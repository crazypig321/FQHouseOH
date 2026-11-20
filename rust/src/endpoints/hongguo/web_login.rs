//! 红果官网登录会话（扫码路径），移植自 hongguoTV（GPL-3.0）。
//! `WebLogin`：hongguoduanju.com Web passport 协议，免签名（csrf cookie）。
//! 一次登录一个 [`WebLoginSession`]，cookie 是凭据：只留在本结构体里，不进日志。
//! 验证码登录不走本模块：官方网页 send_code 对非浏览器客户端一律滑块，
//! 已改走 [`super::phone_login`]（security.snssdk.com 签名移动端点）。
use serde_json::Value;

use crate::timeutil::now_millis;
use crate::upstream::okhttp::okhttp_transport;

pub(crate) const BASE: &str = "https://hongguoduanju.com";
const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
/// hongguoTV PhoneConsole 对解码后 QR 图片限 128KB，这里对 data URL
/// 字符串取同量级上限。
const QR_IMAGE_MAX_LEN: usize = 200 * 1024;
const RESPONSE_LIMIT: usize = 2 * 1024 * 1024;

/// hongguoTV `JSONObject.str`：null/缺失→空串，标量转串后 trim。
fn field_str(value: &Value, key: &str) -> String {
    match value.get(key) {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(_) => String::new(),
    }
}

