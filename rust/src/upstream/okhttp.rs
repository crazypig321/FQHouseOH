//! 红果官网登录专用传输：wreq（btls/BoringSSL）复刻 Android
//! OkHttp 4.12 + Conscrypt 指纹。
//!
//! rustls 的 TLS ClientHello 被官网 `send_code` 端点的风控标记（1105
//! 滑块），鸿蒙系统 HTTP 栈同样被拦；同网络同账号的参考客户端
//! hongguoTV（OkHttp 4.12 + Conscrypt/BoringSSL）可过——端点按 TLS
//! 指纹放行主流客户端。wreq-util 的 `OkHttp4_12` 档案模拟的是桌面
//! BoringSSL 味 OkHttp（带 3DES 与 SHA-1 sigalg、缺 SCT/压缩证书/
//! ALPS），与 Android Conscrypt 实测指纹不符，这里按探针实测
//! （tls.peet.ws）逐项对齐 Android Conscrypt：
//!
//! - JA3 `771,4865-…-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513-21,29-23-24,0`
//! - JA4 `t13d1516h2_8daaf6152771_e5627efa2ab1`
//!   （scrapfly 实测库：Chrome/WeChat Android 共享指纹，佐证
//!   Android Conscrypt/okhttp 系客户端基准）
//!
//! 仅红果 web login 端点使用，其余上游仍走 rustls（见
//! [`super::http`]）。
//!
//! 响应语义与 [`HttpTransport`] 对齐：不跟 30x（登录确认跳转由调用
//! 方手动跟，cookie 不出域）、gzip 按 `Content-Encoding`/魔数解压、
//! 响应体超限报 `TooLarge`。

use std::time::Duration;

use once_cell::sync::OnceCell;
use wreq::header::{HeaderMap, HeaderName, HeaderValue};
use wreq::http2::{Http2Options, PseudoId, PseudoOrder, SettingId, SettingsOrder};
use wreq::tls::{AlpsProtocol, TlsOptions, TlsVersion};
use wreq::{Emulation, Group, Method};
use wreq_util::emulate::compress::BrotliCompressor;

use super::http::{RawResponse, TransportError};
use crate::crypto::{gunzip_capped, GunzipError};

/// 连接超时：与参考实现 hongguoTV 的 OkHttp 默认值同量级。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// 单请求总超时（登录端点只回小 JSON）。
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// Android Conscrypt 套件顺序（JA3 实测基准，无 3DES）。
const CIPHERS: &str = concat!(
    "TLS_AES_128_GCM_SHA256:",
    "TLS_AES_256_GCM_SHA384:",
    "TLS_CHACHA20_POLY1305_SHA256:",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:",
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:",
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:",
    "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA:",
    "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:",
    "TLS_RSA_WITH_AES_128_GCM_SHA256:",
    "TLS_RSA_WITH_AES_256_GCM_SHA384:",
    "TLS_RSA_WITH_AES_128_CBC_SHA:",
    "TLS_RSA_WITH_AES_256_CBC_SHA",
);

/// Android Conscrypt 签名算法（SHA-1 弃用后默认 8 个，无 rsa_pkcs1_sha1）。
const SIGALGS: &str = concat!(
    "ecdsa_secp256r1_sha256:",
    "rsa_pss_rsae_sha256:",
    "rsa_pkcs1_sha256:",
    "ecdsa_secp384r1_sha384:",
    "rsa_pss_rsae_sha384:",
    "rsa_pkcs1_sha384:",
    "rsa_pss_rsae_sha512:",
    "rsa_pkcs1_sha512"
);

/// OkHttp 4.12 HTTP/2 SETTINGS / pseudo 头序（探针实测 akamai 指纹
/// `4:16777216|16711681|0|m,p,a,s` 一致）。
fn conscrypt_emulation() -> Emulation {
    let tls = TlsOptions::builder()
        .enable_ocsp_stapling(true)
        .enable_signed_cert_timestamps(true)
        .curves_list("X25519:P-256:P-384")
        .sigalgs_list(SIGALGS)
        .cipher_list(CIPHERS)
        .min_tls_version(TlsVersion::TLS_1_2)
        .max_tls_version(TlsVersion::TLS_1_3)
        .aes_hw_override(true)
        .certificate_compressors(vec![&BrotliCompressor as &dyn wreq::tls::compress::CertificateCompressor])
        .alps_protocols([AlpsProtocol::HTTP2])
        .alps_use_new_codepoint(false)
        .build();

    let http2 = Http2Options::builder()
        .initial_window_size(16777216)
        .initial_connection_window_size(16777216)
        .headers_pseudo_order(
            PseudoOrder::builder()
                .extend([
                    PseudoId::Method,
                    PseudoId::Path,
                    PseudoId::Authority,
                    PseudoId::Scheme,
                ])
                .build(),
        )
        .settings_order(
            SettingsOrder::builder()
                .extend([
                    SettingId::HeaderTableSize,
                    SettingId::EnablePush,
                    SettingId::MaxConcurrentStreams,
                    SettingId::InitialWindowSize,
                    SettingId::MaxFrameSize,
                    SettingId::MaxHeaderListSize,
                    SettingId::EnableConnectProtocol,
                    SettingId::NoRfc7540Priorities,
                ])
                .build(),
        )
        .build();

    Emulation::builder()
        .tls_options(tls)
        .http2_options(http2)
        .build(Group::new("okhttp-conscrypt"))
}

