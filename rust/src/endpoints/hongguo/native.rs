//! 红果原生内容源（Rust 原生实现，替换 Go 核心 `libduanju_core.so`）。
//!
//! 移植自 hongguoTV（GPL-3.0，本项目同 license 直接移植）：
//! - **catalog**：`short_play` → 官网 SSR 分类页
//!   （`/category?tab=1&sort_type=1`，`loaderData.category_page.recommendList`，
//!   drpys `server/vendor/hongguo.cjs`）；
//!   `comic_series` → App 搜索 tab 19（新签名 [`vsign::signed_app_get`]），
//!   失败/空页回退官网 rank `hot-comic-drama`（cjs `appCategoryPage` 语义）。
//! - **detail**：官网 SSR 详情页 `vid_list` → chapters（复用 [`web`]）。
//! - **media**：kotlin-tv `MobilePlayback.ladder` / `PlaybackModels`：V5
//!   签名 POST `multi_video_model/player/v1`（[`crate::sign::v5`]，设备池
//!   匿名身份）→ `data["1004"][vid].video_model.video_list` 档位（跳过
//!   bytevc2/bvc2，`main_url`/`play_url`/`backup_url_1`，模型级 `key_seed`
//!   解密）→ spade_a 内容密钥，直返 CDN 地址（CENC 密文，播放器带
//!   decryptionKey 播放，同番茄 /api/videos 方案）；`mode=download`
//!   代下载整集（`download_and_save`），url 改写为 `/src/` 本地路径。
//!   缓存 id 以 `hg_` 前缀隔离：红果与番茄 vid 命名空间相同而密钥不同，
//!   混用会把对方缓存写成坏档。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::device::Device;
use crate::endpoints::base::{
    map_client_error, Upstream, UpstreamMode, UpstreamRequestSpec,
};
use crate::endpoints::hongguo::client::HOST_HONGGUO_WEB;
use crate::endpoints::hongguo::vsign::{self, AppSearchCursor};
use crate::endpoints::hongguo::web;
use crate::endpoints::util::raw_json;
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use crate::timeutil::now_millis;
use crate::upstream::UpstreamClient;

/// cjs `PAGE_SIZE`（App 分类页每页条数）。
const COMIC_PAGE_SIZE: u32 = 24;
/// cjs `CATEGORY_CONFIG.comic`：漫剧走 App 搜索 tab 19、关键词「热门」。
const COMIC_TAB_TYPE: u32 = 19;
const COMIC_KEYWORD: &str = "热门";
/// cjs `CATEGORY_CONFIG.comic.fallback`：App 搜索失败回退的官网榜单。
const COMIC_FALLBACK_ROUTE: &str = "hot-comic-drama";
/// cjs `pageCache`：SSR 页面 3 分钟。
const SSR_CACHE_TTL_MS: i64 = 3 * 60 * 1000;
const SSR_CACHE_CAP: usize = 32;
/// cjs `appSearchCache`：App 搜索页 5 分钟。
const APP_SEARCH_CACHE_TTL_MS: i64 = 5 * 60 * 1000;
const APP_SEARCH_CACHE_CAP: usize = 64;
/// cjs `videoInfoCache`：video_info 5 分钟。
const VIDEO_INFO_TTL_MS: i64 = 5 * 60 * 1000;
const VIDEO_INFO_CAP: usize = 32;
/// kotlin-tv `MobilePlayback.ladder`：V5 播放模型接口（`sign::v5` 签名，
/// gzip body，设备池匿名身份）。番茄侧 `endpoints::video` 同接口在用。
const V5_PLAYER_URL: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1";
/// kotlin-tv 0.16.10（#72 修复）`tabVideoModel(strict = true)`：POST v5 空正文时
/// pin 同一设备身份兜底重查当前集的 `video_tab` GET 接口。
const V5_VIDEO_TAB_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/";

pub fn register(s: &mut Server) {
    s.add_route("hongguo_native_catalog", handle_catalog);
    s.add_route("hongguo_native_detail", handle_detail);
    s.add_route("hongguo_native_media", handle_media);
}

// ---------------------------------------------------------------------------
// 缓存
// ---------------------------------------------------------------------------

struct CacheEntry<T> {
    value: T,
    expires_at: i64,
}

fn cache_get<T: Clone>(map: &Mutex<HashMap<String, CacheEntry<T>>>, key: &str) -> Option<T> {
    let mut guard = map.lock().unwrap();
    match guard.get(key) {
        Some(entry) if entry.expires_at > now_millis() => Some(entry.value.clone()),
        Some(_) => {
            guard.remove(key);
            None
        }
        None => None,
    }
}

fn cache_put<T>(
    map: &Mutex<HashMap<String, CacheEntry<T>>>,
    key: &str,
    value: T,
    ttl_ms: i64,
    cap: usize,
) {
    let mut guard = map.lock().unwrap();
    if guard.len() >= cap {
        guard.clear();
    }
    guard.insert(
        key.to_string(),
        CacheEntry {
            value,
            expires_at: now_millis() + ttl_ms,
        },
    );
}

fn ssr_cache() -> &'static Mutex<HashMap<String, CacheEntry<Value>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, CacheEntry<Value>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn app_search_cache() -> &'static Mutex<HashMap<String, CacheEntry<AppSearchPage>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, CacheEntry<AppSearchPage>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn video_info_cache() -> &'static Mutex<HashMap<String, CacheEntry<Arc<VideoInfo>>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, CacheEntry<Arc<VideoInfo>>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

// ---------------------------------------------------------------------------
// JSON/字符串小工具（JS 语义）
// ---------------------------------------------------------------------------

/// cjs `cleanUrl`：`\/`、`\u0026`、`&amp;` 还原。
fn clean_url(value: &str) -> String {
    value
        .replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
        .trim()
        .to_string()
}

/// cjs `str(value)`：null → 空，其余 String(value).trim()。
fn value_text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => v.to_string(),
    }
}

/// cjs `a || b || c` 链（空串/0/null 视为缺席）取第一个非缺席值。
fn first_text(m: &Map<String, Value>, keys: &[&str]) -> String {
    for key in keys {
        let Some(v) = m.get(*key) else { continue };
        match v {
            Value::Null => continue,
            Value::String(s) if s.trim().is_empty() => continue,
            Value::Number(n) if n.as_f64() == Some(0.0) => continue,
            _ => return value_text(v),
        }
    }
    String::new()
}

fn field_int(m: &Map<String, Value>, keys: &[&str]) -> i64 {
    for key in keys {
        let Some(v) = m.get(*key) else { continue };
        match v {
            Value::Null => continue,
            Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    return i;
                }
                if let Some(f) = n.as_f64() {
                    return f as i64;
                }
            }
            Value::String(s) => {
                if let Ok(i) = s.trim().parse::<i64>() {
                    return i;
                }
            }
            _ => {}
        }
    }
    0
}

fn string_array(v: Option<&Value>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(arr) = v.and_then(Value::as_array) {
        for item in arr {
            let text = value_text(item);
            if !text.is_empty() {
                out.push(text);
            }
        }
    }
    out
}

