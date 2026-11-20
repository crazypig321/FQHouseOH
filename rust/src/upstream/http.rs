//! Thin wrapper around the shared reqwest client.
//!
//! Deliberately does NOT use reqwest's gzip feature: the reference implementation only
//! decompresses when the transport itself asked for gzip (or when the body
//! carries the gzip magic), and some endpoints set `Accept-Encoding` by hand.
//! Redirect policy and business-error handling therefore stay identical too.
//! The only addition is an in-scope observation hook: while a playback trace
//! scope is active the redirect decision, the response shape and the inflate
//! result are logged as lengths, booleans and enums. Outside the scope nothing
//! is recorded, and the redirect decision itself keeps the default
//! `Policy::limited(10)` semantics.

use std::time::{Duration, Instant};

use futures::StreamExt;
use once_cell::sync::OnceCell;
use std::sync::atomic::Ordering;

use crate::crypto::{gunzip_capped, GunzipError, MAX_GUNZIP_BYTES};

/// Response-body cap for JSON/API calls (P2-12). The video download path
/// passes its own per-file bound instead, so API callers all share one cap.
pub const API_BODY_LIMIT_BYTES: usize = 64 * 1024 * 1024;

const INLINE_GUNZIP_LIMIT: usize = 64 * 1024;
static GUNZIP_WORK: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

/// How a gzip-decodable response came out. Observation only: the raw bytes are
/// still preserved on `Corrupt` and the over-limit/task cases still surface as
/// [TransportError], exactly as before.
#[derive(Clone, Copy)]
enum GzipOutcome {
    Ok,
    Corrupt,
    OverLimit,
    Task,
}

impl GzipOutcome {
    fn label(self) -> &'static str {
        match self {
            GzipOutcome::Ok => "ok",
            GzipOutcome::Corrupt => "corrupt",
            GzipOutcome::OverLimit => "over_limit",
            GzipOutcome::Task => "task",
        }
    }
}

fn inflate_body(body: Vec<u8>, limit: usize) -> Result<(Vec<u8>, GzipOutcome), TransportError> {
    match gunzip_capped(&body, limit) {
        Ok(inflated) => Ok((inflated, GzipOutcome::Ok)),
        Err(GunzipError::OverLimit) => Err(TransportError::TooLarge(format!(
            "gunzip output exceeds {limit} bytes"
        ))),
        // Preserve corrupt gzip for the downstream parser to reject.
        Err(GunzipError::Corrupt(_)) => Ok((body, GzipOutcome::Corrupt)),
    }
}

async fn inflate_response(
    body: Vec<u8>,
    limit: usize,
) -> Result<(Vec<u8>, GzipOutcome), TransportError> {
    if body.len() <= INLINE_GUNZIP_LIMIT {
        // Bound actual output, not the untrusted gzip size trailer. Even a
        // tiny compressed body can expand into megabytes.
        match gunzip_capped(&body, limit.min(INLINE_GUNZIP_LIMIT)) {
            Ok(inflated) => return Ok((inflated, GzipOutcome::Ok)),
            Err(GunzipError::Corrupt(_)) => return Ok((body, GzipOutcome::Corrupt)),
            Err(GunzipError::OverLimit) if limit <= INLINE_GUNZIP_LIMIT => {
                return Err(TransportError::TooLarge(format!(
                    "gunzip output exceeds {limit} bytes"
                )));
            }
            Err(GunzipError::OverLimit) => {}
        }
    }
    let queued = Instant::now();
    let input_bytes = body.len();
    let permit = GUNZIP_WORK
        .acquire()
        .await
        .map_err(|e| TransportError::Network(e.to_string()))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let wait_ms = queued.elapsed().as_millis();
        let started = Instant::now();
        let result = inflate_body(body, limit);
        let work_ms = started.elapsed().as_millis();
        if wait_ms + work_ms >= 100 {
            log::info!(
                "gunzip slow: queue_ms={wait_ms} work_ms={work_ms} input_bytes={input_bytes}"
            );
        }
        result
    })
    .await
    .map_err(|e| TransportError::Network(format!("gunzip task failed: {e}")))?
}