pub struct OkHttpTransport {
    client: wreq::Client,
}

impl OkHttpTransport {
    fn build() -> Result<Self, String> {
        let client = wreq::Client::builder()
            // 指纹档案：Android OkHttp 4.12 + Conscrypt（探针实测对齐，
            // 见模块头注释的 JA3/JA4 基准）。
            .emulation(conscrypt_emulation())
            // 30x 不自动跟：扫码确认的 redirect_url 由 WebLoginSession
            // 手动跟（站点闸 + cookie 不出域）。
            .redirect(wreq::redirect::Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|e| format!("build okhttp transport: {e}"))?;
        Ok(OkHttpTransport { client })
    }

    /// 有界只读 GET/POST（无请求体），签名对齐
    /// [`HttpTransport::request_bounded`]。
    pub async fn request_bounded(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        self.request(method, url, headers, None, max_bytes).await
    }

    /// 有界表单 POST，签名对齐 [`HttpTransport::request_body_bounded`]。
    pub async fn request_body_bounded(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Vec<u8>,
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        self.request(method, url, headers, Some(body), max_bytes).await
    }

    async fn request(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        let method = Method::from_bytes(method.as_bytes())
            .map_err(|e| TransportError::Network(format!("bad method {method}: {e}")))?;
        let mut map = HeaderMap::new();
        for (key, value) in headers {
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(key.as_bytes()),
                HeaderValue::from_str(value),
            ) {
                map.insert(name, value);
            }
        }
        let mut builder = self.client.request(method, url).headers(map);
        if let Some(body) = body {
            builder = builder.body(body);
        }
        let response = builder
            .send()
            .await
            .map_err(|e| TransportError::Network(e.to_string()))?;
        let status = response.status().as_u16();
        let headers: Vec<(String, String)> = response
            .headers()
            .iter()
            .map(|(key, value)| {
                (
                    key.as_str().to_string(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect();
        let raw = response
            .bytes()
            .await
            .map_err(|e| TransportError::Network(e.to_string()))?;
        if raw.len() > max_bytes {
            return Err(TransportError::TooLarge(format!(
                "response body exceeds {max_bytes} bytes"
            )));
        }
        // 调用方显式带 `Accept-Encoding: gzip`（OkHttp 同款）。按头或魔数
        // 解压；坏 gzip 保留原样交下游 JSON 解析拒绝，超限报 TooLarge。
        let gzip_header = headers.iter().any(|(key, value)| {
            key.eq_ignore_ascii_case("content-encoding") && value.eq_ignore_ascii_case("gzip")
        });
        let gzip_magic = raw.len() >= 2 && raw[0] == 0x1f && raw[1] == 0x8b;
        let body = if gzip_header || gzip_magic {
            match gunzip_capped(&raw, max_bytes) {
                Ok(inflated) => inflated,
                Err(GunzipError::OverLimit) => {
                    return Err(TransportError::TooLarge(format!(
                        "gunzip output exceeds {max_bytes} bytes"
                    )))
                }
                Err(GunzipError::Corrupt(_)) => raw.to_vec(),
            }
        } else {
            raw.to_vec()
        };
        Ok(RawResponse {
            status,
            headers,
            body,
        })
    }
}

/// 进程级 OkHttp 指纹传输（红果 web login 端点专用）。
///
/// 传输无状态可共享；首次构建失败会在下次调用重试。
pub fn okhttp_transport() -> Result<&'static OkHttpTransport, String> {
    static OKHTTP_TRANSPORT: OnceCell<OkHttpTransport> = OnceCell::new();
    OKHTTP_TRANSPORT.get_or_try_init(OkHttpTransport::build)
}
