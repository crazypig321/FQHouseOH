//! hongguoduanju.com 网页解析：`_ROUTER_DATA` 定位 + 详情页 `vid_list`
//! 提取 + 官网搜索 JSON 接口（kotlin-tv `ContentRepository.searchAll`）。
//!
//! 对应 guoapp `parseRouterData` / `routerLoaderMap` /
//! `fetchHongguoWebChapters`（GPL-3.0，本项目同 license 直接移植）。
//! 网页详情是免签名的剧集目录来源：`detail?series_id=` 的
//! `loaderData.detail_page.seriesDetail.vid_list` 按集排序。

use std::sync::Arc;

use serde_json::Value;

use crate::endpoints::base::{Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::hongguo::client::{fetch_web_text, HOST_HONGGUO_WEB};
use crate::endpoints::hongguo::vsign;
use crate::endpoints::util::raw_json;
use crate::error::{ApiError, ApiResult};
use crate::upstream::UpstreamClient;

/// 从 HTML 中截取 `window._ROUTER_DATA = {...}` 的 JSON 并解析。
pub(crate) fn parse_router_data(raw: &str) -> Option<Value> {
    let idx = raw
        .find("_ROUTER_DATA")
        .map(|p| raw[p..].find('=').map(|q| p + q + 1))??;
    // JSON 起点后第一个非空白字符必须是 '{'。
    let rest = raw[idx..].trim_start();
    if !rest.starts_with('{') {
        return None;
    }
    let start = idx + (raw[idx..].len() - rest.len());
    // 顶层对象后面跟着 `;`/`</script>` 尾巴，serde 要求整段合法，
    // 先做字符串感知的花括号配对截取再解析。
    let bytes = raw[start..].as_bytes();
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    let mut end = None;
    for (i, &b) in bytes.iter().enumerate() {
        if in_string {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_string = false;
            }
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(i + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    let end = end?;
    raw_json(&bytes[..end]).ok()
}

/// guoapp `routerLoaderMap`：按名字（含前缀匹配，`$` 结尾表精确）取
/// `loaderData` 下的页对象。
fn loader_map<'a>(data: &'a Value, names: &[&str]) -> Option<&'a Value> {
    let loader = data.get("loaderData")?.as_object()?;
    for name in names {
        if let Some(page) = loader.get(*name) {
            if page.as_object().is_some_and(|m| !m.is_empty()) {
                return Some(page);
            }
        }
    }
    let exact: Vec<&str> = names.iter().map(|n| n.trim_end_matches('$')).collect();
    for (key, value) in loader {
        for name in &exact {
            if !name.is_empty() && key.starts_with(name) {
                if let Some(page) = value.as_object() {
                    if !page.is_empty() {
                        return Some(value);
                    }
                }
            }
        }
    }
    None
}

pub(crate) struct WebDetail {
    pub title: String,
    pub vids: Vec<String>,
}

/// 抓取并解析网页详情：`series_id` 必须是纯数字。
pub(crate) async fn fetch_series_detail(
    up: &std::sync::Arc<crate::upstream::UpstreamClient>,
    series_id: &str,
) -> ApiResult<WebDetail> {
    let url = format!(
        "{}/detail?series_id={}",
        HOST_HONGGUO_WEB,
        crate::endpoints::util::go_query_escape(series_id)
    );
    let body = fetch_web_text(up, &url, &format!("{HOST_HONGGUO_WEB}/")).await?;
    parse_series_detail(&body, series_id)
}

pub(crate) fn parse_series_detail(body: &str, series_id: &str) -> ApiResult<WebDetail> {
    let data = parse_router_data(body)
        .ok_or_else(|| ApiError::internal("hq网页详情数据不可用"))?;
    let page = loader_map(&data, &["detail_page", "detail_"])
        .ok_or_else(|| ApiError::internal("hq网页详情数据不可用"))?;
    let detail = page
        .get("seriesDetail")
        .and_then(|v| v.as_object())
        .filter(|m| !m.is_empty())
        .ok_or_else(|| ApiError::internal("hq网页详情数据不可用"))?;

    let title = crate::json::first_map_string(detail, &["series_name", "series_title", "name"]);
    let title = if title.is_empty() {
        series_id.to_string()
    } else {
        title
    };
    let mut vids: Vec<String> = Vec::new();
    if let Some(list) = detail.get("vid_list").and_then(|v| v.as_array()) {
        for v in list {
            let vid = match v {
                Value::String(s) => s.trim().to_string(),
                Value::Number(n) => n.to_string(),
                _ => String::new(),
            };
            if !vid.is_empty() && !vid.contains('<') {
                vids.push(vid);
            }
        }
    }
    if vids.is_empty() {
        return Err(ApiError::internal("hq详情没有返回剧集 ID"));
    }
    Ok(WebDetail { title, vids })
}

/// kotlin-tv `ContentRepository.searchAll`：官网搜索 JSON 接口
/// `/api/search/result`（免签名）。该路径须保留完整客户端 UA
/// （[`vsign::VIDEO_UA`]）并带 Referer，否则服务端拒绝（kotlin
/// `signedRequest` 特例）。
pub(crate) async fn fetch_search_result(
    up: &Arc<UpstreamClient>,
    keyword: &str,
    page: u32,
) -> ApiResult<Value> {
    let url = format!(
        "{HOST_HONGGUO_WEB}/api/search/result?query={}&page={page}",
        vsign::pue_one(keyword),
    );
    let (raw, _) = Upstream::new(up.clone())
        .raw_with_headers(&UpstreamRequestSpec {
            mode: UpstreamMode::NoSign,
            method: Some("GET".to_string()),
            raw_url: Some(url),
            headers: vec![
                ("User-Agent".to_string(), vsign::VIDEO_UA.to_string()),
                ("Referer".to_string(), format!("{HOST_HONGGUO_WEB}/")),
                ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
            ],
            ..Default::default()
        })
        .await?;
    Ok(raw_json(&raw)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DETAIL_HTML: &str = r#"
<html><head><script>
window._ROUTER_DATA = {
  "loaderData": {
    "detail_page": {
      "seriesDetail": {
        "series_id": "7381000000000000000",
        "series_name": "测试短剧",
        "vid_list": ["111", 222, " 333 ", "", null]
      }
    }
  }
};
</script></head><body></body></html>
"#;

    #[test]
    fn parses_detail_vid_list() {
        let d = parse_series_detail(DETAIL_HTML, "7381000000000000000").unwrap();
        assert_eq!(d.title, "测试短剧");
        assert_eq!(d.vids, vec!["111", "222", "333"]);
    }

    #[test]
    fn missing_router_data_is_an_error() {
        assert!(parse_router_data("<html>no data</html>").is_none());
        assert!(parse_series_detail("<html>no data</html>", "1").is_err());
    }

    #[test]
    fn empty_vid_list_is_an_error() {
        let html = r#"x _ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_name":"t","vid_list":[]}}}}"#;
        assert!(parse_series_detail(html, "1").is_err());
    }
}
