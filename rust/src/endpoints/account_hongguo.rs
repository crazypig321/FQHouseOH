//! 红果云端收藏只读采集 + 账号登录（扫码 / 手机验证码）。
//! 协议参考 hongguoTV（GPL-3.0）：收藏走 cookie 有界 POST body +
//! 生产验证的 vsign GET 签名套件（`CloudAccountClient.favorites` /
//! `parseFavorites`）；扫码走免签名的 Web passport 协议（`WebLogin`，
//! 见 [`hongguo::web_login`]）；验证码走官方签名移动端点
//! `security.snssdk.com`（`PhoneLogin`，见 [`hongguo::phone_login`]）。
//! cookie 是凭据：不进日志、不进设备池、不跟随重定向。

use serde::Deserialize;
use serde_json::{json, Value};

use crate::dispatch::{Request, Response};
use crate::endpoints::hongguo::phone_login::PhoneLoginSession;
use crate::endpoints::hongguo::vsign;
use crate::endpoints::hongguo::web_login::{self, WebLoginSession};
use crate::endpoints::Ctx;
use crate::timeutil::now_millis;
use crate::upstream::http::account_transport;

const RESPONSE_LIMIT: usize = 4 * 1024 * 1024;
const FAVORITES_API: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/bookshelf/video/info/v1/";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FavoritesRequest {
    cookie: String,
}

fn response(status: u16, payload: Value) -> Response {
    let mut response = Response::json(status, &payload);
    response
        .headers
        .push(("cache-control".into(), "no-store".into()));
    response
}

fn failure(status: u16, message: &str) -> Response {
    response(status, json!({ "success": false, "error": message }))
}

/// hongguoTV `JSONObject.str`：null/缺失返回空串，标量值转串后 trim。
fn field_str(value: &Value, key: &str) -> String {
    match value.get(key) {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(_) => String::new(),
    }
}

