//! Request-local, content-free diagnostics for V5 playback.

use std::collections::hash_map::RandomState;
use std::future::Future;
use std::hash::BuildHasher;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);
static DEVICE_TAG_HASHER: OnceLock<RandomState> = OnceLock::new();

/// Marker for "no exchange has been sent under this scope yet", matching the
/// unknown marker the observation line already prints. Nothing here guesses a
/// method: the transport records the one it resolves before sending.
pub(crate) const METHOD_UNKNOWN: &str = "-";

#[derive(Clone)]
pub(crate) struct PlaybackTraceContext {
    pub request_id: u64,
    pub purpose: &'static str,
    pub attempt: usize,
    pub device_tag: u64,
    pub in_flight: usize,
    pub redirect_hops: Arc<AtomicUsize>,
    pub redirect_method: Arc<Mutex<String>>,
    pub route: &'static str,
    pub exchange: Arc<Mutex<PlaybackExchange>>,
}

#[derive(Clone, Copy)]
pub(crate) struct PlaybackExchange {
    pub http_status: Option<u16>,
    pub body_len: Option<usize>,
    pub envelope: &'static str,
}

impl Default for PlaybackExchange {
    fn default() -> Self {
        Self {
            http_status: None,
            body_len: None,
            envelope: "legacy",
        }
    }
}

impl PlaybackTraceContext {
    /// Records the method the transport is actually sending for this exchange.
    /// A redirect that rewrites the method still updates it afterwards, so the
    /// log reports what went on the wire rather than a fixed literal.
    pub(crate) fn record_method(&self, method: &str) {
        if let Ok(mut recorded) = self.redirect_method.lock() {
            recorded.clear();
            recorded.push_str(method);
        }
    }

    /// The method currently on record for this exchange.
    pub(crate) fn recorded_method(&self) -> String {
        self.redirect_method
            .lock()
            .map_or_else(|_| METHOD_UNKNOWN.to_string(), |method| method.clone())
    }
}

tokio::task_local! {
    static TRACE: PlaybackTraceContext;
}

pub(crate) fn current() -> Option<PlaybackTraceContext> {
    TRACE.try_with(Clone::clone).ok()
}

pub(crate) fn purpose(value: &str) -> &'static str {
    match value {
        "foreground" => "foreground",
        "prefetch" => "prefetch",
        _ => "other",
    }
}

struct InFlight;

impl Drop for InFlight {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(crate) async fn within<F: Future>(
    request_id: u64,
    purpose: &'static str,
    work: F,
) -> F::Output {
    let in_flight = IN_FLIGHT.fetch_add(1, Ordering::Relaxed) + 1;
    // Dropping a cancelled endpoint also releases its diagnostic count.
    let _in_flight = InFlight;
    let trace = PlaybackTraceContext {
        request_id,
        purpose,
        attempt: 0,
        device_tag: 0,
        in_flight,
        redirect_hops: Arc::new(AtomicUsize::new(0)),
        redirect_method: Arc::new(Mutex::new(METHOD_UNKNOWN.to_string())),
        route: "-",
        exchange: Arc::new(Mutex::new(PlaybackExchange::default())),
    };
    log::info!("v5 trace request={request_id} purpose={purpose} event=start in_flight={in_flight}");
    TRACE.scope(trace, work).await
}

pub(crate) async fn with_route<F: Future>(route: &'static str, work: F) -> F::Output {
    let Some(mut trace) = current() else {
        return work.await;
    };
    trace.route = route;
    trace.exchange = Arc::new(Mutex::new(PlaybackExchange::default()));
    TRACE.scope(trace, work).await
}

pub(crate) async fn with_device<F: Future>(device_id: &str, work: F) -> F::Output {
    let Some(mut trace) = current() else {
        return work.await;
    };
    // A randomly keyed process-local hash permits comparisons within one run
    // without logging an identity or producing a stable identifier across runs.
    trace.device_tag = DEVICE_TAG_HASHER
        .get_or_init(RandomState::new)
        .hash_one(device_id);
    TRACE.scope(trace, work).await
}

pub(crate) async fn with_attempt<F: Future>(attempt: usize, work: F) -> F::Output {
    let Some(mut trace) = current() else {
        return work.await;
    };
    trace.attempt = attempt;
    trace.in_flight = IN_FLIGHT.load(Ordering::Relaxed);
    trace.redirect_hops = Arc::new(AtomicUsize::new(0));
    // A retry re-sends the request, so this attempt learns its own method.
    trace.redirect_method = Arc::new(Mutex::new(METHOD_UNKNOWN.to_string()));
    TRACE.scope(trace, work).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run<F: Future>(work: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(work)
    }

    fn recorded() -> String {
        current().expect("scope").recorded_method()
    }

    // A request that is never redirected must report the method it actually
    // sent. The scope starts unknown, so a GET can no longer come out as POST.
    #[test]
    fn a_non_redirected_request_reports_the_recorded_method() {
        let method = run(within(1, "foreground", async {
            assert_eq!(recorded(), METHOD_UNKNOWN);
            current().expect("scope").record_method("GET");
            recorded()
        }));
        assert_eq!(method, "GET");
    }

    // Each attempt re-sends the request, so it inherits no method from the one
    // before it and reports its own once the transport records it.
    #[test]
    fn a_new_attempt_starts_without_a_method() {
        let method = run(within(1, "foreground", async {
            current().expect("scope").record_method("GET");
            with_attempt(1, async {
                assert_eq!(recorded(), METHOD_UNKNOWN);
                current().expect("scope").record_method("POST");
                recorded()
            })
            .await
        }));
        assert_eq!(method, "POST");
    }
}