/// cjs `decodeHtml`。
fn decode_html(value: &str) -> String {
    value
        .replace("&quot;", "\"")
        .replace("&#x2F;", "/")
        .replace("&#x2f;", "/")
        .replace("&#47;", "/")
        .replace("&#x27;", "'")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

// ---------------------------------------------------------------------------
// 条目映射（nativeDrama JSON 契约，见 go/core/app_runtime.go:66）
// ---------------------------------------------------------------------------

/// 归一化后的剧字段（各上游形态 → 统一 nativeDrama）。
struct SeriesFields {
    id: String,
    title: String,
    cover: String,
    intro: String,
    episodes: i64,
    tags: Vec<String>,
}

fn series_to_drama(f: &SeriesFields, category: &str) -> Value {
    json!({
        "metadataSchema": 1,
        "id": f.id,
        "source": "hongguo",
        "sourceId": f.id,
        "title": f.title,
        "description": f.intro,
        "cover": f.cover,
        "episodes": f.episodes,
        "category": category,
        "vip": false,
        "tags": f.tags,
    })
}

/// cjs `itemToCard`（官网 SSR 形态）：`video_data` 为对象时优先，否则取条目自身。
fn ssr_series_fields(item: &Value) -> Option<SeriesFields> {
    let source = match item.get("video_data") {
        Some(v) if v.is_object() => v,
        _ => item,
    };
    let obj = source.as_object()?;
    let id = first_text(obj, &["series_id"]);
    let item_obj = item.as_object()?;
    let title = {
        let t = first_text(obj, &["series_name", "series_title"]);
        if t.is_empty() {
            first_text(item_obj, &["name"])
        } else {
            t
        }
    };
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let episodes = match obj.get("episode_cnt") {
        Some(v) if !v.is_null() => field_int(obj, &["episode_cnt"]),
        _ => obj
            .get("series_episode_info")
            .and_then(Value::as_object)
            .map(|m| field_int(m, &["episode_cnt"]))
            .unwrap_or(0),
    };
    let mut tags = string_array(obj.get("tags"));
    if tags.is_empty() {
        if let Some(list) = obj.get("category_list").and_then(Value::as_array) {
            for entry in list {
                let text = match entry {
                    Value::String(s) => s.trim().to_string(),
                    Value::Object(m) => crate::json::first_map_string(m, &["name"]),
                    _ => String::new(),
                };
                if !text.is_empty() {
                    tags.push(text);
                }
            }
        }
    }
    tags.truncate(5);
    Some(SeriesFields {
        id,
        title,
        cover: clean_url(&first_text(obj, &["series_cover"])),
        intro: first_text(obj, &["series_intro"]),
        episodes,
        tags,
    })
}

/// cjs `appSearchVod`（App 搜索 cell 形态：`video_data` 为数组）。
fn search_series_fields(cell: &Value) -> Option<SeriesFields> {
    let cell_obj = cell.as_object()?;
    let video = cell_obj
        .get("video_data")
        .and_then(Value::as_array)
        .and_then(|arr| arr.iter().find(|v| v.is_object()))?;
    let video_obj = video.as_object()?;
    let mut title = String::new();
    if let Some(highlight) = cell_obj
        .get("search_high_light")
        .and_then(Value::as_object)
        .and_then(|h| h.get("title"))
        .and_then(Value::as_object)
    {
        title = first_text(highlight, &["text"]);
    }
    if title.is_empty() {
        title = first_text(video_obj, &["title"]);
    }
    if title.is_empty() {
        title = first_text(cell_obj, &["cell_name"]);
    }
    let id = {
        let v = first_text(video_obj, &["series_id"]);
        if v.is_empty() {
            first_text(cell_obj, &["book_id", "search_result_id"])
        } else {
            v
        }
    };
    if id.is_empty() || title.is_empty() {
        return None;
    }
    Some(SeriesFields {
        id,
        title,
        cover: clean_url(&first_text(video_obj, &["cover", "cover_url"])),
        intro: first_text(video_obj, &["video_desc", "rec_text", "sub_title"]),
        episodes: field_int(video_obj, &["episode_cnt"]),
        tags: Vec::new(),
    })
}

/// cjs `rankItemToCard`（官网榜单条目形态）。
fn rank_series_fields(item: &Value) -> Option<SeriesFields> {
    let obj = item.as_object()?;
    let id = first_text(obj, &["seriesId", "series_id", "id"]);
    let title = first_text(obj, &["title", "seriesTitle", "series_name"]);
    if id.is_empty() || title.is_empty() {
        return None;
    }
    Some(SeriesFields {
        id,
        title,
        cover: clean_url(&first_text(obj, &["cover", "seriesCover", "series_cover"])),
        intro: first_text(obj, &["description", "intro", "seriesIntro"]),
        episodes: field_int(obj, &["episodeCount", "episode_cnt"]),
        tags: string_array(obj.get("tags")),
    })
}

// ---------------------------------------------------------------------------
// 网页抓取（cjs `getText`：VIDEO_UA + zh-CN）
// ---------------------------------------------------------------------------

async fn fetch_page_text(up: &Arc<UpstreamClient>, url: &str) -> ApiResult<String> {
    let (raw, _) = Upstream::new(up.clone())
        .raw_with_headers(&UpstreamRequestSpec {
            mode: UpstreamMode::NoSign,
            method: Some("GET".to_string()),
            raw_url: Some(url.to_string()),
            headers: vec![
                ("User-Agent".to_string(), vsign::VIDEO_UA.to_string()),
                ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
            ],
            ..Default::default()
        })
        .await?;
    Ok(String::from_utf8_lossy(&raw).into_owned())
}

/// cjs `routerData`：SSR 页面 `_ROUTER_DATA`（3 分钟缓存）。
async fn router_data(up: &Arc<UpstreamClient>, url: &str) -> ApiResult<Value> {
    if let Some(cached) = cache_get(ssr_cache(), url) {
        return Ok(cached);
    }
    let text = fetch_page_text(up, url).await?;
    let value = web::parse_router_data(&text)
        .ok_or_else(|| ApiError::internal("hq网页数据不可用"))?;
    cache_put(ssr_cache(), url, value.clone(), SSR_CACHE_TTL_MS, SSR_CACHE_CAP);
    Ok(value)
}

// ---------------------------------------------------------------------------
// App 搜索（新签名，cjs `appSearchPage`）
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct AppSearchPage {
    dramas: Vec<Value>,
    has_more: bool,
    cursor: AppSearchCursor,
}

/// cjs `appSearchPage`：翻页游标取上一页响应（递归，页结果 5 分钟缓存）。
async fn app_search_page(
    up: &Arc<UpstreamClient>,
    keyword: &str,
    tab_type: u32,
    page: u32,
    limit: u32,
) -> ApiResult<AppSearchPage> {
    let key = format!("{tab_type}|{keyword}|{page}");
    if let Some(cached) = cache_get(app_search_cache(), &key) {
        return Ok(cached);
    }
    let cursor = if page > 1 {
        Box::pin(app_search_page(up, keyword, tab_type, page - 1, limit))
            .await?
            .cursor
    } else {
        AppSearchCursor::default()
    };
    let values = vsign::app_search_params(keyword, tab_type, limit, &cursor, page);
    let signed = vsign::signed_app_get(&values, now_millis());
    let (raw, _) = Upstream::new(up.clone())
        .raw_with_headers(&UpstreamRequestSpec {
            mode: UpstreamMode::NoSign,
            method: Some("GET".to_string()),
            raw_url: Some(signed.url),
            headers: signed.headers,
            ..Default::default()
        })
        .await?;
    let data = raw_json(&raw)?;

    let tabs = data
        .get("search_tabs")
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| {
            data.get("data")
                .and_then(|d| d.get("search_tabs"))
                .and_then(Value::as_array)
                .cloned()
        })
        .ok_or_else(|| ApiError::internal("hq App 搜索暂不可用"))?;
    let tab = tabs
        .iter()
        .find(|t| {
            t.as_object()
                .map(|m| field_int(m, &["tab_type"]) == tab_type as i64)
                .unwrap_or(false)
        })
        .cloned()
        .unwrap_or_else(|| json!({}));
    let tab_obj = tab.as_object().cloned().unwrap_or_default();

    let mut dramas: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    if let Some(cells) = tab_obj.get("data").and_then(Value::as_array) {
        for cell in cells {
            for item in app_search_cells(cell) {
                if let Some(f) = search_series_fields(&item) {
                    if seen.iter().any(|id| *id == f.id) {
                        continue;
                    }
                    seen.push(f.id.clone());
                    dramas.push(series_to_drama(&f, "漫剧"));
                }
            }
        }
    }
    let has_more = matches!(tab_obj.get("has_more"), Some(Value::Bool(true)))
        || field_int(&tab_obj, &["has_more"]) == 1;
    let cursor = AppSearchCursor {
        search_id: first_text(&tab_obj, &["search_id"]),
        passback: first_text(&tab_obj, &["passback"]),
    };
    let page_value = AppSearchPage {
        dramas,
        has_more,
        cursor,
    };
    cache_put(
        app_search_cache(),
        &key,
        page_value.clone(),
        APP_SEARCH_CACHE_TTL_MS,
        APP_SEARCH_CACHE_CAP,
    );
    Ok(page_value)
}