/// hongguoTV `optInt`/`optLong`：数值或可解析字符串，否则 None。
fn field_i64(value: &Value, key: &str) -> Option<i64> {
    match value.get(key) {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(Value::String(s)) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn first_non_blank(values: &[String]) -> String {
    values
        .iter()
        .find(|v| !v.is_empty())
        .cloned()
        .unwrap_or_default()
}

/// hongguoTV `cleanUrl`：解转义 JSON/HTML 转义的 URL。
fn clean_url(s: &str) -> String {
    s.replace("\\/", "/")
        .replace("\\u002F", "/")
        .replace("\\u002f", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
}

fn valid_series_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 30 && id.bytes().all(|b| b.is_ascii_digit())
}

/// hongguoTV `parseFavorites` 的 tags 段：`category_schema` JSON 数组名
/// （≤5，` · ` 连接），解析失败回退 `video.category`。
fn category_tags(row: &Value, video: &Value) -> String {
    let schema = field_str(row, "category_schema");
    let items = serde_json::from_str::<Value>(&schema)
        .ok()
        .and_then(|parsed| parsed.as_array().cloned());
    let mut names: Vec<String> = Vec::new();
    if let Some(items) = items {
        for item in items {
            let name = field_str(&item, "name");
            if !name.is_empty() {
                names.push(name);
                if names.len() == 5 {
                    break;
                }
            }
        }
    }
    let joined = names.join(" · ");
    if joined.is_empty() {
        field_str(video, "category")
    } else {
        joined
    }
}

struct Favorite {
    id: String,
    title: String,
    cover: String,
    intro: String,
    episodes: i64,
    tags: String,
    collected_at: i64,
}

/// hongguoTV `CloudAccountClient.parseFavorites`（协议参考，语义逐行对齐）：
/// `data.video_shelf_info` 行 → 归一化条目；秒级时间戳 ×1000；
/// 按收藏时间降序去重；畸形结构报错而不是当作空收藏。
fn parse_favorites(raw: &Value) -> Result<Vec<Favorite>, &'static str> {
    let data = raw
        .get("data")
        .filter(|v| v.is_object())
        .ok_or("账户收藏数据格式已变化")?;
    let shelf = data
        .get("video_shelf_info")
        .ok_or("账户收藏列表格式已变化")?;
    let rows = match shelf {
        Value::Null => Vec::new(),
        Value::Array(rows) => rows.clone(),
        _ => return Err("账户收藏列表格式已变化"),
    };
    let mut out: Vec<Favorite> = Vec::new();
    for row in &rows {
        if !row.is_object() {
            continue;
        }
        let video = row.get("video_data").filter(|v| v.is_object()).unwrap_or(row);
        let id = first_non_blank(&[
            field_str(video, "series_id"),
            field_str(row, "series_id"),
            field_str(row, "book_id"),
        ]);
        let title = first_non_blank(&[
            field_str(row, "series_title"),
            field_str(video, "title"),
            field_str(row, "book_name"),
        ]);
        if !valid_series_id(&id) || title.is_empty() {
            continue;
        }
        let cover = first_non_blank(&[
            field_str(row, "series_cover_url"),
            field_str(video, "cover"),
            field_str(video, "cover_url"),
            field_str(video, "thumb_url"),
            field_str(row, "thumb_url"),
        ]);
        let episodes = field_i64(video, "episode_cnt")
            .or_else(|| field_i64(video, "episode_count"))
            .or_else(|| field_i64(row, "episode_cnt"))
            .unwrap_or(0);
        let intro = first_non_blank(&[
            field_str(row, "series_intro"),
            field_str(video, "video_desc"),
            field_str(row, "abstract"),
        ]);
        let mut collected_at = field_i64(row, "collect_time").unwrap_or(0).max(0);
        if (1..=9_999_999_999).contains(&collected_at) {
            collected_at *= 1000;
        }
        out.push(Favorite {
            id,
            title,
            cover: clean_url(&cover),
            intro,
            episodes,
            tags: category_tags(row, video),
            collected_at,
        });
    }
    if !rows.is_empty() && out.is_empty() {
        return Err("账户收藏条目格式已变化");
    }
    out.sort_by(|a, b| b.collected_at.cmp(&a.collected_at));
    let mut seen = std::collections::HashSet::new();
    out.retain(|favorite| seen.insert(favorite.id.clone()));
    Ok(out)
}

/// 与 account_library 相同的 cookie 闸：非空、≤12KB、可打印 ASCII、
/// 携带非空 `sessionid`/`sessionid_ss`/`sid_tt`。
fn valid_cookie(raw: &str) -> bool {
    let cookie = raw.trim();
    !cookie.is_empty()
        && cookie.len() <= 12 * 1024
        && cookie.bytes().all(|b| (0x20..=0x7e).contains(&b))
        && cookie.split(';').any(|part| {
            part.trim()
                .split_once('=')
                .is_some_and(|(key, value)| {
                    matches!(key, "sessionid" | "sessionid_ss" | "sid_tt") && !value.is_empty()
                })
        })
}

pub async fn handle(_ctx: &Ctx, req: &Request) -> Response {
    if req.method != "POST" {
        let mut response = failure(405, "请使用 POST 导入红果收藏");
        response.headers.push(("allow".into(), "POST".into()));
        return response;
    }
    if req.body.len() > crate::dispatch::ACCOUNT_REQUEST_BODY_LIMIT || !req.query.is_empty() {
        return failure(400, "导入参数无效或过长");
    }
    let input: FavoritesRequest = match serde_json::from_slice(&req.body) {
        Ok(input) => input,
        Err(_) => return failure(400, "导入参数无效"),
    };
    if !valid_cookie(&input.cookie) {
        return failure(400, "未取得有效登录态，请重新登录");
    }
    let cookie = input.cookie.trim();
    // 与搜索 GET 同 host/aid/设备表：固定设备 + 72232 覆盖 + cjs 签名套件。
    let signed = vsign::signed_bookapi_get(FAVORITES_API, &vsign::app_device(), now_millis());
    let mut headers = signed.headers;
    headers.push(("Cookie".into(), cookie.to_owned()));
    // cookie 请求禁重试/禁重定向：共享 account_transport（不跟随重定向）。
    let client = match account_transport() {
        Ok(client) => client,
        Err(_) => return failure(503, "无法初始化红果收藏连接"),
    };
    let upstream = match client
        .request_bounded("GET", &signed.url, &headers, RESPONSE_LIMIT)
        .await
    {
        Ok(upstream) => upstream,
        Err(_) => return failure(502, "红果收藏接口暂不可用，请稍后重试"),
    };
    if !(200..300).contains(&(upstream.status as u32)) {
        return failure(
            502,
            &format!("红果收藏请求失败（HTTP {}），请重新登录或稍后重试", upstream.status),
        );
    }
    if upstream.body.is_empty() {
        return failure(502, "红果收藏接口返回空响应，请稍后重试");
    }
    let raw: Value = match serde_json::from_slice(&upstream.body) {
        Ok(raw) => raw,
        Err(_) => return failure(502, "红果收藏响应不是有效的 JSON 数据"),
    };
    let code = raw.get("code").and_then(Value::as_i64).unwrap_or(-1);
    if code != 0 {
        return failure(
            502,
            &format!("账号接口不可用（错误码 {code}），请重新登录或稍后重试"),
        );
    }
    let favorites = match parse_favorites(&raw) {
        Ok(favorites) => favorites,
        Err(message) => return failure(502, message),
    };
    let favorites: Vec<Value> = favorites
        .iter()
        .map(|favorite| {
            json!({
                "id": favorite.id,
                "title": favorite.title,
                "cover": favorite.cover,
                "intro": favorite.intro,
                "episodes": favorite.episodes,
                "tags": favorite.tags,
                "collectedAt": favorite.collected_at,
            })
        })
        .collect();
    response(200, json!({ "code": 0, "favorites": favorites }))
}

// --- 官网登录（扫码 / 手机验证码） ----------------------------------------

/// 登录子路由：扫码共用一个 [`WebLoginSession`]（进程内存，
/// tokio 异步锁；单用户本地服务，登录操作天然串行）。
static LOGIN_SESSION: tokio::sync::Mutex<Option<WebLoginSession>> =
    tokio::sync::Mutex::const_new(None);

/// 验证码登录会话（hongguoTV `PhoneLogin` 签名移动端点）；
/// RetryGate（error_code 7 退避）是 phone_login 内的进程级状态。
static PHONE_LOGIN: tokio::sync::Mutex<Option<PhoneLoginSession>> =
    tokio::sync::Mutex::const_new(None);

pub enum LoginAction {
    Qr,
    Poll,
    Send,
    Verify,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginSendRequest {
    mobile: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginVerifyRequest {
    code: String,
}

/// `/api/v1/account/hongguo/login/{qr|poll|send|verify}`：
/// qr 新开会话返回 data URL 二维码；poll 返回 waiting/confirmed
///（confirmed 时完成官方确认跳转并打包 cookie 返回，随后清会话）；
/// send 走官方签名移动端点（security.snssdk.com）发短信；
/// verify 验码登录。本地参数校验回 400，上游业务失败按消息回 502。
pub async fn handle_login(_ctx: &Ctx, req: &Request, action: LoginAction) -> Response {
    if req.method != "POST" {
        let mut response = failure(405, "请使用 POST 登录红果账号");
        response.headers.push(("allow".into(), "POST".into()));
        return response;
    }
    if req.body.len() > crate::dispatch::ACCOUNT_REQUEST_BODY_LIMIT || !req.query.is_empty() {
        return failure(400, "登录参数无效或过长");
    }
    match action {
        LoginAction::Qr => {
            let mut guard = LOGIN_SESSION.lock().await;
            let mut session = WebLoginSession::new();
            match session.qr().await {
                Ok(qr) => {
                    *guard = Some(session);
                    response(
                        200,
                        json!({ "code": 0, "image": qr.image, "expiresIn": qr.expires_in }),
                    )
                }
                Err(message) => failure(502, &message),
            }
        }
        LoginAction::Poll => {
            let mut guard = LOGIN_SESSION.lock().await;
            let Some(session) = guard.as_mut() else {
                return failure(400, "请先获取二维码");
            };
            if !session.has_token() {
                return failure(400, "请先获取二维码");
            }
            match session.poll().await {
                Ok(true) => {
                    let cookie = match session.credentials().await {
                        Ok(cookie) => cookie,
                        Err(message) => return failure(502, &message),
                    };
                    *guard = None;
                    response(200, json!({ "code": 0, "status": "confirmed", "cookie": cookie }))
                }
                Ok(false) => response(200, json!({ "code": 0, "status": "waiting" })),
                Err(message) => failure(502, &message),
            }
        }
        LoginAction::Send => {
            let input: LoginSendRequest = match serde_json::from_slice(&req.body) {
                Ok(input) => input,
                Err(_) => return failure(400, "登录参数无效"),
            };
            // hongguoTV PhoneConsole：手机号先限长再归一化。
            if input.mobile.len() > 32 {
                return failure(400, "手机号过长");
            }
            let mobile = match web_login::parse_mobile(&input.mobile) {
                Ok(mobile) => mobile,
                Err(message) => return failure(400, &message),
            };
            // 官方 App 的签名移动端点（security.snssdk.com）：一次发码一个新会话，
            // RetryGate（error_code 7 退避）进程级共享。
            let mut guard = PHONE_LOGIN.lock().await;
            let mut session = PhoneLoginSession::new();
            match session.send(&mobile).await {
                Ok(sent) => {
                    *guard = Some(session);
                    response(
                        200,
                        json!({
                            "code": 0,
                            "maskedMobile": sent.masked_mobile,
                            "retrySeconds": sent.retry_seconds,
                        }),
                    )
                }
                Err(message) => failure(502, &message),
            }
        }
        LoginAction::Verify => {
            let input: LoginVerifyRequest = match serde_json::from_slice(&req.body) {
                Ok(input) => input,
                Err(_) => return failure(400, "登录参数无效"),
            };
            // hongguoTV PhoneConsole：`[0-9]{4,8}`。
            let code = input.code.trim();
            if code.len() < 4 || code.len() > 8 || !code.bytes().all(|b| b.is_ascii_digit()) {
                return failure(400, "验证码是 4—8 位数字");
            }
            let mut guard = PHONE_LOGIN.lock().await;
            let Some(session) = guard.as_mut() else {
                return failure(400, "请先发送验证码");
            };
            if !session.has_sent() {
                return failure(400, "请先发送验证码");
            }
            let result = session.verify(code).await;
            match result {
                Ok(cookie) => {
                    *guard = None;
                    response(200, json!({ "code": 0, "cookie": cookie }))
                }
                Err(message) => failure(502, &message),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(raw: &str) -> Result<Vec<Favorite>, &'static str> {
        parse_favorites(&serde_json::from_str(raw).expect("fixture json"))
    }

    #[test]
    fn keeps_metadata_order_and_dedupes() {
        // CloudFavoritesTest.videoShelfUsesCurrentCredentialsAndKeepsMetadataAndCollectionOrder
        let rows = parse(
            r#"{"code":0,"data":{"video_shelf_info":[
              {"video_data":{"series_id":"1","episode_cnt":12},"series_title":"第一部","series_cover_url":"https:\/\/example.com\/a.jpg","series_intro":"简介","collect_time":100},
              {"video_data":{"series_id":"2","title":"第二部","category":"系统"},"collect_time":200},
              {"video_data":{"series_id":"1"},"series_title":"较早的重复条目","collect_time":50}
            ]}}"#,
        )
        .expect("parse");
        assert_eq!(vec!["2", "1"], rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>());
        assert_eq!(200_000, rows[0].collected_at);
        assert_eq!("第二部", rows[0].title);
        assert_eq!("系统", rows[0].tags);
        assert_eq!("第一部", rows[1].title);
        assert_eq!(12, rows[1].episodes);
        assert_eq!("https://example.com/a.jpg", rows[1].cover);
        assert_eq!("简介", rows[1].intro);
    }

    #[test]
    fn malformed_shelf_never_looks_like_empty() {
        for raw in [
            "{}",
            r#"{"data":{}}"#,
            r#"{"data":{"video_shelf_info":{}}}"#,
            r#"{"data":{"video_shelf_info":[{"series_title":"missing id"}]}}"#,
        ] {
            assert!(parse(raw).is_err(), "raw {raw} must not parse as empty");
        }
        assert!(parse(r#"{"data":{"video_shelf_info":[]}}"#).unwrap().is_empty());
        assert!(
            parse(r#"{"data":{"video_shelf_info":null}}"#)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn category_schema_names_win_over_video_category() {
        let rows = parse(
            r#"{"data":{"video_shelf_info":[
              {"video_data":{"series_id":"7","category":"回退"},"series_title":"剧","category_schema":"[{\"name\":\"古装\"},{\"name\":\"恋爱\"},{\"name\":\"\"},{\"name\":\"逆袭\"}]","collect_time":1}
            ]}}"#,
        )
        .expect("parse");
        assert_eq!("古装 · 恋爱 · 逆袭", rows[0].tags);
    }

    #[test]
    fn category_schema_caps_at_five_names() {
        let schema = (1..=7)
            .map(|i| format!("{{\\\"name\\\":\\\"标签{i}\\\"}}"))
            .collect::<Vec<_>>()
            .join(",");
        let rows = parse(&format!(
            r#"{{"data":{{"video_shelf_info":[{{"video_data":{{"series_id":"7"}},"series_title":"剧","category_schema":"[{schema}]","collect_time":1}}]}}}}"#
        ))
        .expect("parse");
        assert_eq!("标签1 · 标签2 · 标签3 · 标签4 · 标签5", rows[0].tags);
    }

    #[test]
    fn millisecond_collect_time_is_kept_as_is() {
        let rows = parse(
            r#"{"data":{"video_shelf_info":[
              {"video_data":{"series_id":"9"},"series_title":"剧","collect_time":1731300000000}
            ]}}"#,
        )
        .expect("parse");
        assert_eq!(1_731_300_000_000, rows[0].collected_at);
    }

    #[test]
    fn episode_count_falls_back_to_row_field() {
        let rows = parse(
            r#"{"data":{"video_shelf_info":[
              {"video_data":{"series_id":"3","title":"剧"},"episode_cnt":8,"collect_time":1}
            ]}}"#,
        )
        .expect("parse");
        assert_eq!(8, rows[0].episodes);
    }

    #[test]
    fn id_falls_back_to_row_series_id_and_book_id() {
        let rows = parse(
            r#"{"data":{"video_shelf_info":[
              {"video_data":{},"series_id":"456","book_name":"按行取","collect_time":1},
              {"video_data":{},"book_id":"789","book_name":"按书取","collect_time":2}
            ]}}"#,
        )
        .expect("parse");
        assert_eq!(vec!["789", "456"], rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>());
    }

    #[test]
    fn clean_url_unescapes_json_and_html() {
        assert_eq!(
            "https://a.com/b.jpg?x=1&y=2&z=3",
            clean_url(r"https:\/\/a.com\/b.jpg?x=1\u0026y=2&amp;z=3")
        );
        assert_eq!("https://a.com/c.jpg", clean_url(r"https:\u002f/a.com/c.jpg"));
    }

    #[test]
    fn cookie_gate_matches_account_library_rules() {
        assert!(valid_cookie("sessionid=abc; sid_tt=1"));
        assert!(valid_cookie("sid_guard=x; sessionid_ss=y"));
        assert!(!valid_cookie("not-a-session"));
        assert!(!valid_cookie("sessionid="));
        assert!(!valid_cookie(""));
        assert!(!valid_cookie("sessionid=你好世界"));
    }

    #[test]
    fn signed_favorites_request_targets_bookshelf_base() {
        let signed = vsign::signed_bookapi_get(
            FAVORITES_API,
            &vsign::app_device(),
            1_700_000_000_000,
        );
        assert!(signed.url.starts_with(FAVORITES_API));
        assert!(signed.url.contains("ts="));
        assert!(signed.url.contains("_rticket="));
        assert!(signed.url.contains("version_code=72232"));
        assert!(signed.url.contains("version_name=7.2.2.32"));
        assert!(signed.headers.iter().any(|(k, _)| k == "x-gorgon"));
        assert!(signed.headers.iter().any(|(k, _)| k == "x-helios"));
        assert!(signed.headers.iter().any(|(k, _)| k == "x-medusa"));
    }
}