#[derive(Debug, Clone)]
pub struct RawResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RawResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone)]
pub enum TransportError {
    /// Connection-level failure (Go: `http.Client.Do` error).
    Network(String),
    /// A *local* size limit was hit (caller cap, gunzip cap). This is not a
    /// transport failure and must not be read as one: callers rotate a pooled
    /// device on `Network`, and a response that is simply too big says nothing
    /// about the device.
    TooLarge(String),
}

pub struct HttpTransport {
    client: reqwest::Client,
    timeout: Duration,
}

impl HttpTransport {
    pub fn new(timeout_secs: u64) -> Result<Self, String> {
        Self::build(timeout_secs, false, false)
    }

    /// Account cookies must never follow a redirect to a different origin.
    pub fn without_redirects(timeout_secs: u64) -> Result<Self, String> {
        Self::build(timeout_secs, true, false)
    }

    /// Account cookies must never follow a redirect to a different origin,
    /// and the TLS handshake offers HTTP/2 via ALPN (hongguo web login:
    /// the reference client, OkHttp, always negotiates h2; risk control
    /// flags a Chrome UA that cannot).
    pub fn without_redirects_h2(timeout_secs: u64) -> Result<Self, String> {
        Self::build(timeout_secs, true, true)
    }

    fn build(timeout_secs: u64, no_redirects: bool, alpn_h2: bool) -> Result<Self, String> {
        ensure_crypto_provider();
        let tls = build_tls_config(alpn_h2)?;
        let mut builder = reqwest::Client::builder().tls_backend_preconfigured(tls);
        if no_redirects {
            builder = builder.redirect(reqwest::redirect::Policy::none());
        } else {
            // `Policy::custom` is used purely to observe; the decision it
            // returns is the same one `Policy::limited(10)` makes.
            builder = builder.redirect(observing_redirect_policy());
        }
        let client = builder
            .build()
            .map_err(|e| format!("build http client: {e}"))?;
        Ok(HttpTransport {
            client,
            timeout: Duration::from_secs(timeout_secs),
        })
    }

    /// Uncapped request. Every JSON/API caller must use
    /// [HttpTransport::request_with_limit]; this stays as the escape hatch for
    /// callers that bound the body some other way.
    pub async fn request(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
    ) -> Result<RawResponse, TransportError> {
        self.request_with_limit(method, url, headers, body, timeout, None)
            .await
    }

    /// Bounded read-only account GET, using the shared transport cap logic.
    pub async fn request_bounded(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        self.request_with_limit(method, url, headers, None, None, Some(max_bytes))
            .await
    }

    /// Sign and transmit the same bounded JSON body for account read RPCs.
    pub async fn request_body_bounded(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Vec<u8>,
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        if body.len() > 16 * 1024 {
            return Err(TransportError::TooLarge(
                "request exceeds size limit".into(),
            ));
        }
        self.request_with_limit(method, url, headers, Some(body), None, Some(max_bytes))
            .await
    }