/// cjs `appSearchCells`：cell 本体 + `lynx_data` 内嵌 `cell_data` 条目。
fn app_search_cells(cell: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if cell.is_object() {
        out.push(cell.clone());
    }
    if let Some(lynx) = cell.get("lynx_data").and_then(Value::as_str) {
        if let Ok(payload) = raw_json(lynx.as_bytes()) {
            if let Some(items) = payload.get("cell_data").and_then(Value::as_array) {
                for item in items {
                    if item.is_object() {
                        out.push(item.clone());
                    }
                }
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// 官网分类页 / 榜单（cjs `categoryPage` / `rankPage`）
// ---------------------------------------------------------------------------

/// cjs `categoryData` + `itemToCard`：短剧 SSR 分类页。
async fn short_play_page(
    up: &Arc<UpstreamClient>,
    page: u32,
) -> ApiResult<(Vec<Value>, bool)> {
    let mut url = format!("{HOST_HONGGUO_WEB}/category?tab=1&sort_type=1");
    if page > 1 {
        url.push_str(&format!("&page={page}"));
    }
    let data = router_data(up, &url).await?;
    // 官网改版后 loader key 不再固定为 `category_page`（现为 `category_$`
    // 且随路由变化），改为在 loaderData 里找带 `recommendList` 的页对象。
    let loader = data
        .get("loaderData")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let list = loader
        .values()
        .find(|v| {
            v.as_object()
                .is_some_and(|m| m.get("recommendList").is_some())
        })
        .and_then(|p| {
            p.get("recommendList")
                .and_then(Value::as_array)
                .cloned()
                .or_else(|| {
                    p.get("categoryData")
                        .and_then(|c| c.get("recommendList"))
                        .and_then(Value::as_array)
                        .cloned()
                })
        })
        .unwrap_or_default();
    let dramas: Vec<Value> = list
        .iter()
        .filter_map(ssr_series_fields)
        .map(|f| series_to_drama(&f, "短剧"))
        .collect();
    let has_more = !dramas.is_empty();
    Ok((dramas, has_more))
}

/// cjs `rankData`：`data-fn-name="r"` 的 `data-fn-args` 第三段。
fn parse_rank_payload(html: &str) -> ApiResult<Value> {
    let marker = html
        .find("data-fn-name=\"r\"")
        .ok_or_else(|| ApiError::internal("hq榜单页面没有数据"))?;
    let args_marker = html[marker..]
        .find("data-fn-args=\"")
        .map(|p| marker + p + "data-fn-args=\"".len())
        .ok_or_else(|| ApiError::internal("hq榜单页面没有数据"))?;
    let end = html[args_marker..]
        .find('"')
        .map(|p| args_marker + p)
        .ok_or_else(|| ApiError::internal("hq榜单页面没有数据"))?;
    let args = raw_json(decode_html(&html[args_marker..end]).as_bytes())
        .map_err(|_| ApiError::internal("hq榜单数据格式错误"))?;
    let payload = args
        .as_array()
        .and_then(|arr| arr.get(2))
        .cloned()
        .ok_or_else(|| ApiError::internal("hq榜单数据格式错误"))?;
    let ok = payload
        .as_object()
        .map(|m| {
            matches!(m.get("isSuccess"), Some(Value::Bool(true)))
                || field_int(m, &["isSuccess"]) == 1
        })
        .unwrap_or(false);
    if !ok || payload.get("rankList").and_then(Value::as_array).is_none() {
        return Err(ApiError::internal("hq榜单数据格式错误"));
    }
    Ok(payload)
}

/// cjs `rankPage`：官网榜单（分页 totalPages 判定 hasMore）。
async fn rank_page(
    up: &Arc<UpstreamClient>,
    route: &str,
    page: u32,
    category: &str,
) -> ApiResult<(Vec<Value>, bool)> {
    let mut url = format!("{HOST_HONGGUO_WEB}/rank/{route}");
    if page > 1 {
        url.push_str(&format!("?page={page}"));
    }
    let html = fetch_page_text(up, &url).await?;
    // 官网改版后榜单数据内嵌在 `_ROUTER_DATA` 的
    // `loaderData["rank_<route>/page"].content`，旧版才是 `data-fn-args`。
    let payload = match web::parse_router_data(&html) {
        Some(data) => match rank_router_payload(&data) {
            Some(payload) => payload,
            None => parse_rank_payload(&html)?,
        },
        None => parse_rank_payload(&html)?,
    };
    let dramas: Vec<Value> = payload
        .get("rankList")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(rank_series_fields)
                .map(|f| series_to_drama(&f, category))
                .collect()
        })
        .unwrap_or_default();
    let total_pages = payload
        .get("pagination")
        .and_then(Value::as_object)
        .map(|m| field_int(m, &["totalPages"]).max(1))
        .unwrap_or(1);
    let has_more = page < total_pages as u32;
    Ok((dramas, has_more))
}

/// 改版后官网榜单 `_ROUTER_DATA`：`loaderData` 下 `rank_*` 页对象的
/// `content`（`isSuccess`/`rankList`/`pagination`）。
fn rank_router_payload(data: &Value) -> Option<Value> {
    let loader = data.get("loaderData")?.as_object()?;
    for (key, value) in loader {
        if !key.starts_with("rank") || key.ends_with("_layout") {
            continue;
        }
        if let Some(content) = value
            .get("content")
            .filter(|c| c.get("rankList").is_some())
        {
            return Some(content.clone());
        }
    }
    None
}

/// 漫剧分类页：App 搜索 tab 19，失败/空页回退官网 rank（cjs 一级分支）。
async fn comic_series_page(
    up: &Arc<UpstreamClient>,
    page: u32,
) -> ApiResult<(Vec<Value>, bool)> {
    let app = app_search_page(up, COMIC_KEYWORD, COMIC_TAB_TYPE, page, COMIC_PAGE_SIZE).await;
    if let Ok(result) = app {
        if !result.dramas.is_empty() {
            return Ok((result.dramas, result.has_more));
        }
    }
    rank_page(up, COMIC_FALLBACK_ROUTE, page, "漫剧").await
}

// ---------------------------------------------------------------------------
// 清晰度档位（kotlin-tv `PlaybackModels.renditions` / cjs `qualityNumber`）
// ---------------------------------------------------------------------------

struct QualityRow {
    number: i64,
    main_url: String,
    spade_a: String,
}

struct VideoInfo {
    rows: Vec<QualityRow>,
}

/// cjs `qualityNumber`：先按 2160..360 数字串最早出现位置取值，
/// 再按 1920→1080 等宽度映射，最后 3-4 位纯数字直取。
fn quality_number(text: &str) -> i64 {
    let candidates = [2160, 1440, 1080, 720, 576, 540, 480, 360];
    let mut best: Option<(usize, i64)> = None;
    for cand in candidates {
        if let Some(pos) = text.find(cand.to_string().as_str()) {
            if best.is_none_or(|(p, _)| pos < p) {
                best = Some((pos, cand));
            }
        }
    }
    if let Some((_, number)) = best {
        return number;
    }
    match text {
        "1920" => 1080,
        "1280" => 720,
        "1024" => 576,
        "854" => 480,
        "640" => 360,
        _ => {
            let len = text.chars().count();
            if (3..=4).contains(&len) && text.chars().all(|c| c.is_ascii_digit()) {
                text.parse::<i64>().unwrap_or(0)
            } else {
                0
            }
        }
    }
}

/// kotlin-tv `PlaybackModels.renditions`：`video_list` 档位表 → 按清晰度
/// 降序的可播列表，跳过 bytevc2/bvc2（鸿蒙无对应解码器）。
fn rendition_rows(model: &Value) -> Vec<QualityRow> {
    let Some(model_obj) = model.as_object() else {
        return Vec::new();
    };
    // 模型级 key_seed：加密档位 URL 的解密种子。
    let seed = match model_obj.get("key_seed") {
        Some(Value::String(s)) if !s.trim().is_empty() => {
            crate::endpoints::video::audio_b64_decode(s).ok()
        }
        _ => None,
    };
    let mut entries: Vec<(&str, &Value)> = Vec::new();
    match model.get("video_list") {
        Some(Value::Object(map)) => {
            for (key, value) in map {
                entries.push((key.as_str(), value));
            }
        }
        Some(Value::Array(array)) => {
            for value in array {
                entries.push(("", value));
            }
        }
        _ => {}
    }
    let mut rows: Vec<QualityRow> = Vec::new();
    for (name, entry) in entries {
        let Some(item) = entry.as_object() else { continue };
        if let Some(row) = rendition_row(item, name, seed.as_deref()) {
            rows.push(row);
        }
    }
    rows.sort_by(|a, b| b.number.cmp(&a.number));
    rows
}

/// kotlin-tv 单档位解析：codec 过滤 → URL 解密 → 加密校验 → 清晰度标签。
fn rendition_row(item: &Map<String, Value>, name: &str, seed: Option<&[u8]>) -> Option<QualityRow> {
    let meta = item.get("video_meta").and_then(Value::as_object);
    // bytevc2 / bvc2：鸿蒙与电视播放器都没有对应解码器。
    let codec = [
        first_text(item, &["codec_type"]),
        first_text(item, &["gear_des_key"]),
        meta.map(|m| first_text(m, &["codec_type"])).unwrap_or_default(),
    ]
    .join(" ")
    .to_lowercase();
    if codec.contains("bytevc2") || contains_bvc2_word(&codec) {
        return None;
    }
    let main_url = resolve_rendition_url(item, seed)?;
    let spade_a = {
        let s = item
            .get("encrypt_info")
            .and_then(Value::as_object)
            .map(|e| first_text(e, &["spade_a"]))
            .unwrap_or_default();
        if s.is_empty() {
            first_text(item, &["spade_a"])
        } else {
            s
        }
    };
    if let Some(enc) = item.get("encrypt_info").and_then(Value::as_object) {
        // 加密开启但拿不到内容密钥的档位不可播。
        if spade_a.is_empty() && !encrypt_flag_off(enc) {
            return None;
        }
    }
    let dimensions = {
        let width = entry_dimension(item, meta, "vwidth");
        let height = entry_dimension(item, meta, "vheight");
        if width > 0 && height > 0 {
            format!("{}", width.min(height))
        } else {
            String::new()
        }
    };
    let mut label = first_text(item, &["quality_desc"]);
    if label.is_empty() {
        label = meta.map(|m| first_text(m, &["definition"])).unwrap_or_default();
    }
    if label.is_empty() {
        label = dimensions;
    }
    if label.is_empty() {
        label = first_text(item, &["height"]);
    }
    if label.is_empty() {
        label = first_text(item, &["vheight"]);
    }
    if label.is_empty() {
        label = first_text(item, &["quality"]);
    }
    if label.is_empty() {
        label = name.to_string();
    }
    Some(QualityRow {
        number: quality_number(&label),
        main_url,
        spade_a,
    })
}

/// kotlin-tv 档位 URL 解析：`main_url`/`play_url`/`backup_url_1` 第一个
/// 非空字段；`http(s)://` 直用，否则模型级 `key_seed` 解密或 base64 解码。
fn resolve_rendition_url(item: &Map<String, Value>, seed: Option<&[u8]>) -> Option<String> {
    for field in ["main_url", "play_url", "backup_url_1"] {
        let raw = clean_url(&first_text(item, &[field]));
        if raw.is_empty() {
            continue;
        }
        let resolved = if raw.starts_with("https://") || raw.starts_with("http://") {
            raw
        } else {
            match seed {
                Some(seed) => crate::endpoints::video::decrypt_spade_url(&raw, seed),
                None => crate::endpoints::video::audio_b64_decode(&raw)
                    .ok()
                    .and_then(|bytes| String::from_utf8(bytes).ok())
                    .unwrap_or_default(),
            }
        };
        if resolved.starts_with("https://") || resolved.starts_with("http://") {
            return Some(resolved);
        }
    }
    None
}

/// kotlin-tv 的 `(^|[^a-z0-9])bvc2([^a-z0-9]|$)`：词边界匹配 bvc2。
fn contains_bvc2_word(codec: &str) -> bool {
    let bytes = codec.as_bytes();
    let mut at = 0;
    while let Some(pos) = codec[at..].find("bvc2") {
        let start = at + pos;
        let end = start + "bvc2".len();
        let left_ok = start == 0 || !bytes[start - 1].is_ascii_alphanumeric();
        let right_ok = end == bytes.len() || !bytes[end].is_ascii_alphanumeric();
        if left_ok && right_ok {
            return true;
        }
        at = end;
    }
    false
}

/// kotlin-tv：`encrypt_info.encrypt` 为 `false`/`0`/`"0"`/`"false"` 视为
/// 未加密，档位没有 spade_a 也可播。
fn encrypt_flag_off(enc: &Map<String, Value>) -> bool {
    match enc.get("encrypt") {
        Some(Value::Bool(false)) => true,
        Some(Value::Number(n)) => n.as_i64() == Some(0),
        Some(Value::String(s)) => s == "0" || s == "false",
        _ => false,
    }
}

/// 档位宽高：entry 自身优先，回退 `video_meta`。
fn entry_dimension(
    item: &Map<String, Value>,
    meta: Option<&Map<String, Value>>,
    key: &str,
) -> i64 {
    let value = field_int(item, &[key]);
    if value > 0 {
        return value;
    }
    meta.map(|m| field_int(m, &[key])).unwrap_or(0)
}

fn quality_list(rows: &[QualityRow]) -> Vec<i64> {
    let mut out: Vec<i64> = Vec::new();
    for row in rows {
        if row.number > 0 && !out.contains(&row.number) {
            out.push(row.number);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// 取流（kotlin-tv `MobilePlayback.ladder` / `PlaybackModels`）
// ---------------------------------------------------------------------------

/// kotlin-tv `MobilePlayback.ladder` 请求体（gzip 后交 `sign::v5` 签名）。
fn v5_playback_body(video_id: &str) -> ApiResult<Vec<u8>> {
    let payload = json!({
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 1,
            "disable_digg_stat": false,
            "disable_video_relate_book": false,
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "use_os_player": false,
            "use_server_dns": false,
            "video_platform": 1024,
        },
        "mixed_video_id_map": { "1004": [video_id] },
        "dr_scene": "player",
    });
    let plain = serde_json::to_vec(&payload)
        .map_err(|e| ApiError::internal(format!("序列化取流请求失败：{e}")))?;
    Ok(crate::crypto::gzip(&plain))
}

/// kotlin-tv `fetchVideoInfo`：V5 签名 POST `multi_video_model/player/v1`
/// （设备池匿名身份，`sign::v5`）→ `data["1004"][vid].video_model` 档位
/// （5 分钟缓存）。上游对该接口间歇性回 200+空正文（hongguoTV #72）：
/// 空正文时 pin 刚才应答的设备，经 `video_tab` GET 重查当前集一次
/// （kotlin-tv 0.16.10），兜底失败保留原空正文错误。
async fn fetch_video_info(up: &Arc<UpstreamClient>, vid: &str) -> ApiResult<Arc<VideoInfo>> {
    if let Some(cached) = cache_get(video_info_cache(), vid) {
        return Ok(cached);
    }
    let body = v5_playback_body(vid)?;
    let (raw, device) = Upstream::new(up.clone())
        .v5_playback_with_device(V5_PLAYER_URL, &body, None)
        .await
        .map_err(map_client_error)?;
    let rows = if raw.is_empty() {
        let empty_err = ApiError::internal("hq取流失败：video_model 接口返回为空");
        match fetch_video_tab_model(up, vid, &device).await {
            Some(model) => {
                let rows = rendition_rows(&model);
                if rows.is_empty() {
                    return Err(empty_err);
                }
                rows
            }
            None => return Err(empty_err),
        }
    } else {
        video_model_rows(&raw, vid)?
    };
    let value = Arc::new(VideoInfo { rows });
    cache_put(
        video_info_cache(),
        vid,
        value.clone(),
        VIDEO_INFO_TTL_MS,
        VIDEO_INFO_CAP,
    );
    Ok(value)
}

/// v5 POST 响应 → 档位表（kotlin-tv `MobilePlayback` 的解析段）。
fn video_model_rows(raw: &[u8], vid: &str) -> ApiResult<Vec<QualityRow>> {
    let root = raw_json(raw)?;
    let root_obj = root.as_object().cloned().unwrap_or_default();
    let code = field_int(&root_obj, &["Code", "code", "status_code"]);
    if code != 0 {
        return Err(ApiError::internal("hq取流失败：video_model 接口暂不可用"));
    }
    let data = root
        .get("data")
        .and_then(Value::as_object)
        .ok_or_else(|| ApiError::internal("hq取流失败：video_model 没有对应视频"))?;
    let entries = data
        .get("1004")
        .and_then(Value::as_object)
        .unwrap_or(data);
    let entry = entries
        .get(vid)
        .and_then(Value::as_object)
        .ok_or_else(|| ApiError::internal("hq取流失败：video_model 没有对应视频"))?;
    let model = match entry.get("video_model") {
        Some(Value::String(s)) => raw_json(s.as_bytes())
            .map_err(|_| ApiError::internal("hq取流失败：video_model 内容无效"))?,
        Some(v) if v.is_object() => v.clone(),
        _ => return Err(ApiError::internal("hq取流失败：video_model 内容为空")),
    };
    let rows = rendition_rows(&model);
    if rows.is_empty() {
        return Err(ApiError::internal("hq取流失败：没有可用清晰度"));
    }
    Ok(rows)
}

/// kotlin-tv `tabVideoModel(strict = true)`：pin 刚才 POST 的设备（同一注册
/// 身份）经 `video_tab` GET 重查当前集；任何失败返回 None，调用方保留原错误。
async fn fetch_video_tab_model(
    up: &Arc<UpstreamClient>,
    vid: &str,
    device: &Device,
) -> Option<Value> {
    let extra = [
        ("video_id", vid),
        ("video_id_type", "0"),
        ("device_level", "1"),
        ("need_all_video_definition", "1"),
        ("need_mp4_align", "0"),
        ("use_os_player", "0"),
        ("video_platform", "1024"),
        ("source", "0"),
        ("from_video_id", ""),
    ];
    let (raw, _) = up
        .v5_get_with_device(V5_VIDEO_TAB_URL, &extra, Some(&device.device_id))
        .await
        .ok()?;
    tab_video_model(&raw, vid)
}

/// `video_tab` GET 响应的 strict 解析（kotlin-tv `tabVideoModel`）：空正文、
/// 非 0 code、结构不符一律 None；`data.video_model_data` 只认当前集 vid，
/// 不借用其它集的模型；`video_model` 兼容字符串 JSON / 内联对象。
fn tab_video_model(raw: &[u8], vid: &str) -> Option<Value> {
    if raw.is_empty() {
        return None;
    }
    let root = raw_json(raw).ok()?;
    let root_obj = root.as_object()?;
    let code = field_int(root_obj, &["Code", "code", "status_code"]);
    if code != 0 {
        return None;
    }
    let data = root.get("data")?.as_object()?;
    let entries = data
        .get("video_model_data")
        .and_then(Value::as_object)
        .unwrap_or(data);
    let entry = entries.get(vid)?.as_object()?;
    match entry.get("video_model") {
        Some(Value::String(s)) => raw_json(s.as_bytes()).ok(),
        Some(v) if v.is_object() => Some(v.clone()),
        _ => None,
    }
}

/// cjs `resolveStream` 的档位选择：`quality > 0` 选对应高度档，否则最高档。
fn select_quality_row<'a>(rows: &'a [QualityRow], quality: i64) -> Option<&'a QualityRow> {
    if quality > 0 {
        rows.iter().find(|row| row.number == quality)
    } else {
        rows.first()
    }
}

/// 集视频 id：chapter `videoUrl` 的 `hongguo-cenc://<vid>` 优先，
/// 回退 `id` 末段（ArkTS `fqHongguoEpisodeVid` 同语义）。
fn chapter_vid(chapter: &Map<String, Value>) -> String {
    let video_url = first_text(chapter, &["videoUrl"]);
    if let Some(marker) = video_url.find("hongguo-cenc://") {
        let vid = video_url[marker + "hongguo-cenc://".len()..].trim();
        if !vid.is_empty() {
            return vid.to_string();
        }
    }
    let id = first_text(chapter, &["id"]);
    if id.is_empty() {
        return String::new();
    }
    match id.rsplit_once(':') {
        Some((_, vid)) => vid.trim().to_string(),
        None => id,
    }
}

// ---------------------------------------------------------------------------
// HTTP handlers
// ---------------------------------------------------------------------------

/// `GET /api/v1/hongguo/native/catalog?source=&category=&page=`：
/// `short_play`（短剧 SSR）/ `comic_series`（漫剧 App 搜索 + 榜单回退）。
fn handle_catalog<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        if params.get_str("source").is_empty() {
            return Err(ApiError::bad_request("缺少source参数"));
        }
        if params.get_str("category").is_empty() {
            return Err(ApiError::bad_request("缺少category参数"));
        }
        let page = (params.get_int("page", 1).max(1)) as u32;
        let (items, has_more) = match params.get_str("category").as_str() {
            "short_play" => short_play_page(&ctx.up, page).await?,
            "comic_series" => comic_series_page(&ctx.up, page).await?,
            other => return Err(ApiError::bad_request(format!("不支持的category参数：{other}"))),
        };
        Ok(json!({ "items": items, "hasMore": has_more, "page": page }))
    })
}

