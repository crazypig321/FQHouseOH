//! Error boundary for the Rust core.
//!
//! Mirrors the Go router's two error classes: a client error maps to HTTP 400
//! with `{"success":false,"error":...}`, anything else to HTTP 500.
//! The hongguo_native endpoints add gateway statuses for the bridged Go core
//! (502 call failure, 503 core not loaded, 504 bridge timeout).

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    BadRequest(String),
    Internal(String),
    ServiceUnavailable(String),
    Timeout(String),
    BadGateway(String),
}

impl ApiError {
    pub fn bad_request(msg: impl Into<String>) -> Self {
        ApiError::BadRequest(msg.into())
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        ApiError::Internal(msg.into())
    }

    pub fn service_unavailable(msg: impl Into<String>) -> Self {
        ApiError::ServiceUnavailable(msg.into())
    }

    pub fn timeout(msg: impl Into<String>) -> Self {
        ApiError::Timeout(msg.into())
    }

    pub fn bad_gateway(msg: impl Into<String>) -> Self {
        ApiError::BadGateway(msg.into())
    }

    pub fn status(&self) -> u16 {
        match self {
            ApiError::BadRequest(_) => 400,
            ApiError::Internal(_) => 500,
            ApiError::ServiceUnavailable(_) => 503,
            ApiError::Timeout(_) => 504,
            ApiError::BadGateway(_) => 502,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            ApiError::BadRequest(m)
            | ApiError::Internal(m)
            | ApiError::ServiceUnavailable(m)
            | ApiError::Timeout(m)
            | ApiError::BadGateway(m) => m,
        }
    }

    /// Whether retrying the same request could plausibly succeed.
    ///
    /// Client errors are deterministic (bad input) and must never be retried.
    /// Internal errors come from an upstream call or the parsing of its
    /// response, so they can be transient upstream jitter. The gateway
    /// statuses (hongguo_native) follow the same rule: the bridged core can
    /// recover once loaded or once the upstream jitter passes.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            ApiError::Internal(_) | ApiError::ServiceUnavailable(_) | ApiError::Timeout(_) | ApiError::BadGateway(_)
        )
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for ApiError {}

impl From<serde_json::Error> for ApiError {
    fn from(e: serde_json::Error) -> Self {
        ApiError::Internal(format!("parse upstream json: {e}"))
    }
}

impl From<std::io::Error> for ApiError {
    fn from(e: std::io::Error) -> Self {
        ApiError::Internal(e.to_string())
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