    /// Request whose response body is rejected once it exceeds
    /// `body_limit` (when `Some`). The body is streamed chunk by chunk, so
    /// an over-limit response fails before its full bytes are ever buffered.
    ///
    /// While a playback trace scope is active, one line of safe fields is
    /// logged for this exchange (see [`log_http_trace`]); no query, body,
    /// host, path, header value beyond an encoding category or error message
    /// ever reaches the log.
    pub async fn request_with_limit(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
        body_limit: Option<usize>,
    ) -> Result<RawResponse, TransportError> {
        let trace = super::playback_trace::current();
        let tracing = trace.is_some();
        let request_body_len = body.as_ref().map_or(0, Vec::len);

        let timeout = super::budget::cap_timeout(timeout.unwrap_or(self.timeout));
        if timeout.is_zero() {
            log_http_trace(&trace, HttpTraceMetrics::new("deadline", request_body_len));
            return Err(TransportError::Network(
                "request deadline exceeded".to_string(),
            ));
        }
        let started = if tracing { Some(Instant::now()) } else { None };
        let m = match reqwest::Method::from_bytes(method.as_bytes()) {
            Ok(m) => m,
            Err(_) => {
                log_http_trace(
                    &trace,
                    HttpTraceMetrics::new("bad_method", request_body_len),
                );
                return Err(TransportError::Network(format!("bad method {method}")));
            }
        };
        // Seed the observation with the method this exchange actually sends, so
        // an un-redirected `GET` is not reported as the old fixed `POST`. The
        // redirect policy rewrites it again only when a hop changes it.
        if let Some(context) = trace.as_ref() {
            context.record_method(m.as_str());
        }
        let mut builder = self.client.request(m, url).timeout(timeout);
        if !headers.is_empty() {
            let mut map = reqwest::header::HeaderMap::new();
            for (k, v) in headers {
                if let (Ok(name), Ok(value)) = (
                    reqwest::header::HeaderName::from_bytes(k.as_bytes()),
                    reqwest::header::HeaderValue::from_str(v),
                ) {
                    map.insert(name, value);
                }
            }
            builder = builder.headers(map);
        }
        if let Some(b) = body {
            builder = builder.body(b);
        }

        let resp = match builder.send().await {
            Ok(resp) => resp,
            Err(e) => {
                let mut metrics = HttpTraceMetrics::new(send_error_class(&e), request_body_len);
                metrics.head = started.map(|s| s.elapsed());
                log_http_trace(&trace, metrics);
                return Err(TransportError::Network(e.to_string()));
            }
        };
        let head = started.map(|s| s.elapsed());
        let status = resp.status().as_u16();
        let http_version = resp.version();
        // The final URL after any followed redirect, compared only to the one
        // we asked for: the boolean is kept, the values are not.
        let redirected = resp.url().as_str() != url;
        let headers: Vec<(String, String)> = resp
            .headers()
            .iter()
            .map(|(k, v)| {
                (
                    k.as_str().to_string(),
                    String::from_utf8_lossy(v.as_bytes()).into_owned(),
                )
            })
            .collect();
        let content_length = content_length_value(&headers);
        let encoding = encoding_class(&headers);
        let response = HttpTraceResponse {
            status,
            http_version,
            redirected,
            content_length,
            encoding,
        };
        // Stream the body with the caller's cap enforced per chunk: an
        // over-limit response is rejected before it is fully buffered.
        let body_started = if tracing { Some(Instant::now()) } else { None };
        let mut raw = Vec::new();
        let mut raw_chunks = 0usize;
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(chunk) => chunk,
                Err(e) => {
                    let mut metrics = HttpTraceMetrics::new("body_stream", request_body_len)
                        .with_response(response);
                    metrics.head = head;
                    metrics.body = body_started.map(|s| s.elapsed());
                    metrics.raw_bytes = Some(raw.len());
                    metrics.raw_chunks = Some(raw_chunks);
                    log_http_trace(&trace, metrics);
                    return Err(TransportError::Network(e.to_string()));
                }
            };
            if let Some(limit) = body_limit {
                if chunk.len() > limit.saturating_sub(raw.len()) {
                    let mut metrics = HttpTraceMetrics::new("body_too_large", request_body_len)
                        .with_response(response);
                    metrics.head = head;
                    metrics.body = body_started.map(|s| s.elapsed());
                    metrics.raw_bytes = Some(raw.len());
                    metrics.raw_chunks = Some(raw_chunks);
                    log_http_trace(&trace, metrics);
                    return Err(TransportError::TooLarge(format!(
                        "response body exceeds {limit} bytes"
                    )));
                }
            }
            if tracing {
                raw_chunks += 1;
            }
            raw.extend_from_slice(&chunk);
        }
        let body_elapsed = body_started.map(|s| s.elapsed());

        let gzip_header = headers.iter().any(|(k, v)| {
            k.eq_ignore_ascii_case("content-encoding") && v.eq_ignore_ascii_case("gzip")
        });
        let gzip_magic = raw.len() >= 2 && raw[0] == 0x1f && raw[1] == 0x8b;
        let gzip_hit = gzip_header || gzip_magic;
        let raw_len = raw.len();
        let mut inflate = None;
        let mut gzip_outcome = None;
        let body = if gzip_hit {
            let inflate_limit = body_limit.unwrap_or(MAX_GUNZIP_BYTES).min(MAX_GUNZIP_BYTES);
            let inflate_started = if tracing { Some(Instant::now()) } else { None };
            match inflate_response(raw, inflate_limit).await {
                Ok((inflated, outcome)) => {
                    inflate = inflate_started.map(|s| s.elapsed());
                    gzip_outcome = Some(outcome.label());
                    inflated
                }
                Err(error) => {
                    let result = if matches!(error, TransportError::TooLarge(_)) {
                        "gunzip_over_limit"
                    } else {
                        "gunzip_task"
                    };
                    let mut metrics =
                        HttpTraceMetrics::new(result, request_body_len).with_response(response);
                    metrics.head = head;
                    metrics.body = body_elapsed;
                    metrics.raw_bytes = Some(raw_len);
                    metrics.raw_chunks = Some(raw_chunks);
                    metrics.gzip = Some(true);
                    metrics.gzip_outcome = Some(if matches!(error, TransportError::TooLarge(_)) {
                        GzipOutcome::OverLimit.label()
                    } else {
                        GzipOutcome::Task.label()
                    });
                    metrics.inflate = inflate_started.map(|s| s.elapsed());
                    log_http_trace(&trace, metrics);
                    return Err(error);
                }
            }
        } else {
            raw
        };

        if tracing {
            let mut metrics = HttpTraceMetrics::new("ok", request_body_len).with_response(response);
            metrics.head = head;
            metrics.body = body_elapsed;
            metrics.raw_bytes = Some(raw_len);
            metrics.raw_chunks = Some(raw_chunks);
            metrics.gzip = Some(gzip_hit);
            metrics.gzip_outcome = gzip_outcome;
            metrics.body_len = Some(body.len());
            metrics.inflate = inflate;
            log_http_trace(&trace, metrics);
        }

        Ok(RawResponse {
            status,
            headers,
            body,
        })
    }
}

