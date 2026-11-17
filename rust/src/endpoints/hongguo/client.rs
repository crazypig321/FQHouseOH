//! 红果 App 的 HTTP 层：comment 签名 POST（弹幕）与 hongguoduanju.com 网页抓取。
//!
//! 请求全部走 [`UpstreamMode::NoSign`]（红果有自己的签名套件，见 [`super::sign`]），
//! 不会碰番茄设备池。两类身份：
//! - **comment 设备**：弹幕用，随机 19 位数字即可、免注册（实测结论，
//!   guoapp 也不为 comment 注册设备）。
//! - **网页**：免签名浏览器 UA。
//!
//! 搜索/详情等 player 请求已切到新签名套件（[`super::vsign`]，
//! 固定硬编码设备，免注册），不在本文件。

use std::sync::Arc;

use serde_json::{json, Value};

use crate::endpoints::base::{Upstream, UpstreamMode, UpstreamRequestSpec, UA_WINDOWS_BROWSER};
use crate::endpoints::hongguo::sign::{new_nonce, random_device_id, sign_comment_request};
use crate::endpoints::util::{encode_query, raw_json};
use crate::error::{ApiError, ApiResult};
use crate::timeutil::{now_millis, now_secs};
use crate::upstream::UpstreamClient;

pub(crate) const HOST_HONGGUO_APP: &str = "https://api5-normal-sinfonlineb.fqnovel.com";
pub(crate) const HOST_HONGGUO_WEB: &str = "https://hongguoduanju.com";
pub(crate) const HONGGUO_AID: &str = "8662";
/// 弹幕窗口硬上限（guoapp `danmakuMaxDurationMS`）。
pub(crate) const DANMAKU_MAX_DURATION_MS: i64 = 24 * 60 * 60 * 1000;

pub(crate) const UA_HONGGUO_APP: &str = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";

