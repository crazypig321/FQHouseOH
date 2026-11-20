//! 红果免费短剧弹幕源（番茄剧集 → 红果弹幕映射，方案 A）+ 原生内容源。
//!
//! - [`handle_hongguo_map`]：`/api/v1/hongguo/map?series_id=<番茄id>&title=<剧名>`
//!   用红果官网搜索（kotlin-tv `searchAll`，[`web::fetch_search_result`]）
//!   做标题 rank 匹配（exact/prefix/contains/全词，见 [`mapping::RANK_ACCEPT`]），
//!   再抓 hongguoduanju.com 网页详情拿 `vid_list`，缓存映射结果。
//! - [`handle_hongguo_danmaku`]：`/api/v1/hongguo/danmaku?series_id=<红果id>&vid=<红果vid>`
//!   用 comment 签名（进程级随机设备，免注册）请求红果弹幕，
//!   响应结构与番茄弹幕同构（`fqParseDanmaku` 兼容），原样透传。
//! - [`native`]：`/api/v1/hongguo/native/{catalog|detail|media}` 原生内容源
//!   （Rust 原生实现，替换原 Go 核心 `libduanju_core.so`）。
//!
//! 映射失败时 ArkTS 侧回退番茄弹幕源，本模块只报错不做回退。
//!
//! 签名与链路移植自 hongguoTV（GPL-3.0，本项目同 license）：V4 套件
//! `server/vendor/hongguo.cjs`（drpys），搜索/取流 kotlin-tv
//! `ContentRepository` / `MobilePlayback`；comment 签名移植 guoapp
//! `provider_hongguo_comment_sign.go`，网页解析 `provider_hongguo.go`，
//! 匹配 `provider_hongguo_search.go`。

mod client;
mod mapping;
mod native;
mod sign;
pub(crate) mod vsign;
mod web;
pub(crate) mod web_login;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::hongguo::client::{fresh_comment_device, is_numeric_id};
use crate::endpoints::hongguo::mapping::{title_search_rank, SearchCandidate, RANK_ACCEPT};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use crate::timeutil::now_millis;

const SEARCH_CACHE_TTL_MS: i64 = 5 * 60 * 1000;
const SEARCH_CACHE_CAP: usize = 64;
const DETAIL_CACHE_TTL_MS: i64 = 10 * 60 * 1000;
const DETAIL_CACHE_CAP: usize = 64;
const MAP_CACHE_TTL_MS: i64 = 30 * 60 * 1000;
const MAP_CACHE_NEGATIVE_TTL_MS: i64 = 2 * 60 * 1000;
const MAP_CACHE_CAP: usize = 128;

pub fn register(s: &mut Server) {
    s.add_route("hongguo_map", handle_hongguo_map);
    s.add_route("hongguo_danmaku", handle_hongguo_danmaku);
    native::register(s);
}

struct CacheEntry<T> {
    value: T,
    expires_at: i64,
}

struct State {
    comment_device: (String, String),
    search_cache: Mutex<HashMap<String, CacheEntry<Arc<Vec<SearchCandidate>>>>>,
    detail_cache: Mutex<HashMap<String, CacheEntry<(String, Arc<Vec<String>>)>>>,
    map_cache: Mutex<HashMap<String, CacheEntry<Value>>>,
}

static STATE: OnceLock<State> = OnceLock::new();

fn state() -> &'static State {
    STATE.get_or_init(|| State {
        comment_device: fresh_comment_device(),
        search_cache: Mutex::new(HashMap::new()),
        detail_cache: Mutex::new(HashMap::new()),
        map_cache: Mutex::new(HashMap::new()),
    })
}