/// Default `reqwest` following, plus an in-scope hop/method record.
///
/// The decision itself is delegated to `Policy::limited(10)`, so the wire
/// behaviour is exactly the default. Only while the playback scope is active
/// and the default would follow (at most ten URLs in the chain) are the hop
/// count and the method rewrite recorded; a request outside the scope, or a
/// chain the default rejects, records nothing.
fn observing_redirect_policy() -> reqwest::redirect::Policy {
    let default = reqwest::redirect::Policy::limited(10);
    reqwest::redirect::Policy::custom(move |attempt| {
        let previous_len = attempt.previous().len();
        if previous_len <= 10 {
            if let Some(context) = super::playback_trace::current() {
                // `tower_http::follow_redirect` rewrites any method other than
                // GET or HEAD to GET for 301/302/303 and keeps it for 307/308.
                if matches!(attempt.status().as_u16(), 301..=303) {
                    if let Ok(mut method) = context.redirect_method.lock() {
                        if !matches!(method.as_str(), "GET" | "HEAD") {
                            method.clear();
                            method.push_str("GET");
                        }
                    }
                }
                // `previous` already holds the initial URL, so the count of
                // followed hops equals its length on a follow decision.
                context.redirect_hops.store(previous_len, Ordering::Relaxed);
            }
        }
        default.redirect(attempt)
    })
}

/// Response-level fields shared by every exit path of one exchange.
#[derive(Clone, Copy)]
struct HttpTraceResponse {
    status: u16,
    http_version: reqwest::Version,
    redirected: bool,
    content_length: Option<u64>,
    encoding: &'static str,
}

