//! 红果验证码登录（hongguoTV `PhoneLogin` 移植）：走官方 App 的签名移动端点
//! `security.snssdk.com`（medusa 设备签名），不碰网页端点（web send_code 对
//! 非浏览器客户端一律滑块）。
//!
//! - [`PhoneLoginSession::send`]：`/passport/mobile/send_code/v1/`（GET）。
//! - [`PhoneLoginSession::verify`]：`sms_login` 系列表单 POST 循环 +
//!   `mobile_ticket` 轮换，`Set-Cookie` 收到 `sessionid` 即成功，返回 cookie 串。
//! - [`RETRY_UNTIL_MS`]：进程级 `RetryGate`（hongguoTV 同款 error_code 7 本地退避）。

use std::sync::atomic::{AtomicI64, Ordering};

use serde_json::{json, Value};

use super::vsign;
use crate::timeutil::now_millis;
use crate::upstream::okhttp::okhttp_transport;

const PASSPORT: &str = "https://security.snssdk.com";
/// login-lab 实测：24 = 登录验证码；1 / 3 是绑定 / 换绑手机号。
const LOGIN_CODE_TYPE: &str = "24";
const RESPONSE_LIMIT: usize = 1024 * 1024;
/// PhoneLogin 设备表版本覆盖（query 与 medusa 明文共用）。
const PASSPORT_VERSION_NAME: &str = "7.3.9.32";

/// 短信登录主端点是 `sms_login` 系列；`validate_code` 是「已登录后校验手机号」
/// 的入口，对未登录会话固定回 `error_code 1`，放最后兜底。
const VERIFY_ATTEMPTS: &[(&str, bool)] = &[
    ("/passport/mobile/sms_login/", true),
    ("/passport/mobile/sms_login_only/", true),
    ("/passport/mobile/sms_login_continue/", true),
    ("/passport/mobile/validate_code/v1/", false),
    ("/passport/mobile/validate_code/v1/", true),
];

/// RetryGate：error_code 7 后本地退避（hongguoTV `RetryGate`，进程级共享）。
static RETRY_UNTIL_MS: AtomicI64 = AtomicI64::new(0);

fn retry_gate_remaining_seconds() -> i64 {
    let until = RETRY_UNTIL_MS.load(Ordering::Relaxed);
    let remaining = (until - now_millis()).max(0);
    (remaining + 999) / 1000
}

fn retry_gate_check() -> Result<(), String> {
    let seconds = retry_gate_remaining_seconds();
    if seconds > 0 {
        return Err(format!(
            "平台提示操作过于频繁（错误码 7）。请至少等待 {seconds} 秒后重试；倒计时不代表平台限制已解除。如仍失败，可稍后再试或改用扫码登录。"
        ));
    }
    Ok(())
}

/// 设置退避并返回可显示的失败消息。
fn retry_gate_reject(seconds: i64) -> String {
    let seconds = seconds.max(60);
    RETRY_UNTIL_MS.store(now_millis() + seconds * 1000, Ordering::Relaxed);
    format!(
        "平台提示操作过于频繁（错误码 7）。请至少等待 {seconds} 秒后重试；倒计时不代表平台限制已解除。如仍失败，可稍后再试或改用扫码登录。"
    )
}

fn describe(data: &Value) -> Option<String> {
    let description = data.get("description").and_then(Value::as_str).unwrap_or("");
    if description.is_empty() {
        return None;
    }
    let error_code = data.get("error_code").and_then(Value::as_i64).unwrap_or(0);
    Some(format!("{description}（错误码 {error_code}）"))
}

fn data_of(reply: &Value) -> Value {
    reply.get("data").filter(|d| d.is_object()).cloned().unwrap_or_else(|| json!({}))
}

/// hongguoTV `PhoneLogin.call` 的设备表：`DEVICE` 原键序去掉 `device_id` /
/// `iid`（官方 App 的 passport 请求不带注册字段，设备靠签名识别），版本字段
/// 覆盖 73932 / 7.3.9.32。
fn passport_query_device() -> Vec<(String, String)> {
    vsign::DEVICE
        .iter()
        .filter(|(k, _)| *k != "device_id" && *k != "iid")
        .map(|(k, v)| {
            let v = match *k {
                "version_code" | "manifest_version_code" | "update_version_code"
                | "pv_player" => "73932",
                "version_name" => PASSPORT_VERSION_NAME,
                _ => *v,
            };
            ((*k).to_string(), v.to_string())
        })
        .collect()
}