/// hongguoTV `optLong(key, default)`：数值或可解析字符串，否则默认值。
fn field_i64(value: &Value, key: &str, default: i64) -> i64 {
    match value.get(key) {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(Value::String(s)) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
    .unwrap_or(default)
}

/// hongguoTV `WebLogin.checked`：data 缺失报格式异常；message 非 success
/// 时拼 `description（错误码 N）`，滑块风控换成扫码指引。
fn checked(reply: &Value) -> Result<&Value, String> {
    let data = reply
        .get("data")
        .filter(|v| v.is_object())
        .ok_or_else(|| "官网登录返回格式异常".to_string())?;
    let message = field_str(reply, "message");
    if message != "success" {
        let code = field_i64(data, "error_code", -1);
        let message = if data.get("verify_center_decision_conf").is_some() {
            // 1105 滑块风控（扫码 Web 端点偶发）：提示可操作的重试路径
            // 而不是只引导换登录方式。
            "红果要求滑块验证（可能因近期尝试过多），请稍后再试或更换网络，也可改用验证码登录".to_string()
        } else {
            let description = field_str(data, "description");
            if description.is_empty() {
                "官网登录失败".to_string()
            } else {
                description
            }
        };
        return Err(format!("{message}（错误码 {code}）"));
    }
    Ok(data)
}

/// hongguoTV `WebLogin.Qr.expiresIn`：`expire_time` 秒数与绝对时间戳
///（>1e9）两种写法，统一换算到 0..600 的剩余秒数。
fn qr_seconds(expiry: i64, now_secs: i64) -> i64 {
    if expiry > 1_000_000_000 {
        (expiry - now_secs).clamp(0, 600)
    } else {
        expiry.clamp(0, 600)
    }
}

/// 登录确认跳转地址：仅允许 https://hongguoduanju.com（站内相对地址用
/// BASE 拼，hongguoTV `finishRedirect` 同款站点闸）。
fn official_url(value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 8192 || value.chars().any(|c| c.is_control()) {
        return Err("登录确认地址无效".to_string());
    }
    let url = if value.starts_with('/') {
        format!("{BASE}{value}")
    } else {
        value.to_string()
    };
    let Some(rest) = url.strip_prefix("https://") else {
        return Err("登录确认跳转到不支持的站点。".to_string());
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = host.split(':').next().unwrap_or("");
    if host != "hongguoduanju.com" {
        return Err("登录确认跳转到不支持的站点。".to_string());
    }
    Ok(url)
}

pub(crate) struct Qr {
    pub image: String,
    pub expires_in: i64,
}

/// 一次红果官网扫码登录：cookie jar + 二维码 token。
/// 单用户本地服务，会话由调用方（`account_hongguo`）串行持有。
pub(crate) struct WebLoginSession {
    cookies: Vec<(String, String)>,
    token: String,
}

impl WebLoginSession {
    pub(crate) fn new() -> Self {
        WebLoginSession {
            cookies: Vec::new(),
            token: String::new(),
        }
    }

    pub(crate) fn has_token(&self) -> bool {
        !self.token.is_empty()
    }

    /// hongguoTV `WebLogin.hasSession`：sessionid / sessionid_ss 任一存在。
    pub(crate) fn has_session(&self) -> bool {
        self.cookie_value("sessionid").is_some() || self.cookie_value("sessionid_ss").is_some()
    }

    fn cookie_value(&self, name: &str) -> Option<&str> {
        self.cookies
            .iter()
            .rev()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }

    /// Set-Cookie 逐条并入：`name=value`（`;` 前段），按名去重、后写覆盖。
    fn merge_set_cookies(&mut self, headers: &[(String, String)]) {
        for (key, line) in headers {
            if !key.eq_ignore_ascii_case("set-cookie") {
                continue;
            }
            let Some((pair, _attrs)) = line.split_once(';') else {
                continue;
            };
            let Some((name, value)) = pair.split_once('=') else {
                continue;
            };
            let name = name.trim();
            let value = value.trim();
            if name.is_empty() || value.is_empty() {
                continue;
            }
            self.cookies.retain(|(n, _)| n != name);
            self.cookies.push((name.to_string(), value.to_string()));
        }
    }

    /// hongguoTV `WebLogin.credentials`：全部会话 cookie 拼 `name=value; …`。
    pub(crate) fn cookie_header(&self) -> String {
        self.cookies
            .iter()
            .map(|(n, v)| format!("{n}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// hongguoTV `WebLogin.call`：公共 query（aid/language）+ csrf 头 +
    /// 表单 POST / GET，Set-Cookie 并回会话，响应按 JSON 解析。
    async fn call(&mut self, path: &str, data: Option<&str>, params: &[(&str, &str)]) -> Result<Value, String> {
        let mut query = String::from(
            "aid=513755&passport_jssdk_version=3.4.10&passport_jssdk_type=normal\
             &account_sdk_source=web&is_from_ttaccountsdk=1&language=zh",
        );
        for (key, value) in params {
            query.push('&');
            query.push_str(key);
            query.push('=');
            query.push_str(&encode_query(value));
        }
        let url = format!("{BASE}{path}?{query}");
        let mut headers: Vec<(String, String)> = vec![
            ("User-Agent".into(), UA.into()),
            ("Referer".into(), format!("{BASE}/")),
            ("Origin".into(), BASE.into()),
            ("Accept".into(), "application/json, text/javascript".into()),
            // OkHttp 默认收 gzip；gzip 由传输层按 Content-Encoding/魔数解压。
            ("Accept-Encoding".into(), "gzip".into()),
        ];
        if let Some(csrf) = self.cookie_value("passport_csrf_token") {
            headers.push(("x-tt-passport-csrf-token".into(), csrf.to_string()));
        }
        let cookie = self.cookie_header();
        if !cookie.is_empty() {
            headers.push(("Cookie".into(), cookie));
        }
        let mut body: Option<Vec<u8>> = None;
        if let Some(data) = data {
            headers.push((
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            ));
            body = Some(data.as_bytes().to_vec());
        }
        let client = okhttp_transport().map_err(|_| "无法初始化红果登录连接。".to_string())?;
        let upstream = match body {
            Some(body) => client
                .request_body_bounded("POST", &url, &headers, body, RESPONSE_LIMIT)
                .await,
            None => client
                .request_bounded("GET", &url, &headers, RESPONSE_LIMIT)
                .await,
        }
        .map_err(|_| "红果登录服务暂不可用，请检查网络后重试".to_string())?;
        self.merge_set_cookies(&upstream.headers);
        if !(200..300).contains(&(upstream.status as u32)) {
            return Err(format!("红果登录请求失败（HTTP {}）", upstream.status));
        }
        if upstream.body.is_empty() {
            return Err("红果登录接口返回空响应，请稍后重试。".to_string());
        }
        serde_json::from_slice(&upstream.body)
            .map_err(|_| "红果登录响应不是有效的 JSON 数据".to_string())
    }

    /// 获取登录二维码（data URL）与剩余秒数，token 留在会话里。
    pub(crate) async fn qr(&mut self) -> Result<Qr, String> {
        let next = format!("{BASE}/");
        let reply = self.call("/passport/web/get_qrcode/", None, &[("next", &next)]).await?;
        let data = checked(&reply)?;
        let token = field_str(data, "token");
        if token.is_empty() {
            return Err("官网登录返回格式异常".to_string());
        }
        let image = field_str(data, "qrcode");
        if !image.starts_with("data:image/") || image.len() > QR_IMAGE_MAX_LEN {
            return Err("官网二维码数据无效。".to_string());
        }
        let expiry = field_i64(data, "expire_time", 180);
        let seconds = qr_seconds(expiry, now_millis() / 1000);
        self.token = token;
        Ok(Qr { image, expires_in: seconds })
    }

    /// 扫码状态轮询：过期报错，确认后完成官方确认跳转。
    /// 返回是否已拿到会话 cookie（未确认前为 false）。
    pub(crate) async fn poll(&mut self) -> Result<bool, String> {
        let token = self.token.clone();
        if token.is_empty() {
            return Err("请先获取二维码。".to_string());
        }
        let next = format!("{BASE}/");
        let reply = self
            .call(
                "/passport/web/check_qrconnect/",
                None,
                &[("next", &next), ("token", &token)],
            )
            .await?;
        let data = checked(&reply)?;
        let status = field_str(data, "status");
        if status == "5" || status == "expired" {
            return Err("二维码已过期，请重新获取".to_string());
        }
        if status == "3" || status == "confirmed" {
            let redirect = field_str(data, "redirect_url");
            if !redirect.is_empty() {
                self.finish_redirect(&redirect).await?;
            }
        }
        Ok(self.has_session())
    }

    /// hongguoTV `WebLogin.finishRedirect`：最多 5 跳，只跟
    /// hongguoduanju.com，cookie 不出域；每跳收 Set-Cookie 并回会话。
    async fn finish_redirect(&mut self, value: &str) -> Result<(), String> {
        let mut url = official_url(value)?;
        for _ in 0..5 {
            let mut headers: Vec<(String, String)> = vec![
                ("User-Agent".into(), UA.into()),
                ("Referer".into(), format!("{BASE}/")),
                ("Accept-Encoding".into(), "gzip".into()),
            ];
            let cookie = self.cookie_header();
            if !cookie.is_empty() {
                headers.push(("Cookie".into(), cookie));
            }
            let client = okhttp_transport().map_err(|_| "无法初始化红果登录连接。".to_string())?;
            let upstream = client
                .request_bounded("GET", &url, &headers, RESPONSE_LIMIT)
                .await
                .map_err(|_| "红果登录服务暂不可用，请检查网络后重试".to_string())?;
            self.merge_set_cookies(&upstream.headers);
            if (300..400).contains(&(upstream.status as u32)) {
                match upstream.header("location") {
                    Some(location) if !location.trim().is_empty() => {
                        url = official_url(location)?;
                        continue;
                    }
                    _ => return Ok(()),
                }
            }
            if !(200..300).contains(&(upstream.status as u32)) {
                return Err(format!("登录确认失败（HTTP {}）", upstream.status));
            }
            return Ok(());
        }
        Err("登录确认跳转次数过多".to_string())
    }

    /// hongguoTV `WebLogin.credentials`：确认登录态后调一次账号信息接口，
    /// 返回全部会话 cookie 串。
    pub(crate) async fn credentials(&mut self) -> Result<String, String> {
        if !self.has_session() {
            return Err("官网尚未下发登录态，请先在手机确认登录。".to_string());
        }
        let reply = self.call("/passport/account/info/v2/", None, &[]).await?;
        checked(&reply)?;
        Ok(self.cookie_header())
    }
}

/// okhttp `addQueryParameter` 同款 percent-encode：保留字母数字与
/// `-_.~`，其余 `%XX`（大写十六进制）。
fn encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// hongguoTV `PhoneLogin.format`：区号 + 本地号码拼平台手机号。
/// 大陆（86）：1 开头 11 位，原样返回；境外：`+区号 号码`
///（区号 1..3 位，区号 + 号码合计至多 15 位，号码至少 4 位）。
/// 号码里的非数字字符一律忽略，去一个开头 0。
fn format_mobile(country_code: &str, number: &str) -> Result<String, String> {
    let cc: String = country_code
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect();
    let all_digits: String = number.chars().filter(|c| c.is_ascii_digit()).collect();
    // Kotlin removePrefix("0")：只去一个开头 0。
    let digits: &str = all_digits.strip_prefix('0').unwrap_or(&all_digits);
    if cc == "86" {
        if digits.len() != 11 || !digits.starts_with('1') {
            return Err("大陆手机号是 1 开头的 11 位数字。".to_string());
        }
        return Ok(digits.to_string());
    }
    if cc.is_empty() || cc.len() > 3 || !cc.starts_with(|c| ('1'..='9').contains(&c)) {
        return Err("区号限 1..3 位数字。".to_string());
    }
    if digits.len() < 4 || cc.len() + digits.len() > 15 {
        return Err("号码长度不对：区号加号码最多 15 位。".to_string());
    }
    Ok(format!("+{cc} {digits}"))
}

/// hongguoTV `PhoneLogin.parse`：单串输入 `13800138000`（大陆）或
/// `+区号 号码` / `+区号-号码`（境外，如 `+886-0912345678`）。
pub(crate) fn parse_mobile(raw: &str) -> Result<String, String> {
    let text = raw.trim();
    if !text.starts_with('+') {
        return format_mobile("86", text);
    }
    let cc: String = text[1..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    let rest = &text[1 + cc.len()..];
    if !(rest.starts_with('-') || rest.starts_with(' ')) {
        return Err("境外号码写成 +区号 号码，如 +886 0912345678".to_string());
    }
    format_mobile(&cc, rest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_mobile_accepts_mainland_and_foreign_forms() {
        assert_eq!(parse_mobile("13800138000").unwrap(), "13800138000");
        assert_eq!(parse_mobile(" 138 0013 8000 ").unwrap(), "13800138000");
        assert_eq!(parse_mobile("+86 13800138000").unwrap(), "13800138000");
        assert_eq!(parse_mobile("+886-0912345678").unwrap(), "+886 912345678");
        assert_eq!(parse_mobile("+1 2125551234").unwrap(), "+1 2125551234");
    }

    #[test]
    fn parse_mobile_rejects_bad_input_with_readable_errors() {
        assert_eq!(parse_mobile("123").unwrap_err(), "大陆手机号是 1 开头的 11 位数字。");
        assert_eq!(parse_mobile("23800138000").unwrap_err(), "大陆手机号是 1 开头的 11 位数字。");
        assert_eq!(parse_mobile("+8613800138000").unwrap_err(), "境外号码写成 +区号 号码，如 +886 0912345678");
        assert_eq!(parse_mobile("+").unwrap_err(), "境外号码写成 +区号 号码，如 +886 0912345678");
        assert_eq!(parse_mobile("+886123").unwrap_err(), "境外号码写成 +区号 号码，如 +886 0912345678");
        assert_eq!(parse_mobile("+886 123").unwrap_err(), "号码长度不对：区号加号码最多 15 位。");
        assert_eq!(parse_mobile("+086 13800138000").unwrap_err(), "区号限 1..3 位数字。");
    }

    #[test]
    fn format_mobile_strips_separators_and_one_leading_zero() {
        assert_eq!(format_mobile("886", "(0912) 345-678").unwrap(), "+886 912345678");
        // removePrefix("0") 只去一个 0。
        assert_eq!(format_mobile("886", "00912").unwrap(), "+886 0912");
        assert_eq!(format_mobile("086", "13800138000").unwrap_err(), "区号限 1..3 位数字。");
    }

    #[test]
    fn qr_seconds_takes_relative_and_absolute_forms() {
        assert_eq!(qr_seconds(180, 0), 180);
        assert_eq!(qr_seconds(700, 0), 600);
        assert_eq!(qr_seconds(-1, 0), 0);
        assert_eq!(qr_seconds(1_700_000_0200, 1_700_000_0000), 200);
        assert_eq!(qr_seconds(1_700_000_0000, 1_700_000_0100), 0);
        assert_eq!(qr_seconds(1_800_000_0000, 0), 600);
    }

    #[test]
    fn checked_maps_errors_like_hongguotv() {
        let ok: Value =
            serde_json::from_str(r#"{"message":"success","data":{"token":"t"}}"#).unwrap();
        assert!(checked(&ok).is_ok());

        let described: Value = serde_json::from_str(
            r#"{"message":"error","data":{"error_code":1102,"description":"验证码错误"}}"#,
        )
        .unwrap();
        assert_eq!(
            checked(&described).unwrap_err(),
            "验证码错误（错误码 1102）"
        );

        let slider: Value = serde_json::from_str(
            r#"{"message":"error","data":{"error_code":1105,"verify_center_decision_conf":"challenge"}}"#,
        )
        .unwrap();
        assert_eq!(
            checked(&slider).unwrap_err(),
            "红果要求滑块验证（可能因近期尝试过多），请稍后再试或更换网络，也可改用验证码登录（错误码 1105）"
        );

        let no_data: Value = serde_json::from_str(r#"{"message":"success"}"#).unwrap();
        assert_eq!(checked(&no_data).unwrap_err(), "官网登录返回格式异常");
    }

    #[test]
    fn set_cookies_merge_by_name_and_detect_session() {
        let mut session = WebLoginSession::new();
        let headers: Vec<(String, String)> = vec![
            ("set-cookie".into(), "passport_csrf_token=csrf-1; Path=/; Secure".into()),
            ("set-cookie".into(), "empty=; Path=/".into()),
            ("set-cookie".into(), "malformed".into()),
            ("content-type".into(), "application/json".into()),
        ];
        session.merge_set_cookies(&headers);
        assert!(!session.has_session());
        assert_eq!(
            session.cookie_value("passport_csrf_token"),
            Some("csrf-1"),
            "csrf cookie 应已并入"
        );
        assert_eq!(session.cookie_header(), "passport_csrf_token=csrf-1");
        // 同名 cookie 后写覆盖。
        session.merge_set_cookies(&[
            ("Set-Cookie".into(), "sessionid=first; Path=/; Secure; HttpOnly".into()),
            ("Set-Cookie".into(), "sessionid=second; Path=/".into()),
            ("Set-Cookie".into(), "sessionid_ss=ss; Path=/".into()),
        ]);
        assert!(session.has_session());
        assert_eq!(
            session.cookie_header(),
            "passport_csrf_token=csrf-1; sessionid=second; sessionid_ss=ss"
        );
        assert_eq!(session.cookie_value("sessionid"), Some("second"));
    }

    #[test]
    fn official_url_only_allows_the_official_site() {
        assert_eq!(
            official_url("https://hongguoduanju.com/auth/complete").unwrap(),
            "https://hongguoduanju.com/auth/complete"
        );
        assert_eq!(
            official_url("/auth/complete").unwrap(),
            "https://hongguoduanju.com/auth/complete"
        );
        assert!(official_url("https://example.com/login")
            .unwrap_err()
            .contains("不支持的站点"));
        assert!(official_url("http://hongguoduanju.com/x")
            .unwrap_err()
            .contains("不支持的站点"));
        assert_eq!(
            official_url("https://user@hongguoduanju.com/x").unwrap(),
            "https://user@hongguoduanju.com/x"
        );
        assert_eq!(official_url("  ").unwrap_err(), "登录确认地址无效");
    }

    #[test]
    fn encode_query_percent_encodes_like_okhttp() {
        assert_eq!(
            encode_query("https://hongguoduanju.com/"),
            "https%3A%2F%2Fhongguoduanju.com%2F"
        );
        assert_eq!(encode_query("zh-CN"), "zh-CN");
        assert_eq!(encode_query("a b+c"), "a%20b%2Bc");
    }
}