/// Safe fields of one HTTP exchange. Lengths, booleans and enums only; never a
/// query, body, host, path, header value or error message.
struct HttpTraceMetrics {
    result: &'static str,
    request_body_len: usize,
    response: Option<HttpTraceResponse>,
    head: Option<Duration>,
    body: Option<Duration>,
    inflate: Option<Duration>,
    raw_bytes: Option<usize>,
    raw_chunks: Option<usize>,
    gzip: Option<bool>,
    gzip_outcome: Option<&'static str>,
    body_len: Option<usize>,
}

impl HttpTraceMetrics {
    fn new(result: &'static str, request_body_len: usize) -> Self {
        Self {
            result,
            request_body_len,
            response: None,
            head: None,
            body: None,
            inflate: None,
            raw_bytes: None,
            raw_chunks: None,
            gzip: None,
            gzip_outcome: None,
            body_len: None,
        }
    }

    fn with_response(mut self, response: HttpTraceResponse) -> Self {
        self.response = Some(response);
        self
    }
}

/// Emits the one observation line, or nothing when no scope is active.
///
/// The fields let a reader separate the three empty-body shapes without any
/// payload: `raw_bytes=0` is a raw-empty body, `gzip=true gzip_outcome=ok
/// body_len=0` is a valid gzip stream that inflated to nothing, and
/// `gzip_outcome=corrupt` is an undecodable body that was passed through
/// unchanged.
fn log_http_trace(
    trace: &Option<super::playback_trace::PlaybackTraceContext>,
    metrics: HttpTraceMetrics,
) {
    let Some(context) = trace.as_ref() else {
        return;
    };
    let request = context.request_id;
    let purpose = context.purpose;
    let attempt = context.attempt;
    let device = context.device_tag;
    let in_flight = context.in_flight;
    let result = metrics.result;
    let hops = context.redirect_hops.load(Ordering::Relaxed);
    let final_method = context.recorded_method();
    let status = metrics
        .response
        .map_or_else(|| "-".to_string(), |r| r.status.to_string());
    let http = version_label(metrics.response.map(|r| r.http_version));
    let redirected = opt_bool(metrics.response.map(|r| r.redirected));
    let content_len = opt_u64(metrics.response.and_then(|r| r.content_length));
    let encoding = metrics.response.map_or("-", |r| r.encoding);
    let raw_bytes = opt_usize(metrics.raw_bytes);
    let raw_chunks = opt_usize(metrics.raw_chunks);
    let gzip = opt_bool(metrics.gzip);
    let gzip_outcome = opt_str(metrics.gzip_outcome);
    let body_len = opt_usize(metrics.body_len);
    let req_body_len = metrics.request_body_len;
    let head_ms = opt_ms(metrics.head);
    let body_ms = opt_ms(metrics.body);
    let inflate_ms = opt_ms(metrics.inflate);
    log::info!(
        "v5 http request={request} purpose={purpose} attempt={attempt} device={device} in_flight={in_flight} result={result} status={status} http={http} redirected={redirected} hops={hops} final_method={final_method} content_len={content_len} encoding={encoding} raw_bytes={raw_bytes} raw_chunks={raw_chunks} gzip={gzip} gzip_outcome={gzip_outcome} body_len={body_len} req_body_len={req_body_len} head_ms={head_ms} body_ms={body_ms} inflate_ms={inflate_ms}"
    );
}

/// Connection-failure category only; the message may carry a URL and is never
/// logged here.
fn send_error_class(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "send_timeout"
    } else if error.is_redirect() {
        "send_redirect"
    } else if error.is_connect() {
        "send_connect"
    } else {
        "send_other"
    }
}

fn version_label(version: Option<reqwest::Version>) -> &'static str {
    match version {
        None => "-",
        Some(v) if v == reqwest::Version::HTTP_09 => "HTTP/0.9",
        Some(v) if v == reqwest::Version::HTTP_10 => "HTTP/1.0",
        Some(v) if v == reqwest::Version::HTTP_11 => "HTTP/1.1",
        Some(v) if v == reqwest::Version::HTTP_2 => "HTTP/2.0",
        Some(v) if v == reqwest::Version::HTTP_3 => "HTTP/3.0",
        Some(_) => "other",
    }
}