/// `GET /api/v1/hongguo/native/detail?drama_id=hongguo:<id>&title=`：
/// 官网详情 `vid_list` → chapters。
fn handle_detail<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let drama_id = params.get_str("drama_id");
        let Some((_, sid)) = drama_id.split_once(':') else {
            return Err(ApiError::bad_request("缺少有效的drama_id参数"));
        };
        if !crate::endpoints::hongguo::client::is_numeric_id(sid) {
            return Err(ApiError::bad_request("缺少有效的drama_id参数"));
        }
        let detail = web::fetch_series_detail(&ctx.up, sid).await?;
        let sid = sid.to_string();
        let chapters: Vec<Value> = detail
            .vids
            .iter()
            .enumerate()
            .map(|(index, vid)| {
                json!({
                    "id": format!("hongguo:{sid}:{vid}"),
                    "title": format!("第{}集", index + 1),
                    "videoUrl": format!("hongguo-cenc://{vid}"),
                })
            })
            .collect();
        Ok(json!({ "chapters": chapters, "title": detail.title }))
    })
}

/// `GET /api/v1/hongguo/native/media?drama_id=&chapter=&index=&quality=
/// &mode=&title=`：取流（CDN 直返 + CENC 密钥）；`mode=download`
/// 代下载整集（CENC 密文 + key sidecar 落 `src/`，url 改写 `/src/`
/// 明文本地路径，按需解密）。
fn handle_media<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let drama_id = params.get_str("drama_id");
        if drama_id.is_empty() || !drama_id.contains(':') {
            return Err(ApiError::bad_request("缺少有效的drama_id参数"));
        }
        let chapter: Value = match serde_json::from_str(&params.get_str("chapter")) {
            Ok(v @ Value::Object(_)) => v,
            _ => return Err(ApiError::bad_request("chapter须为有效的JSON对象")),
        };
        let chapter_obj = chapter.as_object().expect("chapter checked as object");
        let vid = chapter_vid(chapter_obj);
        if vid.is_empty() {
            return Err(ApiError::bad_request("chapter缺少剧集vid"));
        }
        let quality = params.get_int("quality", 0);
        let info = fetch_video_info(&ctx.up, &vid).await?;
        let row = select_quality_row(&info.rows, quality)
            .ok_or_else(|| ApiError::internal("hq取流失败：没有可用清晰度"))?;
        // main_url 在 fetch_video_info 已解密成最终 CDN 地址。
        let url = clean_url(&row.main_url);
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return Err(ApiError::internal("hq取流失败：播放地址解密失败"));
        }
        let key = crate::endpoints::video::derive_spade_content_key(&row.spade_a);
        let qualities = quality_list(&info.rows);
        let mut out = json!({
            "url": url,
            "headers": {},
            "decryptionKey": hex::encode(&key),
            "quality": row.number,
            "qualities": qualities,
            "danmakuId": vid,
            "local": false,
        });
        if params.get_str("mode") == "download" {
            let cache_id = if row.number > 0 {
                format!("hg_{vid}_{}", row.number)
            } else {
                format!("hg_{vid}")
            };
            let local = crate::endpoints::video::download_and_save(
                ctx,
                &cache_id,
                &url,
                &key,
                crate::endpoints::video::DownloadKind::Video,
            )
            .await
            .map_err(ApiError::internal)?;
            out["url"] = Value::String(local);
            out["local"] = Value::Bool(true);
        }
        Ok(out)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoints::Params;

    // ---------- 条目映射 ----------

    #[test]
    fn ssr_series_fields_maps_recommend_item() {
        let item = json!({
            "series_id": "7381000000000000000",
            "series_name": "测试短剧",
            "series_cover": "https://img.example/a.jpg\\/b?x=1\\u0026y=2&amp;z=3",
            "episode_cnt": 24,
            "series_intro": "简介",
            "category_list": [{"name": "都市"}, {"name": "逆袭"}],
        });
        let f = ssr_series_fields(&item).unwrap();
        assert_eq!(f.id, "7381000000000000000");
        assert_eq!(f.title, "测试短剧");
        assert_eq!(f.cover, "https://img.example/a.jpg/b?x=1&y=2&z=3");
        assert_eq!(f.episodes, 24);
        assert_eq!(f.tags, vec!["都市", "逆袭"]);
        let drama = series_to_drama(&f, "短剧");
        assert_eq!(drama["id"], "7381000000000000000");
        assert_eq!(drama["source"], "hongguo");
        assert_eq!(drama["category"], "短剧");
        assert_eq!(drama["vip"], false);
    }

    #[test]
    fn ssr_series_fields_prefers_video_data_and_requires_title() {
        let item = json!({
            "name": "外层名",
            "video_data": {
                "series_id": 123,
                "series_title": "内层标题",
                "series_episode_info": { "episode_cnt": 8 },
            },
        });
        let f = ssr_series_fields(&item).unwrap();
        assert_eq!(f.id, "123");
        assert_eq!(f.title, "内层标题");
        assert_eq!(f.episodes, 8);
        // 缺 id / 缺标题 → 丢弃。
        assert!(ssr_series_fields(&json!({ "series_name": "x" })).is_none());
        assert!(ssr_series_fields(&json!({ "series_id": "1" })).is_none());
    }

    #[test]
    fn search_series_fields_maps_cell_with_video_array() {
        let cell = json!({
            "video_data": [{
                "series_id": "728",
                "title": "视频标题",
                "cover": "https://img.example/c.jpg",
                "episode_cnt": 12,
                "video_desc": "漫剧简介",
            }],
            "search_high_light": { "title": { "text": "高亮标题" } },
            "cell_name": "单元格名",
        });
        let f = search_series_fields(&cell).unwrap();
        assert_eq!(f.id, "728");
        assert_eq!(f.title, "高亮标题");
        assert_eq!(f.episodes, 12);
        assert_eq!(f.intro, "漫剧简介");
        // 无 video_data → 丢弃。
        assert!(search_series_fields(&json!({ "cell_name": "x" })).is_none());
    }

    #[test]
    fn rank_series_fields_maps_camel_case() {
        let item = json!({
            "seriesId": "9001",
            "title": "榜单剧",
            "cover": "https://img.example/r.jpg",
            "description": "榜单简介",
            "episodeCount": 30,
        });
        let f = rank_series_fields(&item).unwrap();
        assert_eq!(f.id, "9001");
        assert_eq!(f.title, "榜单剧");
        assert_eq!(f.episodes, 30);
    }

    // ---------- 榜单解析 ----------

    #[test]
    fn parses_rank_payload_from_html() {
        // 真实页面里 JSON 是 HTML 转义后的（&quot;），解析前须 decode_html。
        let args = r#"[0,{&quot;a&quot;:1},{&quot;isSuccess&quot;:true,&quot;rankList&quot;:[{&quot;seriesId&quot;:&quot;1&quot;,&quot;title&quot;:&quot;A&quot;}],&quot;pagination&quot;:{&quot;totalPages&quot;:3}}]"#;
        let html = format!(r#"<div data-fn-name="r" data-fn-args="{args}"></div>"#);
        let payload = parse_rank_payload(&html).unwrap();
        assert_eq!(payload["rankList"][0]["seriesId"], "1");
        assert_eq!(payload["pagination"]["totalPages"], 3);
    }

    #[test]
    fn rank_payload_requires_success_and_list() {
        assert!(parse_rank_payload("<html></html>").is_err());
        let html = r#"<div data-fn-name="r" data-fn-args="[0,1,{&quot;isSuccess&quot;:false}]"></div>"#;
        assert!(parse_rank_payload(html).is_err());
    }

    #[test]
    fn rank_router_payload_reads_new_ssr_shape() {
        // 官网改版后：loaderData["rank_<route>/page"].content 携带榜单数据。
        let data = json!({
            "loaderData": {
                "rank_layout": null,
                "rank_hot-comic-drama/page": {
                    "rankKey": "comic",
                    "content": {
                        "isSuccess": true,
                        "rankList": [
                            { "seriesId": "9001", "title": "榜单剧", "episodeCount": 30 }
                        ],
                        "pagination": { "total": 100, "pageNum": 1, "totalPages": 3 },
                    },
                }
            }
        });
        let payload = rank_router_payload(&data).expect("router payload");
        assert_eq!(payload["pagination"]["totalPages"], 3);
        let f = rank_series_fields(&payload["rankList"][0]).unwrap();
        assert_eq!(f.id, "9001");
        assert_eq!(f.episodes, 30);
        // 布局键（rank_layout）不是数据源；无 rank_* 页对象时返回 None。
        assert!(rank_router_payload(&json!({
            "loaderData": { "rank_layout": { "content": { "rankList": [] } } }
        }))
        .is_none());
        assert!(rank_router_payload(&json!({ "loaderData": {} })).is_none());
        assert!(rank_router_payload(&json!({})).is_none());
    }

    // ---------- 清晰度 ----------

    #[test]
    fn quality_number_matches_cjs() {
        assert_eq!(quality_number("超清1080P"), 1080);
        assert_eq!(quality_number("高清720"), 720);
        assert_eq!(quality_number("2160"), 2160);
        assert_eq!(quality_number("1920"), 1080);
        assert_eq!(quality_number("1280"), 720);
        assert_eq!(quality_number("1090"), 1090);
        assert_eq!(quality_number("auto"), 0);
        assert_eq!(quality_number("流畅"), 0);
        assert_eq!(quality_number("480_360"), 480);
    }

    #[test]
    fn rendition_rows_collect_and_sort() {
        let model = json!({
            "video_list": {
                "video_720p": { "quality_desc": "高清720", "main_url": "https://x/720", "spade_a": "SA720" },
                "video_1080p": { "quality_desc": "超清1080P", "main_url": "https://x/1080", "spade_a": "SA1080" },
                "video_no_url": { "quality_desc": "480P", "spade_a": "SA480" },
                "video_auto": { "main_url": "https://x/auto" },
            }
        });
        let rows = rendition_rows(&model);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].number, 1080);
        assert_eq!(rows[0].main_url, "https://x/1080");
        assert_eq!(rows[0].spade_a, "SA1080");
        assert_eq!(rows[1].number, 720);
        assert_eq!(rows[2].number, 0);
        assert_eq!(rows[2].main_url, "https://x/auto");
        assert_eq!(quality_list(&rows), vec![1080, 720]);
        // 选档：指定高度命中，否则最高档。
        assert_eq!(select_quality_row(&rows, 720).unwrap().number, 720);
        assert_eq!(select_quality_row(&rows, 0).unwrap().number, 1080);
        assert!(select_quality_row(&rows, 4320).is_none());
    }

    #[test]
    fn rendition_rows_skip_bytevc2_codecs() {
        let model = json!({
            "video_list": {
                "v1": { "codec_type": "bytevc2", "main_url": "https://x/1" },
                "v2": { "main_url": "https://x/2", "video_meta": { "codec_type": "h265_bvc2" } },
                "v3": { "gear_des_key": "bvc2_1080", "main_url": "https://x/3" },
                "v4": { "main_url": "https://x/4" },
            }
        });
        let rows = rendition_rows(&model);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].main_url, "https://x/4");
    }

    #[test]
    fn rendition_rows_reject_encrypted_entries_without_key() {
        let model = json!({
            "video_list": {
                "v_enc": { "main_url": "https://x/enc", "encrypt_info": { "encrypt": 1 } },
                "v_off0": { "main_url": "https://x/off0", "encrypt_info": { "encrypt": 0 } },
                "v_offfalse": { "main_url": "https://x/off", "encrypt_info": { "encrypt": false } },
                "v_keyed": { "main_url": "https://x/keyed", "encrypt_info": { "encrypt": 1, "spade_a": "SA" } },
            }
        });
        let rows = rendition_rows(&model);
        let urls: Vec<&str> = rows.iter().map(|r| r.main_url.as_str()).collect();
        // 加密开启但没有 spade_a 的档位不可播，encrypt 关闭的保留。
        assert!(!urls.contains(&"https://x/enc"));
        assert!(urls.contains(&"https://x/off0"));
        assert!(urls.contains(&"https://x/off"));
        assert!(urls.contains(&"https://x/keyed"));
        assert_eq!(
            rows.iter().find(|r| r.main_url == "https://x/keyed").unwrap().spade_a,
            "SA"
        );
    }

    #[test]
    fn rendition_rows_accepts_array_list_and_b64_urls() {
        use base64::Engine as _;
        let url = base64::engine::general_purpose::STANDARD.encode("https://x/480");
        let model = json!({
            "video_list": [
                { "height": "480", "main_url": url },
                { "quality_desc": "无url" },
            ]
        });
        let rows = rendition_rows(&model);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 480);
        assert_eq!(rows[0].main_url, "https://x/480");
    }

    #[test]
    fn rendition_rows_derives_quality_from_dimensions() {
        let model = json!({
            "video_list": {
                "v": { "vwidth": 1080, "vheight": 1920, "main_url": "https://x/v" },
            }
        });
        let rows = rendition_rows(&model);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 1080);
    }

    #[test]
    fn chapter_vid_from_video_url_or_id() {
        let chapter = json!({
            "id": "hongguo:738:999",
            "title": "第1集",
            "videoUrl": "hongguo-cenc://999",
        });
        assert_eq!(chapter_vid(chapter.as_object().unwrap()), "999");
        // 无 videoUrl → id 末段。
        let chapter = json!({ "id": "hongguo:738:888", "title": "第2集" });
        assert_eq!(chapter_vid(chapter.as_object().unwrap()), "888");
        // videoUrl marker 后为空 → id 末段。
        let chapter = json!({ "id": "hongguo:738:777", "videoUrl": "hongguo-cenc://" });
        assert_eq!(chapter_vid(chapter.as_object().unwrap()), "777");
        // 全空。
        assert_eq!(chapter_vid(json!({ "title": "x" }).as_object().unwrap()), "");
    }

    // ---------- video_tab 兜底（kotlin-tv 0.16.10 / #72） ----------

    fn sample_model() -> Value {
        json!({
            "video_list": [
                { "height": "480", "main_url": "aHR0cHM6Ly94LzQ4MA==" },
            ]
        })
    }

    #[test]
    fn video_model_rows_maps_post_response() {
        let raw = json!({
            "code": 0,
            "data": { "1004": { "111": { "video_model": sample_model() } } }
        })
        .to_string();
        let rows = video_model_rows(raw.as_bytes(), "111").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 480);
        // video_model 为字符串 JSON 时同样可解。
        let raw = json!({
            "code": 0,
            "data": { "1004": { "111": { "video_model": sample_model().to_string() } } }
        })
        .to_string();
        assert_eq!(video_model_rows(raw.as_bytes(), "111").unwrap().len(), 1);
        // 非 0 code / 当前集缺失 / 空档位。
        let bad_code = json!({ "code": 10001, "data": {} }).to_string();
        assert!(video_model_rows(bad_code.as_bytes(), "111").is_err());
        let no_entry = json!({ "code": 0, "data": { "1004": { "222": {} } } }).to_string();
        assert!(video_model_rows(no_entry.as_bytes(), "111").is_err());
        let no_rows = json!({
            "code": 0,
            "data": { "1004": { "111": { "video_model": { "video_list": [] } } } }
        })
        .to_string();
        assert!(video_model_rows(no_rows.as_bytes(), "111").is_err());
    }

    #[test]
    fn tab_video_model_reads_current_episode_only() {
        let raw = json!({
            "code": 0,
            "data": { "video_model_data": { "111": { "video_model": sample_model() } } }
        })
        .to_string();
        let model = tab_video_model(raw.as_bytes(), "111").unwrap();
        assert!(model.get("video_list").is_some());
        // strict：只认当前集，不借用其它集的模型。
        assert!(tab_video_model(raw.as_bytes(), "222").is_none());
        // video_model 为字符串 JSON 时同样可解。
        let raw = json!({
            "code": 0,
            "data": { "video_model_data": { "111": { "video_model": sample_model().to_string() } } }
        })
        .to_string();
        assert!(tab_video_model(raw.as_bytes(), "111").is_some());
    }

    #[test]
    fn tab_video_model_rejects_empty_bad_code_and_shape() {
        // 空正文（kotlin-tv EmptyPlaybackResponseException 场景）。
        assert!(tab_video_model(b"", "111").is_none());
        // 非 0 code。
        let bad_code = json!({ "code": 100103, "data": {} }).to_string();
        assert!(tab_video_model(bad_code.as_bytes(), "111").is_none());
        // 无 data / 无当前集 / video_model 既非字符串也非对象。
        let no_data = json!({ "code": 0 }).to_string();
        assert!(tab_video_model(no_data.as_bytes(), "111").is_none());
        let no_entry = json!({ "code": 0, "data": { "video_model_data": { "222": {} } } })
            .to_string();
        assert!(tab_video_model(no_entry.as_bytes(), "111").is_none());
        let bad_model = json!({
            "code": 0,
            "data": { "video_model_data": { "111": { "video_model": 3 } } }
        })
        .to_string();
        assert!(tab_video_model(bad_model.as_bytes(), "111").is_none());
    }

    // ---------- 路由 ----------

    #[test]
    fn routes_map_native_paths() {
        use crate::endpoints::router::match_rest_path;
        let cases = [
            ("catalog", Some("hongguo_native_catalog")),
            ("detail", Some("hongguo_native_detail")),
            ("media", Some("hongguo_native_media")),
            // 无调用方的 Go 时代端点随 Go 核心一并退役。
            ("boards", None),
            ("categories", None),
            ("rankings", None),
            ("recommendations", None),
            ("suggestions", None),
            ("danmaku", None),
            ("map", None),
            ("", None),
        ];
        for (tail, expected) in cases {
            let path = format!("/api/v1/hongguo/native/{tail}");
            let got = match_rest_path(&path, &Params::new()).map(|m| m.api);
            assert_eq!(got, expected, "path: {path}");
        }
        assert_eq!(
            match_rest_path("/api/v1/hongguo/map", &Params::new()).unwrap().api,
            "hongguo_map"
        );
        assert_eq!(
            match_rest_path("/api/v1/hongguo/danmaku", &Params::new()).unwrap().api,
            "hongguo_danmaku"
        );
        // query 原样透传。
        let q = Params::parse("source=hongguo&category=short_play&page=2");
        let m = match_rest_path("/api/v1/hongguo/native/catalog", &q).unwrap();
        assert_eq!(m.params.get_str("category"), "short_play");
        assert_eq!(m.params.get_int("page", 1), 2);
    }

    // ---------- decode_html ----------

    #[test]
    fn decode_html_unescapes_entities() {
        assert_eq!(decode_html("a&quot;b&#x2F;c&#39;d&lt;e&gt;f&amp;g"), "a\"b/c'd<e>f&g");
    }
}