fn app_query_pairs(device_id: &str, install_id: &str) -> Vec<(String, String)> {
    [
        ("aid", HONGGUO_AID),
        ("app_name", "novelread"),
        ("version_code", "73532"),
        ("version_name", "7.3.5.32"),
        ("manifest_version_code", "73532"),
        ("update_version_code", "73532"),
        ("channel", "update_64"),
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("device_type", "25053RT47C"),
        ("device_brand", "Redmi"),
        ("language", "zh"),
        ("os_api", "36"),
        ("os_version", "16"),
        ("resolution", "1280*2772"),
        ("dpi", "520"),
        ("ac", "wifi"),
        ("device_id", device_id),
        ("iid", install_id),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

/// 注册设备号对（19 位数字，未注册的随机号），弹幕/comment 请求专用。
pub(crate) fn fresh_comment_device() -> (String, String) {
    (random_device_id(), random_device_id())
}

pub(crate) fn is_numeric_id(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

/// comment 签名 POST（弹幕），`series_id` 是红果剧集 id（business_param.book_id），
/// `vid` 是红果视频 id（group_id 与路径段）。`cursor` 为续拉串（首页空串，
/// hongguoTV TimedComments 同款）。响应原样返回给调用方透传。
pub(crate) async fn fetch_danmaku(
    up: &Arc<UpstreamClient>,
    device_id: &str,
    install_id: &str,
    series_id: &str,
    vid: &str,
    start_ms: i64,
    duration_ms: i64,
    cursor: &str,
) -> ApiResult<Value> {
    let body = json!({
        "aid": 8662,
        "business_param": {
            "book_id": series_id,
            "need_danmaku_guide_type": [1, 3, 4, 2],
            "playlet_item_duration": duration_ms,
            "start_offset_time": start_ms,
        },
        "comment_source": 601,
        "comment_type": 20,
        "compliance_status": 0,
        "count": 90,
        "cursor": cursor,
        "group_id": vid,
        "group_type": 30,
        "server_channel": 1000,
        "sort": 1,
    });
    let body =
        serde_json::to_vec(&body).map_err(|e| ApiError::internal(format!("序列化弹幕请求失败: {e}")))?;

    let mut params = app_query_pairs(device_id, install_id);
    params.push(("_rticket".to_string(), now_millis().to_string()));
    let query = encode_query(&params);
    let url = format!(
        "{}/novel/commentapi/comment/list/{}/v1/?{}",
        HOST_HONGGUO_APP, vid, query
    );

    let stamp = now_secs();
    let nonce = new_nonce();
    let mut headers = vec![
        ("User-Agent".to_string(), UA_HONGGUO_APP.to_string()),
        ("Accept".to_string(), "application/json".to_string()),
        ("X-XS-From-Web".to_string(), "0".to_string()),
        ("Sdk-Version".to_string(), "2".to_string()),
        ("Comment-Source".to_string(), "601".to_string()),
        ("Server-Channel".to_string(), "1000".to_string()),
        (
            "Content-Type".to_string(),
            "application/json; charset=utf-8".to_string(),
        ),
    ];
    headers.extend(sign_comment_request(&query, HONGGUO_AID, &nonce, stamp));

    let (raw, _) = Upstream::new(up.clone())
        .raw_with_headers(&UpstreamRequestSpec {
            mode: UpstreamMode::NoSign,
            method: Some("POST".to_string()),
            raw_url: Some(url),
            body: Some(body),
            headers,
            ..Default::default()
        })
        .await?;
    let result = raw_json(&raw)?;
    check_app_code(&result)?;
    Ok(result)
}

/// 抓 hongguoduanju.com 页面文本（免签名，浏览器 UA + Referer）。
pub(crate) async fn fetch_web_text(
    up: &Arc<UpstreamClient>,
    url: &str,
    referer: &str,
) -> ApiResult<String> {
    let (raw, _) = Upstream::new(up.clone())
        .raw_with_headers(&UpstreamRequestSpec {
            mode: UpstreamMode::NoSign,
            method: Some("GET".to_string()),
            raw_url: Some(url.to_string()),
            headers: vec![
                ("User-Agent".to_string(), UA_WINDOWS_BROWSER.to_string()),
                ("Referer".to_string(), referer.to_string()),
            ],
            ..Default::default()
        })
        .await?;
    Ok(String::from_utf8_lossy(&raw).into_owned())
}

/// guoapp `hongguoAppRequest` 的 code 校验：`code`/`Code`/`status_code`
/// 或 `BaseResp.StatusCode`，非 0 即失败。
fn check_app_code(result: &Value) -> ApiResult<()> {
    let obj = match result.as_object() {
        Some(o) => o,
        None => return Err(ApiError::internal("hq App 接口返回格式异常")),
    };
    let mut code = crate::json::first_map_string(obj, &["code", "Code", "status_code"]);
    if code.is_empty() {
        if let Some(base) = obj.get("BaseResp").and_then(|v| v.as_object()) {
            code = crate::json::first_map_string(base, &["StatusCode"]);
        }
    }
    if !code.is_empty() && code != "0" {
        let mut shown = code.clone();
        if shown.len() > 20 {
            shown.truncate(20);
        }
        return Err(ApiError::internal(format!("hq App 接口暂不可用（{shown}）")));
    }
    Ok(())
}

/// 弹幕窗口参数校验（guoapp `hongguoDanmaku` 的入参约束）。
pub(crate) fn validate_danmaku_window(start_ms: i64, duration_ms: i64) -> ApiResult<()> {
    if start_ms < 0 || duration_ms <= start_ms || duration_ms > DANMAKU_MAX_DURATION_MS {
        return Err(ApiError::bad_request("弹幕请求参数无效"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_query_bag_matches_the_reference() {
        let q = app_query_pairs("111", "222");
        assert_eq!(q.len(), 20);
        assert_eq!(q[0], ("aid".to_string(), "8662".to_string()));
        assert_eq!(
            q[q.len() - 1],
            ("iid".to_string(), "222".to_string())
        );
    }

    #[test]
    fn numeric_id_check() {
        assert!(is_numeric_id("7381000000000000000"));
        assert!(!is_numeric_id(""));
        assert!(!is_numeric_id("123a"));
        assert!(!is_numeric_id("-1"));
    }

    #[test]
    fn danmaku_window_bounds() {
        validate_danmaku_window(0, 30_000).unwrap();
        validate_danmaku_window(30_000, 30_000).unwrap_err();
        validate_danmaku_window(-1, 30_000).unwrap_err();
        validate_danmaku_window(0, DANMAKU_MAX_DURATION_MS + 1).unwrap_err();
    }
}