/// Decimal `Content-Length` only; a non-numeric or absent value is `None`.
fn content_length_value(headers: &[(String, String)]) -> Option<u64> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<u64>().ok())
}

/// Category only: the raw `Content-Encoding` value never reaches the log.
fn encoding_class(headers: &[(String, String)]) -> &'static str {
    match headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-encoding"))
        .map(|(_, v)| v.as_str())
    {
        None => "none",
        Some(v) if v.eq_ignore_ascii_case("gzip") => "gzip",
        Some(v) if v.eq_ignore_ascii_case("identity") => "identity",
        Some(_) => "other",
    }
}

fn opt_u64(value: Option<u64>) -> String {
    value.map_or_else(|| "-".to_string(), |value| value.to_string())
}

fn opt_usize(value: Option<usize>) -> String {
    value.map_or_else(|| "-".to_string(), |value| value.to_string())
}

fn opt_bool(value: Option<bool>) -> String {
    value.map_or_else(|| "-".to_string(), |value| value.to_string())
}

fn opt_ms(value: Option<Duration>) -> String {
    value.map_or_else(|| "-".to_string(), |value| value.as_millis().to_string())
}

fn opt_str(value: Option<&'static str>) -> &'static str {
    value.unwrap_or("-")
}

/// Process-wide transport for account cookie requests.
///
/// Account reads must not follow redirects with a cookie attached, and every
/// collection request used to build a fresh `reqwest::Client` (TLS roots and
/// all) just for that. The transport is stateless, so one shared instance is
/// safe and keeps client construction off the per-request path. A failed
/// first build is retried on the next call.
pub fn account_transport() -> Result<&'static HttpTransport, String> {
    static ACCOUNT_TRANSPORT: OnceCell<HttpTransport> = OnceCell::new();
    ACCOUNT_TRANSPORT.get_or_try_init(|| HttpTransport::without_redirects(20))
}

/// Process-wide transport for the hongguo web-login endpoints. Identical to
/// [`account_transport`] except the TLS config advertises `h2` in ALPN, so
/// reqwest negotiates HTTP/2 like the reference OkHttp client does. A Chrome
/// UA over plain HTTP/1.1 reads as a bot to the passport risk control and
/// triggers slider challenges (1105) on `send_code`.
pub fn web_login_transport() -> Result<&'static HttpTransport, String> {
    static WEB_LOGIN_TRANSPORT: OnceCell<HttpTransport> = OnceCell::new();
    WEB_LOGIN_TRANSPORT.get_or_try_init(|| HttpTransport::without_redirects_h2(20))
}

/// reqwest is built with `rustls-no-provider` so exactly one TLS backend is
/// linked; that means the process-wide crypto provider has to be installed
/// before any client is constructed. Installing it here keeps the requirement
/// with the only code that needs it.
fn ensure_crypto_provider() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn build_tls_config(alpn_h2: bool) -> Result<rustls::ClientConfig, String> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("tls protocol versions: {e}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    if alpn_h2 {
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    }
    Ok(config)
}

#[cfg(test)]
mod body_cap_tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// Serves one fixed response, then exits. Returns the URL to fetch.
    fn serve_once(body: Vec<u8>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 8192];
                let _ = stream.read(&mut buf);
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes());
                let _ = stream.write_all(&body);
                let _ = stream.flush();
            }
        });
        format!("http://{addr}/api/x")
    }

    fn run<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(f)
    }

    #[test]
    fn over_limit_body_is_rejected() {
        let url = serve_once(vec![b'x'; 1024 * 1024]);
        let transport = HttpTransport::new(5).expect("transport");
        let err = run(transport.request_with_limit("GET", &url, &[], None, None, Some(1024)))
            .expect_err("1 MiB body must exceed a 1 KiB cap");
        // A local cap is its own class: `Network` would make the caller retire
        // a pooled device over a response that is merely too large.
        assert!(matches!(err, TransportError::TooLarge(_)));
    }

    #[test]
    fn under_limit_body_passes_through() {
        let url = serve_once(b"{\"ok\":true}".to_vec());
        let transport = HttpTransport::new(5).expect("transport");
        let resp = run(transport.request_with_limit("GET", &url, &[], None, None, Some(1024)))
            .expect("small body passes");
        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, b"{\"ok\":true}");
    }
}