impl State {
    fn cache_get<T>(map: &Mutex<HashMap<String, CacheEntry<T>>>, key: &str) -> Option<T>
    where
        T: Clone,
    {
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

    fn cache_put<T>(map: &Mutex<HashMap<String, CacheEntry<T>>>, key: &str, value: T, ttl_ms: i64, cap: usize) {
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
}

/// 搜索红果剧集（按关键词缓存 5 分钟）：官网搜索 JSON 接口
/// （kotlin-tv `searchAll`，免签名，完整客户端 UA + Referer）。
/// 结果可为空（番茄独有剧在红果没有对端），由调用方决定 matched:false。
async fn search_candidates(ctx: &Ctx, keyword: &str) -> ApiResult<Arc<Vec<SearchCandidate>>> {
    if let Some(c) = State::cache_get(&state().search_cache, keyword) {
        return Ok(c);
    }
    let result = web::fetch_search_result(&ctx.up, keyword, 1).await?;
    let candidates = Arc::new(mapping::parse_website_search_candidates(&result));
    State::cache_put(
        &state().search_cache,
        keyword,
        candidates.clone(),
        SEARCH_CACHE_TTL_MS,
        SEARCH_CACHE_CAP,
    );
    Ok(candidates)
}

/// 抓红果剧集网页详情拿 vid_list（按红果 series_id 缓存 10 分钟）。
async fn series_vids(ctx: &Ctx, hongguo_series_id: &str) -> ApiResult<(String, Arc<Vec<String>>)> {
    if let Some(d) = State::cache_get(&state().detail_cache, hongguo_series_id) {
        return Ok(d);
    }
    let detail = web::fetch_series_detail(&ctx.up, hongguo_series_id).await?;
    let out = (detail.title, Arc::new(detail.vids));
    State::cache_put(
        &state().detail_cache,
        hongguo_series_id,
        out.clone(),
        DETAIL_CACHE_TTL_MS,
        DETAIL_CACHE_CAP,
    );
    Ok(out)
}

/// `GET /api/v1/hongguo/map?series_id=<番茄id>&title=<剧名>` → 红果映射。
fn handle_hongguo_map<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let fanqie_series_id = params.get_str("series_id");
        if !is_numeric_id(&fanqie_series_id) {
            return Err(ApiError::bad_request("缺少有效的series_id参数"));
        }
        let title = params.get_str("title").trim().to_string();
        if title.is_empty() || title.chars().count() > 80 || title.chars().any(|c| c.is_control())
        {
            return Err(ApiError::bad_request("title须为1至80个字符"));
        }

        if let Some(cached) = State::cache_get(&state().map_cache, &fanqie_series_id) {
            return Ok(cached);
        }

        let candidates = search_candidates(ctx, &title).await?;
        // rank 最低者胜；同 rank 取搜索序在前者（guoapp 的稳定排序语义）。
        let mut best: Option<(u8, &SearchCandidate)> = None;
        for c in candidates.iter() {
            let rank = title_search_rank(&c.title, &title);
            if best.is_none_or(|(br, _)| rank < br) {
                best = Some((rank, c));
            }
        }
        // 搜索为空（番茄独有剧）或全部超 rank：按未匹配缓存，走番茄弹幕。
        let Some((rank, candidate)) = best else {
            let resp = json!({ "matched": false, "series_id": fanqie_series_id });
            State::cache_put(
                &state().map_cache,
                &fanqie_series_id,
                resp.clone(),
                MAP_CACHE_NEGATIVE_TTL_MS,
                MAP_CACHE_CAP,
            );
            return Ok(resp);
        };
        if rank > RANK_ACCEPT {
            let resp = json!({ "matched": false, "series_id": fanqie_series_id });
            State::cache_put(
                &state().map_cache,
                &fanqie_series_id,
                resp.clone(),
                MAP_CACHE_NEGATIVE_TTL_MS,
                MAP_CACHE_CAP,
            );
            return Ok(resp);
        }

        let (hg_title, vids) = series_vids(ctx, &candidate.series_id).await?;
        let resp = json!({
            "matched": true,
            "series_id": fanqie_series_id,
            "hongguo_series_id": candidate.series_id,
            "title": hg_title,
            "episode_count": vids.len(),
            "vids": vids.as_ref(),
        });
        State::cache_put(
            &state().map_cache,
            &fanqie_series_id,
            resp.clone(),
            MAP_CACHE_TTL_MS,
            MAP_CACHE_CAP,
        );
        Ok(resp)
    })
}

/// `GET /api/v1/hongguo/danmaku?series_id=<红果id>&vid=<红果vid>
/// &start_offset_time=<ms>&playlet_item_duration=<秒>&cursor=<续拉串>`
/// → 红果弹幕（响应结构与番茄弹幕同构，原样透传给 `fqParseDanmaku`）。
///
/// 参数语义与番茄弹幕 endpoint（`playlet_danmaku`）一致：进度毫秒、时长秒；
/// `cursor` 为响应 `common_list_info.cursor` 回传的续拉串（首页空串）。
fn handle_hongguo_danmaku<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let series_id = params.get_str("series_id");
        let vid = params.get_str("vid");
        if !is_numeric_id(&series_id) {
            return Err(ApiError::bad_request("缺少有效的series_id参数"));
        }
        if !is_numeric_id(&vid) {
            return Err(ApiError::bad_request("缺少有效的vid参数"));
        }
        let cursor = params.get_str("cursor");
        if cursor.len() > 16_384 || cursor.chars().any(|c| c.is_control()) {
            return Err(ApiError::bad_request("cursor参数无效"));
        }
        // 时长秒 → 毫秒；进度毫秒（与番茄弹幕 endpoint 相同）。
        let duration_ms = params.get_int("playlet_item_duration", 0).saturating_mul(1000);
        let start_ms = params.get_int("start_offset_time", 0).min(duration_ms.saturating_sub(1));
        client::validate_danmaku_window(start_ms, duration_ms)?;

        let (device_id, install_id) = state().comment_device.clone();
        client::fetch_danmaku(
            &ctx.up, &device_id, &install_id, &series_id, &vid, start_ms, duration_ms, &cursor,
        )
        .await
    })
}

#[cfg(test)]
mod tests;