pub(crate) struct Sent {
    pub masked_mobile: String,
    pub retry_seconds: i64,
}

/// 一次验证码登录对应一个会话；RetryGate 是进程级的，重建会话不会清退避。
pub(crate) struct PhoneLoginSession {
    device_id: String,
    install_id: String,
    mobile: String,
    ticket: String,
    expired: bool,
    sent: bool,
    /// 保序 cookie（按名覆盖，`Set-Cookie` 累积）。
    cookies: Vec<(String, String)>,
}

impl PhoneLoginSession {
    pub(crate) fn new() -> PhoneLoginSession {
        PhoneLoginSession {
            device_id: String::new(),
            install_id: String::new(),
            mobile: String::new(),
            ticket: String::new(),
            expired: false,
            sent: false,
            cookies: Vec::new(),
        }
    }

    pub(crate) fn has_sent(&self) -> bool {
        self.sent
    }

    fn cookie_value(&self, name: &str) -> Option<&str> {
        self.cookies.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    fn cookie_header(&self) -> String {
        self.cookies
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    }

    fn merge_set_cookies(&mut self, headers: &[(String, String)]) {
        for (name, value) in headers {
            if !name.eq_ignore_ascii_case("set-cookie") {
                continue;
            }
            let pair = value.split(';').next().unwrap_or("").trim();
            let Some((key, val)) = pair.split_once('=') else {
                continue;
            };
            let key = key.trim();
            let val = val.trim();
            if key.is_empty() || val.is_empty() {
                continue;
            }
            match self.cookies.iter_mut().find(|(k, _)| k == key) {
                Some(existing) => existing.1 = val.to_string(),
                None => self.cookies.push((key.to_string(), val.to_string())),
            }
        }
    }

    /// 带设备签名发一次 passport 请求；`Set-Cookie` 并进会话，返回 JSON。
    /// error_code 7 时清 cookie 并设置 RetryGate。
    async fn call(
        &mut self,
        path: &str,
        params: &[(&str, &str)],
        form: bool,
    ) -> Result<Value, String> {
        let query_device = passport_query_device();
        let mut passport: Vec<(String, String)> = vec![
            ("aid".into(), "8662".into()),
            ("app_name".into(), "novelread".into()),
            ("device_platform".into(), "android".into()),
        ];
        for (key, value) in params {
            if !value.is_empty() {
                passport.push(((*key).to_string(), (*value).to_string()));
            }
        }
        // 表单 POST：passport 参数进 body；GET：并入 query（设备表已有的同名键
        // 值相同，跳过不重复）。
        let body: Option<Vec<u8>> = if form {
            Some(vsign::python_url_encode(&passport).into_bytes())
        } else {
            None
        };
        let mut query_values = query_device.clone();
        if body.is_none() {
            for (key, value) in &passport {
                if !query_values.iter().any(|(k, _)| k == key) {
                    query_values.push((key.clone(), value.clone()));
                }
            }
        }
        let signed = vsign::signed_passport_request(
            &format!("{PASSPORT}{path}"),
            &query_values,
            body.as_deref(),
            PASSPORT_VERSION_NAME,
            now_millis(),
        );
        // 刻意不回发 Cookie：send_code 下发的 cookie 带进 sms_login 会被判
        // 2046；Set-Cookie 只用于判断是否拿到 sessionid（hongguoTV 同款）。
        let client = okhttp_transport().map_err(|_| "无法初始化红果登录连接。".to_string())?;
        let upstream = match &signed.body {
            Some(body) => {
                client
                    .request_body_bounded(
                        "POST",
                        &signed.url,
                        &signed.headers,
                        body.clone(),
                        RESPONSE_LIMIT,
                    )
                    .await
            }
            None => {
                client
                    .request_bounded("GET", &signed.url, &signed.headers, RESPONSE_LIMIT)
                    .await
            }
        }
        .map_err(|_| "红果登录服务暂不可用，请检查网络后重试".to_string())?;
        self.merge_set_cookies(&upstream.headers);
        let raw = String::from_utf8_lossy(&upstream.body);
        let reply: Value = if upstream.body.is_empty() {
            json!({})
        } else {
            serde_json::from_slice(&upstream.body).unwrap_or_else(|_| {
                json!({
                    "http": upstream.status,
                    "raw": raw.chars().take(300).collect::<String>(),
                })
            })
        };
        // error_code 7：在任何业务解析前拦下（hongguoTV `call` 同序）。
        let data = data_of(&reply);
        if data.get("error_code").and_then(Value::as_i64) == Some(7) {
            self.cookies.clear();
            let retry = data.get("retry_time").and_then(Value::as_i64).unwrap_or(60);
            return Err(retry_gate_reject(retry));
        }
        Ok(reply)
    }

    /// 发送验证码：返回平台回显的打码号码与重发倒计时秒数。
    pub(crate) async fn send(&mut self, mobile: &str) -> Result<Sent, String> {
        retry_gate_check()?;
        // 官方 App 的短信登录不注册新设备：直接用设备表里的固定
        // device_id / iid，不带注册 cookie。
        self.device_id = vsign::DEVICE
            .iter()
            .find(|(k, _)| *k == "device_id")
            .map(|(_, v)| (*v).to_string())
            .unwrap_or_default();
        self.install_id = vsign::DEVICE
            .iter()
            .find(|(k, _)| *k == "iid")
            .map(|(_, v)| (*v).to_string())
            .unwrap_or_default();
        self.cookies.clear();
        self.ticket.clear();
        self.expired = false;
        self.mobile = mobile.to_string();
        let reply = self
            .call(
                "/passport/mobile/send_code/v1/",
                &[("mobile", mobile), ("type", LOGIN_CODE_TYPE)],
                false,
            )
            .await?;
        let data = data_of(&reply);
        // 风控要求滑块验证：本流程不做也不绕。
        if data.get("verify_center_decision_conf").is_some() {
            return Err("平台要求先完成滑块验证，当前流程暂不支持，尚未完成登录。".to_string());
        }
        let message = reply.get("message").and_then(Value::as_str).unwrap_or("");
        if message != "success" {
            return Err(describe(&data).unwrap_or_else(|| "验证码没发出去。".to_string()));
        }
        self.ticket = data
            .get("mobile_ticket")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        self.sent = true;
        let masked = data.get("mobile").and_then(Value::as_str).unwrap_or("");
        Ok(Sent {
            masked_mobile: if masked.is_empty() { mobile.to_string() } else { masked.to_string() },
            retry_seconds: data
                .get("retry_time")
                .and_then(Value::as_i64)
                .unwrap_or(60)
                .clamp(1, 600),
        })
    }

    /// 校验验证码；成功返回全部会话 cookie 串（含 `sessionid`）。
    pub(crate) async fn verify(&mut self, code: &str) -> Result<String, String> {
        retry_gate_check()?;
        if self.expired {
            return Err("本次登录会话已失效，请重新获取验证码。".to_string());
        }
        if self.device_id.is_empty() {
            return Err("请先发送验证码。".to_string());
        }
        let mut params: Vec<(String, String)> = vec![
            ("mobile".into(), self.mobile.clone()),
            ("code".into(), code.to_string()),
            ("type".into(), LOGIN_CODE_TYPE.into()),
            ("mobile_ticket".into(), self.ticket.clone()),
        ];
        let mut first_failure: Option<String> = None;
        for (path, form) in VERIFY_ATTEMPTS {
            let refs: Vec<(&str, &str)> = params
                .iter()
                .map(|(key, value)| (key.as_str(), value.as_str()))
                .collect();
            let reply = self.call(path, &refs, *form).await?;
            if self.cookie_value("sessionid").is_some() {
                break;
            }
            let data = data_of(&reply);
            // 平台每次尝试后可能下发新 mobile_ticket，后续端点沿用最新值。
            if let Some(fresh) = data.get("mobile_ticket").and_then(Value::as_str) {
                if !fresh.is_empty() {
                    self.ticket = fresh.to_string();
                    for (key, value) in params.iter_mut() {
                        if key == "mobile_ticket" {
                            *value = fresh.to_string();
                        }
                    }
                }
            }
            let error_code = data.get("error_code").and_then(Value::as_i64).unwrap_or(0);
            if error_code == 0 || error_code == 1 {
                // 1 = 会话过期：该端点不适用于「未登录换验证码」，继续试下一条。
                if error_code == 1 && first_failure.is_none() {
                    first_failure = Some("会话过期，请重新登录（错误码 1）。".to_string());
                }
                continue;
            }
            if error_code == 1203 {
                // 错误次数过多或验证码过期：本次会话作废，继续提交只会更糟。
                self.expired = true;
                self.cookies.clear();
                self.ticket.clear();
                return Err(describe(&data).unwrap_or_else(|| {
                    "错误次数过多或验证码过期，请重新获取验证码（错误码 1203）。".to_string()
                }));
            }
            return Err(
                describe(&data)
                    .unwrap_or_else(|| format!("验证码校验失败（错误码 {error_code}）。")),
            );
        }
        if self.cookie_value("sessionid").is_none() {
            return Err(first_failure.unwrap_or_else(|| "登录没有成功，平台没有下发登录态。".to_string()));
        }
        Ok(self.cookie_header())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passport_query_device_drops_ids_and_overrides_versions() {
        let device = passport_query_device();
        assert!(device.iter().all(|(k, _)| k != "device_id" && k != "iid"));
        let value = |key: &str| {
            device
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.as_str())
                .unwrap()
        };
        for key in ["version_code", "manifest_version_code", "update_version_code", "pv_player"] {
            assert_eq!(value(key), "73932", "{key} 应覆盖为 73932");
        }
        assert_eq!(value("version_name"), "7.3.9.32");
        assert_eq!(value("aid"), "8662");
        assert_eq!(value("app_name"), "novelread");
        // 键序与 DEVICE 一致（签名对 query 字节级敏感）。
        let expected_keys: Vec<String> = vsign::DEVICE
            .iter()
            .filter(|(k, _)| *k != "device_id" && *k != "iid")
            .map(|(k, _)| (*k).to_string())
            .collect();
        let keys: Vec<String> = device.iter().map(|(k, _)| k.clone()).collect();
        assert_eq!(keys, expected_keys);
    }

    #[test]
    fn set_cookies_merge_by_name_and_keep_order() {
        let mut session = PhoneLoginSession::new();
        session.merge_set_cookies(&[
            ("set-cookie".into(), "sid_guard=abc; Path=/; HttpOnly".into()),
            ("Set-Cookie".into(), "sessionid=xyz; path=/".into()),
            ("content-type".into(), "application/json".into()),
        ]);
        session.merge_set_cookies(&[
            ("set-cookie".into(), "sid_guard=fresh; Max-Age=1".into()),
            ("set-cookie".into(), "uid_tt=1".into()),
        ]);
        assert_eq!(session.cookie_header(), "sid_guard=fresh; sessionid=xyz; uid_tt=1");
        assert_eq!(session.cookie_value("sessionid"), Some("xyz"));
    }

    #[test]
    fn retry_gate_reject_sets_cooldown_and_check_reports_it() {
        RETRY_UNTIL_MS.store(0, Ordering::Relaxed);
        let message = retry_gate_reject(120);
        assert!(message.contains("120 秒"));
        assert!(retry_gate_check().is_err());
        let seconds = retry_gate_remaining_seconds();
        assert!((100..=120).contains(&seconds), "剩余秒数应接近 120：{seconds}");
        RETRY_UNTIL_MS.store(0, Ordering::Relaxed);
        assert!(retry_gate_check().is_ok());
    }

    #[test]
    fn describe_appends_error_code() {
        let data = json!({"description": "验证码错误", "error_code": 1102});
        assert_eq!(describe(&data).unwrap(), "验证码错误（错误码 1102）");
        assert!(describe(&json!({})).is_none());
    }
}