#[cfg(test)]
mod account_transport_tests {
    use super::account_transport;

    // Account collection runs several requests per import; each one used to
    // rebuild the TLS client. The shared handle must stay identical.
    #[test]
    fn the_account_transport_is_built_once_and_reused() {
        let first = account_transport().expect("account transport");
        let second = account_transport().expect("account transport");
        assert!(
            std::ptr::eq(first, second),
            "account requests must reuse the cached no-redirect transport"
        );
    }
}

#[cfg(test)]
mod trace_method_tests {
    use super::*;
    use crate::upstream::playback_trace;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// Serves one scripted response per accepted connection, in order, so a
    /// redirect chain can be followed to its end. `{base}` is expanded to the
    /// listener's own origin, which keeps the Location header local.
    fn serve_script(script: &[&str]) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let base = format!("http://{addr}");
        let bodies: Vec<String> = script
            .iter()
            .map(|response| response.replace("{base}", &base))
            .collect();
        std::thread::spawn(move || {
            for body in bodies {
                if let Ok((mut stream, _)) = listener.accept() {
                    let mut buf = [0u8; 8192];
                    let _ = stream.read(&mut buf);
                    let _ = stream.write_all(body.as_bytes());
                    let _ = stream.flush();
                }
            }
        });
        format!("{base}/api/x")
    }

    const OK: &str = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}";
    const SEE_OTHER: &str = "HTTP/1.1 303 See Other\r\nLocation: {base}/api/y\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    fn run<F: std::future::Future>(work: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(work)
    }

    /// Sends one exchange inside a playback scope and reports the method the
    /// tracker holds afterwards, plus the hop count it recorded.
    fn traced(
        transport: &HttpTransport,
        method: &str,
        url: &str,
        body: Option<Vec<u8>>,
    ) -> (String, usize) {
        run(playback_trace::within(7, "foreground", async {
            transport
                .request_with_limit(method, url, &[], body, None, Some(4096))
                .await
                .expect("exchange succeeds");
            let context = playback_trace::current().expect("scope");
            (
                context.recorded_method(),
                context.redirect_hops.load(Ordering::Relaxed),
            )
        }))
    }

    // The defect: a fallback door sends GET, nothing redirects, and the log
    // still claimed `final_method=POST`.
    #[test]
    fn a_non_redirected_get_reports_the_method_actually_sent() {
        let url = serve_script(&[OK]);
        let transport = HttpTransport::new(5).expect("transport");
        let (method, hops) = traced(&transport, "GET", &url, None);
        assert_eq!(hops, 0, "no hop may be recorded for a direct response");
        assert_eq!(method, "GET");
    }

    // A `POST` that a 303 rewrites to `GET` must still report the rewrite.
    #[test]
    fn a_rewriting_redirect_still_updates_the_method() {
        let url = serve_script(&[SEE_OTHER, OK]);
        let transport = HttpTransport::new(5).expect("transport");
        let (method, hops) = traced(&transport, "POST", &url, Some(b"{}".to_vec()));
        assert_eq!(hops, 1, "the followed hop is recorded");
        assert_eq!(method, "GET");
    }

    // `HEAD` survives a 303 unchanged, so the seed must not be flattened to GET.
    #[test]
    fn a_see_other_keeps_a_head_method() {
        let url = serve_script(&[SEE_OTHER, OK]);
        let transport = HttpTransport::new(5).expect("transport");
        let (method, hops) = traced(&transport, "HEAD", &url, None);
        assert_eq!(hops, 1);
        assert_eq!(method, "HEAD");
    }
}
