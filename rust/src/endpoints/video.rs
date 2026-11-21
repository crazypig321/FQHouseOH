//! Video endpoints: the multi-quality video resolver plus the short-drama
//! series detail and episode-list endpoints.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use base64::Engine;
use futures::future::BoxFuture;
use once_cell::sync::Lazy;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha512};
use tokio::io::AsyncWriteExt;
use tokio::time::Instant;

use crate::endpoints::base::{
    video_detail_headers, video_detail_url, Upstream, UpstreamMode, UpstreamRequestSpec,
    UA_ANDROID_BROWSER, UA_WINDOWS_BROWSER,
};
use crate::endpoints::util::{default_val, go_query_escape, int_default, user_agent_headers};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use crate::upstream::UpstreamRequest;

/// The spade derivation constant table from video.go.
const SPADE_CONSTANTS: [u8; 64] = [
    77, 212, 194, 230, 184, 49, 98, 9, 14, 82, 179, 199, 166, 115, 59, 164, 28, 178, 70, 43, 130,
    154, 181, 138, 25, 107, 57, 219, 87, 23, 117, 36, 244, 155, 175, 127, 8, 232, 214, 141, 38,
    167, 46, 55, 193, 169, 90, 47, 31, 5, 165, 24, 146, 174, 242, 148, 151, 50, 182, 42, 56, 170,
    221, 88,
];

const FALLBACK_USER_AGENT: &str = "com.xs.fm/632 (Linux; U; Android 15; zh_CN; 23049RAD8C; Build/AQ3A.250226.002; Cronet/TTNetVersion:fc4cebd3 2024-12-10 QuicVersion:d9628e3d 2024-10-11)";

const VIDEO_FETCH_BUDGET: Duration = Duration::from_secs(12);
const VIDEO_RESOLUTION_BUDGET: Duration = Duration::from_secs(14);
const VIDEO_RESOLUTION_RESERVE: Duration = Duration::from_secs(2);
const VIDEO_WORK_BUDGET: Duration = Duration::from_secs(18);
const VIDEO_VARIANT_BUDGET: Duration = Duration::from_secs(4);
const VIDEO_RESPONSE_RESERVE: Duration = Duration::from_secs(1);
static STREAM_TRACE_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

const V5_PLAYER_URL: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1";

/// The official app's `GET` playback-model door carrying the model list, used
/// as the second attempt when the v5 player door answers an empty body.
const VIDEO_TAB_PLAYER_PATH: &str = "/reading/bookapi/video_tab/multi_video_model/v1/";

/// Hard cap on playback-door attempts per request, re-probe and rotation round
/// included.
const MAX_PLAYBACK_ATTEMPTS: usize = 8;

/// A door that answers an empty body is probed once more after this pause: the
/// refusal is transient per request far more often than it is a verdict about
/// the identity, and the same door recovers by itself in a few hundred ms.
const SAME_DOOR_REPROBE_DELAY: Duration = Duration::from_millis(250);

/// The re-probe needs this much caller budget left: another round trip is not
/// worth starting when the caller is nearly out of time.
const REPROBE_MIN_BUDGET: Duration = Duration::from_millis(1_000);

/// A rotation needs this much caller budget left to be worth attempting: a
/// replacement registration is several round trips.
const ROTATION_MIN_BUDGET: Duration = Duration::from_millis(1_500);

/// Reading directory endpoint used as the primary pseries directory source.
const DIRECTORY_READING_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/directory/all_items/v?";
const DIRECTORY_READING_QUERY_SUFFIX: &str = "&book_info_md5=&need_version=true&device_id={device_id}&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&=&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10+8.0.0.556%28C00%29&compliance_status=0";

type CacheLocks = HashMap<PathBuf, Weak<tokio::sync::Mutex<()>>>;
static VIDEO_CACHE_LOCKS: Lazy<Mutex<CacheLocks>> = Lazy::new(|| Mutex::new(HashMap::new()));
static VIDEO_DOWNLOADS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

fn cache_entry_lock(path: &Path) -> Arc<tokio::sync::Mutex<()>> {
    let key = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let mut locks = VIDEO_CACHE_LOCKS.lock().unwrap_or_else(|e| e.into_inner());
    locks.retain(|_, lock| lock.strong_count() > 0);
    if let Some(lock) = locks.get(&key).and_then(Weak::upgrade) {
        return lock;
    }
    let lock = Arc::new(tokio::sync::Mutex::new(()));
    locks.insert(key, Arc::downgrade(&lock));
    lock
}

// Note: 编码拒绝必须穿透回退链，见 .agents/notes/implemented/bug-fix/2026-09-25-video-codec-gates.md
#[derive(Debug, PartialEq, Eq)]
enum VideoSourceResolution {
    Found(String, Vec<u8>),
    CodecRejected,
    NotFound,
}

impl VideoSourceResolution {
    fn is_terminal(&self) -> bool {
        !matches!(self, Self::NotFound)
    }
}

struct ParsedVideoResponse {
    root: Value,
    models: Vec<Map<String, Value>>,
    requested_video_id: Option<String>,
}

impl ParsedVideoResponse {
    fn parse(raw: &[u8], requested_video_id: Option<&str>) -> ApiResult<Self> {
        let root: Value = serde_json::from_slice(raw)
            .map_err(|e| ApiError::Internal(format!("parse upstream json: {e}")))?;
        let models = root
            .get("data")
            .and_then(Value::as_object)
            .map(|data| video_models(data, requested_video_id))
            .unwrap_or_default();
        Ok(Self {
            root,
            models,
            requested_video_id: requested_video_id.map(str::to_string),
        })
    }
}

enum FallbackResolution {
    Found(String, Vec<u8>),
    CodecRejected,
    NotFound,
    Inconclusive,
}

/// Request-local fallback bodies; failed or empty responses are never inserted.
type FallbackBodyCache = Arc<Mutex<HashMap<String, Arc<Map<String, Value>>>>>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum FallbackFetchFailure {
    Retryable,
    Permanent,
}

fn new_fallback_body_cache() -> FallbackBodyCache {
    Arc::new(Mutex::new(HashMap::new()))
}

// ---------------------------------------------------------------------------
// video.go
// ---------------------------------------------------------------------------

fn handle_video<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let video_id = default_val(&params.get_str("video_id"), &params.get_str("item_ids"));
        if video_id.is_empty() {
            return Err(ApiError::BadRequest("缺少video_id参数".to_string()));
        }

        let stream_mode = params.get_str("mode") == "stream";
        // 客户端选定的清晰度档（如 720P）：命中 variants 档时该档优先选流，
        // 下载缓存按档分文件；未传或未命中按最高可用档（原行为不变）。
        let quality = sanitize_quality(&params.get_str("quality"));
        let source_trace_id =
            STREAM_TRACE_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let purpose =
            crate::upstream::playback_trace::purpose(&params.get_str("_playback_purpose"));
        let work_started = Instant::now();
        let work_budget = crate::upstream::budget::remaining()
            .map(|left| left.saturating_sub(VIDEO_RESPONSE_RESERVE))
            .unwrap_or(VIDEO_WORK_BUDGET)
            .min(VIDEO_WORK_BUDGET);
        let variant_budget = VIDEO_VARIANT_BUDGET.min(work_budget / 4);
        let resolution_reserve = VIDEO_RESOLUTION_RESERVE.min(work_budget / 8);
        let fetch_budget = VIDEO_FETCH_BUDGET
            .min(work_budget.saturating_sub(variant_budget.saturating_add(resolution_reserve)));
        let resolution_budget =
            VIDEO_RESOLUTION_BUDGET.min(work_budget.saturating_sub(variant_budget));
        let work_deadline = work_started + work_budget;
        let fetch_deadline = work_started + fetch_budget;
        let resolution_deadline = work_started + resolution_budget;
        let parsed = crate::upstream::playback_trace::within(
            source_trace_id,
            purpose,
            fetch_parsed_video_response(
                "v5",
                &video_id,
                fetch_deadline,
                fetch_playback_model(ctx, &video_id, fetch_deadline, purpose),
            ),
        )
        .await
        .ok_or_else(|| ApiError::Internal("视频取流失败,请稍后重试".to_string()))?;
        let fallback_bodies = new_fallback_body_cache();
        let resolved = resolve_video_source_until(
            ctx,
            &video_id,
            "v5",
            &parsed,
            &fallback_bodies,
            resolution_deadline,
        )
        .await;

        // 官方 `wp3/o1.java:301-347` 的 `isSupportShowLandIcon` 按服务端
        // `vertical` 决定竖屏剧集是否给「全屏观看」（竖屏不给）。该字段随
        // 每集的 `VideoInfo.vertical` 下发，合成的取流响应原先把它丢了；
        // 这里透传出去，缺字段时为 null（Dart 侧保持旧行为，见 player_page）。
        let vertical = episode_vertical_value(&parsed.root, Some(&video_id));

        if matches!(resolved, VideoSourceResolution::NotFound)
            && legacy_raw_response_has_playable_url(&parsed)
        {
            log::info!(
                "stream trace request={source_trace_id} purpose={purpose} event=final mode={} selected_source=v5 bodies=1 quality_count=0 result=legacy_raw",
                if stream_mode { "stream" } else { "single" },
            );
            return Ok(parsed.root);
        }

        let (mut video_url, mut content_key) = match resolved {
            VideoSourceResolution::Found(url, key) => (url, key),
            VideoSourceResolution::CodecRejected => {
                log::warn!(
                    "stream trace request={source_trace_id} purpose={purpose} event=final result=codec_rejected"
                );
                return Err(ApiError::Internal("该视频暂不支持播放".to_string()));
            }
            VideoSourceResolution::NotFound => {
                log::warn!(
                    "stream trace request={source_trace_id} purpose={purpose} event=final result=not_found"
                );
                return Err(ApiError::Internal("视频取流失败，请稍后重试".to_string()));
            }
        };
        let variant_deadline = (Instant::now() + variant_budget).min(work_deadline);
        let (variants, variant_counts) = extract_stream_variants(
            ctx,
            &video_id,
            &parsed,
            &fallback_bodies,
            &video_url,
            source_trace_id,
            variant_deadline,
        )
        .await;
        debug_assert_eq!(
            variants.len(),
            variant_counts.kept,
            "kept must stay the same number the panel shows"
        );
        let primary_in_variants = variants
            .iter()
            .any(|variant| variant.get("url").and_then(Value::as_str) == Some(video_url.as_str()));
        let quality_trace = variants
            .iter()
            .filter_map(|variant| {
                Some(format!(
                    "{}:{}",
                    variant.get("name")?.as_str()?,
                    variant.get("quality_height")?.as_i64()?
                ))
            })
            .collect::<Vec<_>>()
            .join(",");
        log::info!(
            "stream trace request={source_trace_id} purpose={purpose} event=final mode={} selected_source=v5 bodies=1 fallback_bodies={} quality_count={} raw_entries={} kept={} dropped=[{}] qualities=[{quality_trace}] primary_in_variants={primary_in_variants}",
            if stream_mode { "stream" } else { "single" },
            fallback_bodies
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .len(),
            variants.len(),
            variant_counts.raw_entries,
            variant_counts.kept,
            variant_counts.dropped.summary(),
        );

        // 请求档命中：直接改用该档流（url + 内容密钥）。未请求档时默认档
        // 升级为合并列表最高可用档（2K/4K 除外）并回显实际档名——客户端
        // 清晰度按钮/菜单显示真实档位（此前 quality 恒空只能显示「清晰度」），
        // 缓存按档分文件（与手动选同档共享缓存）；合并列表为空（老形状
        // 上游不带档位）保持主解析选流，quality 为空。
        let mut served_quality = String::new();
        let mut cache_suffix = String::new();
        if let Some((url, key)) = quality_hit(&variants, &quality) {
            video_url = url;
            content_key = key;
            served_quality = quality.clone();
            cache_suffix = quality.clone();
        } else if quality.is_empty() {
            if let Some((url, key, name)) = top_default_variant(&variants) {
                video_url = url;
                content_key = key;
                served_quality = name.clone();
                cache_suffix = name;
            }
        }

        let source = json!({
            "video_url": video_url,
            "key_hex": hex::encode(&content_key),
            "video_id": video_id,
            "quality": served_quality.clone(),
            "source_trace_id": source_trace_id,
            // 分集方向（官方 `VideoInfo.vertical`）：缺字段时 null，客户端
            // 据此保持旧行为（显示「全屏观看」）。
            "vertical": vertical,
            // 全量兼容档（高→低）。官方面板按该列表渲染清晰度行；空数组
            // 表示单流，客户端隐藏清晰度入口。
            "variants": variants,
        });
        // 字节 VVC（bytevc2）档：mpv 的 libavformat 认不出字节私有的 bvc2
        // 标签（`sinf`→`frma`=`bvc2` + 配置盒 `bv2C`），stream 直连只建音频
        // 轨、黑屏有声（2026-11-21 实测 7704560470203567129 第十集全档
        // bvc2，hilog 只有 audio-reconfig 无 video-reconfig）。这类档不返回
        // 直链，落入下方下载解密链路（代下载 + box 重写 bvc2→vvi1/vvcC +
        // loopback 供流，mpv FFmpeg 8.0 原生软解 VVC）；普通编码集保持
        // stream 秒开不变。按最终选中 URL 反查行编码：选档覆盖（请求档/
        // 默认档）都来自 `variants` 行，主选流命中行时也能查到；老形状
        // （行里查不到）无编码信息，维持 stream 原行为。
        let selected_is_vvc = variants
            .iter()
            .find(|row| row.get("url").and_then(Value::as_str) == Some(video_url.as_str()))
            .and_then(|row| row.get("codec"))
            .and_then(Value::as_str)
            .is_some_and(|codec| codec.contains("bytevc2") || codec.contains("bvc2"));
        if stream_mode && selected_is_vvc {
            log::info!(
                "stream trace request={source_trace_id} purpose={purpose} event=vvc_fallback_download quality={served_quality}"
            );
        }
        if stream_mode && !selected_is_vvc {
            return Ok(source);
        }

        // 按档分缓存文件：默认档沿用 {video_id}（存量缓存兼容），选定档用
        // {video_id}_{quality}，切档互不覆盖、回切命中各自缓存。
        let cache_id = if cache_suffix.is_empty() {
            video_id.clone()
        } else {
            format!("{video_id}_{cache_suffix}")
        };

        // 非流式代下载的容错链：首轮用已选好的候选；失败后重取一次新流再试。
        // 设备端实测（rust.log 2026-11-12）：解析出的直链也会按设备网络被
        // 调度到拒绝服务的 CDN 边缘（v13-reading-video 域对设备 403，同一集
        // 对 PC 却 200），而不同次取流拿到的边缘域名不同（同集先后给过
        // v3 / v5-jx / v95 / v13）——重取即换边缘。不降档、不混档：重取后
        // 仍只下请求档（或同最高档）。
        for attempt in 1..=2u8 {
            if attempt > 1 {
                let retry_fetch_deadline = Instant::now() + Duration::from_secs(8);
                let retry_resolution_deadline = Instant::now() + Duration::from_secs(12);
                let reparsed = fetch_parsed_video_response(
                    "v5",
                    &video_id,
                    retry_fetch_deadline,
                    fetch_playback_model(ctx, &video_id, retry_fetch_deadline, purpose),
                )
                .await;
                let Some(reparsed) = reparsed else {
                    break;
                };
                let reresolved = resolve_video_source_until(
                    ctx,
                    &video_id,
                    "v5",
                    &reparsed,
                    &new_fallback_body_cache(),
                    retry_resolution_deadline,
                )
                .await;
                let (url, key) = match reresolved {
                    VideoSourceResolution::Found(url, key) => (url, key),
                    _ => break,
                };
                let (revariants, _) = extract_stream_variants(
                    ctx,
                    &video_id,
                    &reparsed,
                    &new_fallback_body_cache(),
                    &url,
                    source_trace_id,
                    Instant::now() + Duration::from_secs(4),
                )
                .await;
                // 请求档在重取的 variants 里重新命中（档与密钥都可能随取流
                // 变化）；命中不了且确实请求过档，则宁可放弃重试也不用别的
                // 档污染 {video_id}_{quality} 缓存。
                if let Some((q_url, q_key)) = quality_hit(&revariants, &quality) {
                    video_url = q_url;
                    content_key = q_key;
                } else if quality.is_empty() && cache_suffix.is_empty() {
                    // 未升级的老形状（合并列表为空）：重取主解析流换边缘。
                    video_url = url;
                    content_key = key;
                } else if quality.is_empty() {
                    // 默认档已升级为具名档：重取后同名档续试（换边缘换签名）；
                    // 档消失则放弃，不降档污染分档缓存。
                    match top_default_variant(&revariants) {
                        Some((retry_url, retry_key, retry_name)) if retry_name == cache_suffix => {
                            video_url = retry_url;
                            content_key = retry_key;
                        }
                        _ => break,
                    }
                } else {
                    break;
                }
            }
            match download_and_save(
                ctx,
                &cache_id,
                &video_url,
                &content_key,
                DownloadKind::Video,
            )
            .await
            {
                Ok(local_path) => {
                    let main_url = local_path.clone();
                    return Ok(json!({
                        "video_url": local_path,
                        "video_id": video_id,
                        "source_trace_id": source_trace_id,
                        "quality": served_quality,
                        "vertical": vertical,
                        "variants": source["variants"].clone(),
                        "video_info": {
                            "data": {
                                "video_list": {
                                    "video_1": { "main_url": main_url },
                                },
                            },
                        },
                    }));
                }
                // 下载失败旧版回退上游 URL——但那是 CENC 密文流，客户端解不了
                // 只能黑屏半天后 eof 跳集（离线下载器还会把密文缓存成坏文件）。
                // 重取一轮新流后仍失败才显式报错，让客户端立刻出重试卡（含
                // 离线缓存兜底）。
                Err(err) => {
                    // 失败日志带上 host + path（不带 query，避免签名参数刷进
                    // 日志）：403 排查时不同轮解析出的 CDN 路径不同，只看错误
                    // 码分不清是哪条 URL 被拒。
                    let target = url::Url::parse(&video_url)
                        .map(|u| format!("{}{}", u.host_str().unwrap_or("?"), u.path()))
                        .unwrap_or_else(|_| "?".to_string());
                    log::warn!(
                        "video {video_id}: download attempt {attempt} failed ({target}): {err}"
                    );
                }
            }
        }
        Err(ApiError::Internal("视频下载失败，请稍后重试".to_string()))
    })
}

/// 请求档命中：返回该档 (url, 内容密钥)；未请求或未命中返回 None。
fn quality_hit(variants: &[Value], quality: &str) -> Option<(String, Vec<u8>)> {
    if quality.is_empty() {
        return None;
    }
    let row = variants
        .iter()
        .find(|row| row.get("name").and_then(Value::as_str) == Some(quality))?;
    let url = row.get("url").and_then(Value::as_str).unwrap_or("");
    let key_hex = row.get("key_hex").and_then(Value::as_str).unwrap_or("");
    if url.is_empty() {
        return None;
    }
    let key = hex::decode(key_hex).ok()?;
    Some((url.to_string(), key))
}

/// 默认档（quality 为空）的自动选档：合并列表里最高的非 2K/4K 档，返回
/// (url, 内容密钥, 档名)。短剧主解析选流只在 shortplay 模型列表里挑，最高
/// 720P；1080P 只在 v5 的 fallback 列表里，默认档原先永远到不了。
/// 自动档改为取合并列表最高可用档（对齐 fqapp 下载偏好「自动 · 优先高清」），
/// 2K/4K 只保留给手动选择（4K VVC 软解耗电卡顿，不适合作自动默认）。
/// 列表为空（老形状上游不带档位）返回 None，保持主解析选流。
fn top_default_variant(variants: &[Value]) -> Option<(String, Vec<u8>, String)> {
    let row = variants.iter().find(|row| {
        !matches!(
            row.get("name").and_then(Value::as_str).unwrap_or(""),
            "2K" | "4K"
        )
    })?;
    let name = row.get("name").and_then(Value::as_str)?.to_string();
    let url = row.get("url").and_then(Value::as_str).unwrap_or("");
    if url.is_empty() {
        return None;
    }
    let key_hex = row.get("key_hex").and_then(Value::as_str).unwrap_or("");
    let key = hex::decode(key_hex).ok()?;
    Some((url.to_string(), key, name))
}

/// `quality` 参数白名单：仅字母数字、长度 <= 8（720P/1080P/2K/4K…），
/// 防止拼接进缓存文件名时注入路径分隔符。
fn sanitize_quality(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed.is_empty()
        && trimmed.len() <= 8
        && trimmed.chars().all(|c| c.is_ascii_alphanumeric())
    {
        trimmed.to_string()
    } else {
        String::new()
    }
}

fn v5_playback_body(video_id: &str) -> ApiResult<Vec<u8>> {
    let plain = serde_json::to_vec(&json!({
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
        "mixed_video_id_map": {
            "1004": [video_id],
        },
        "dr_scene": "player",
    }))
    .map_err(|e| ApiError::Internal(format!("marshal v5 playback body: {e}")))?;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder
        .write_all(&plain)
        .map_err(|e| ApiError::Internal(format!("gzip v5 playback body: {e}")))?;
    encoder
        .finish()
        .map_err(|e| ApiError::Internal(format!("gzip v5 playback body: {e}")))
}

/// What one playback-door attempt produced.
enum DoorOutcome {
    /// A non-empty 200 body.
    Body(Vec<u8>),
    /// `HTTP 200` with zero bytes: the door refused without saying why.
    Empty,
    /// Transport error, unusable status or a body without a usable model.
    Failed,
    /// The caller's deadline passed before the door answered.
    Deadline,
}

struct PlaybackAttempt {
    outcome: DoorOutcome,
    /// Identity that produced this outcome, when the transport revealed it.
    device_id: Option<String>,
}

/// The `video_tab` door's own query fields: the official app's snake_case
/// `GetVideoModelRequest` parameters.
fn video_tab_query(video_id: &str) -> Vec<(&str, &str)> {
    vec![
        ("video_id", video_id),
        ("video_id_type", "0"),
        ("device_level", "1"),
        ("need_all_video_definition", "1"),
        ("need_mp4_align", "0"),
        ("use_os_player", "0"),
        ("video_platform", "1024"),
        ("source", "0"),
        ("from_video_id", ""),
    ]
}

/// Hands a `video_tab` payload to the endpoint parser unchanged.
///
/// The parser already walks `data.video_model_data.<id>`, `data.<id>` and the
/// grouped shapes, so this only validates the envelope and re-wraps `data`.
/// A business code or a payload without `data` is a failed door, never an empty
/// one; the envelope line records keys, `data` type, code and message only, so a
/// shape drift stays diagnosable without logging a URL or a body.
fn video_tab_player_shape(raw: &[u8]) -> Option<Vec<u8>> {
    let root: Value = match serde_json::from_slice(raw) {
        Ok(root) => root,
        Err(_) => {
            log::warn!(
                "v5 trace event=tab result=failed reason=json body_len={}",
                raw.len()
            );
            return None;
        }
    };
    let code = root
        .get("code")
        .or_else(|| root.get("Code"))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if code != 0 {
        log::warn!("v5 trace event=tab result=failed reason=business code={code}");
        return None;
    }
    let Some(data) = root.get("data") else {
        log::warn!(
            "v5 trace event=tab result=failed reason=data envelope={}",
            body_envelope(&root)
        );
        return None;
    };
    match serde_json::to_vec(&json!({ "data": data })) {
        Ok(shaped) => Some(shaped),
        Err(_) => {
            log::warn!("v5 trace event=tab result=failed reason=remarshal");
            None
        }
    }
}

async fn attempt_playback_route(
    ctx: &Ctx,
    video_id: &str,
    body: &[u8],
    route: crate::upstream::playback_routes::Route,
    pin: Option<&str>,
    deadline: Instant,
) -> PlaybackAttempt {
    use crate::upstream::playback_routes::Door;
    match route.door {
        Door::V5Player => match tokio::time::timeout_at(
            deadline,
            ctx.up.v5_playback_with_device(V5_PLAYER_URL, body, pin),
        )
        .await
        {
            Err(_) => PlaybackAttempt {
                outcome: DoorOutcome::Deadline,
                device_id: None,
            },
            Ok(Ok((data, device))) => PlaybackAttempt {
                outcome: if data.is_empty() {
                    DoorOutcome::Empty
                } else {
                    DoorOutcome::Body(data)
                },
                device_id: Some(device.device_id),
            },
            Ok(Err(_)) => PlaybackAttempt {
                outcome: DoorOutcome::Failed,
                device_id: None,
            },
        },
        Door::VideoTab => {
            let base = format!("{}{}", route.host(), VIDEO_TAB_PLAYER_PATH);
            let extra = video_tab_query(video_id);
            match tokio::time::timeout_at(deadline, ctx.up.v5_get_with_device(&base, &extra, pin))
                .await
            {
                Err(_) => PlaybackAttempt {
                    outcome: DoorOutcome::Deadline,
                    device_id: None,
                },
                Ok(Ok((raw, device))) => {
                    let device_id = Some(device.device_id);
                    if raw.is_empty() {
                        return PlaybackAttempt {
                            outcome: DoorOutcome::Empty,
                            device_id,
                        };
                    }
                    match video_tab_player_shape(&raw) {
                        Some(shaped) => PlaybackAttempt {
                            outcome: DoorOutcome::Body(shaped),
                            device_id,
                        },
                        None => PlaybackAttempt {
                            outcome: DoorOutcome::Failed,
                            device_id,
                        },
                    }
                }
                Ok(Err(_)) => PlaybackAttempt {
                    outcome: DoorOutcome::Failed,
                    device_id: None,
                },
            }
        }
    }
}

/// One bounded, foreground-only identity rotation.
async fn rotate_playback_identity(
    ctx: &Ctx,
    deadline: Instant,
    failed: Option<&str>,
) -> Option<String> {
    let trace = crate::upstream::playback_trace::current();
    let (request_id, purpose) = trace
        .as_ref()
        .map_or((0, "other"), |trace| (trace.request_id, trace.purpose));
    match tokio::time::timeout_at(deadline, ctx.up.rotate_playback_identity(failed)).await {
        Ok(Ok(device)) => {
            log::info!("v5 trace request={request_id} purpose={purpose} event=rotate result=ok");
            Some(device.device_id)
        }
        Ok(Err(error)) => {
            log::warn!(
                "v5 trace request={request_id} purpose={purpose} event=rotate result=unavailable error={error}"
            );
            None
        }
        Err(_) => {
            log::warn!(
                "v5 trace request={request_id} purpose={purpose} event=rotate result=deadline"
            );
            None
        }
    }
}

/// Fetches the playback model through every playback door.
///
/// Ported from `N3urda/hongguoTV`'s `streamLadderWithCompatibility`: a single
/// v5 attempt, then the signed `video_tab` doors under the same identity, with
/// per-door cooldowns (30 s after an empty body, 5 s after any other failure)
/// and at most one identity rotation per request. Prefetch callers never probe
/// a cooling door and never rotate.
async fn fetch_playback_model(
    ctx: &Ctx,
    video_id: &str,
    deadline: Instant,
    purpose: &'static str,
) -> ApiResult<Vec<u8>> {
    use crate::upstream::playback_routes;

    let speculative = purpose == "prefetch";
    let request_id = crate::upstream::playback_trace::current().map_or(0, |trace| trace.request_id);
    let body = v5_playback_body(video_id)?;
    let mut pin: Option<String> = None;
    let mut all_empty = true;
    let mut attempts = 0usize;
    // One same-door re-probe per request: an empty body is usually a transient
    // per-request refusal, and the same door answers again a moment later.
    let mut reprobed = false;

    // A long empty streak rotates the identity before the next attempt, which is
    // what recovered live playback for the reference implementation.
    if playback_routes::with_state(|state| state.rotate_due(playback_routes::now_ms(), speculative))
        && crate::upstream::budget::remaining().is_none_or(|left| left > ROTATION_MIN_BUDGET)
    {
        pin = rotate_playback_identity(ctx, deadline, None).await;
        playback_routes::with_state(|state| {
            state.note_rotate(playback_routes::now_ms(), pin.is_some())
        });
    }

    for round in 0..2u8 {
        let now = playback_routes::now_ms();
        let plan = playback_routes::with_state(|state| state.plan(now, speculative));
        for route in plan {
            if attempts >= MAX_PLAYBACK_ATTEMPTS || Instant::now() >= deadline {
                break;
            }
            attempts += 1;
            let started = Instant::now();
            // Decided before the attempt: a door that is already parked is being
            // probed deliberately, not freshly refused, so it earns no re-probe.
            let route_parked = playback_routes::with_state(|state| state.parked(route, now));
            let mut attempt =
                attempt_playback_route(ctx, video_id, &body, route, pin.as_deref(), deadline).await;
            let can_reprobe = matches!(attempt.outcome, DoorOutcome::Empty)
                && !reprobed
                && !route_parked
                && !speculative
                && route.door == crate::upstream::playback_routes::Door::V5Player
                && attempts < MAX_PLAYBACK_ATTEMPTS
                && Instant::now() + REPROBE_MIN_BUDGET < deadline
                && crate::upstream::budget::remaining()
                    .is_none_or(|left| left > REPROBE_MIN_BUDGET);
            if can_reprobe && crate::upstream::budget::retry_pause(SAME_DOOR_REPROBE_DELAY).await {
                reprobed = true;
                attempts += 1;
                log::info!(
                    "v5 trace request={request_id} purpose={purpose} event=door route={} result=reprobe",
                    route.tag(),
                );
                attempt = attempt_playback_route(
                    ctx,
                    video_id,
                    &body,
                    route,
                    attempt.device_id.as_deref(),
                    deadline,
                )
                .await;
            }
            let elapsed = started.elapsed().as_millis();
            let outcome = match attempt.outcome {
                DoorOutcome::Body(raw) => {
                    log::info!(
                        "v5 trace request={request_id} purpose={purpose} event=door route={} result=ok elapsed_ms={elapsed} body_len={}",
                        route.tag(),
                        raw.len(),
                    );
                    playback_routes::with_state(|state| {
                        state.success(route, playback_routes::now_ms());
                        state.note_round(false);
                    });
                    return Ok(raw);
                }
                DoorOutcome::Empty => {
                    log::info!(
                        "v5 trace request={request_id} purpose={purpose} event=door route={} result=empty elapsed_ms={elapsed}",
                        route.tag(),
                    );
                    playback_routes::with_state(|state| state.failed(route, now, true));
                    DoorOutcome::Empty
                }
                DoorOutcome::Failed => {
                    log::warn!(
                        "v5 trace request={request_id} purpose={purpose} event=door route={} result=failed elapsed_ms={elapsed}",
                        route.tag(),
                    );
                    playback_routes::with_state(|state| state.failed(route, now, false));
                    DoorOutcome::Failed
                }
                DoorOutcome::Deadline => {
                    playback_routes::with_state(|state| state.failed(route, now, false));
                    DoorOutcome::Deadline
                }
            };
            if !matches!(outcome, DoorOutcome::Empty) {
                all_empty = false;
            }
            if let Some(device_id) = attempt.device_id {
                pin = Some(device_id);
            }
            if matches!(outcome, DoorOutcome::Deadline) {
                break;
            }
        }

        // A round that ended with every door parked may still buy one rotation,
        // but only while pacing allows it: the device pool is bounded.
        let parked =
            playback_routes::with_state(|state| state.exhausted(playback_routes::now_ms()));
        let now_after = playback_routes::now_ms();
        let paced =
            playback_routes::with_state(|state| state.rotation_paced(now_after, speculative));
        let due = playback_routes::with_state(|state| state.rotate_due(now_after, speculative));
        let can_rotate = round == 0
            && paced
            && (parked || due)
            && crate::upstream::budget::remaining().is_none_or(|left| left > ROTATION_MIN_BUDGET);
        if !can_rotate {
            break;
        }
        let rotated = rotate_playback_identity(ctx, deadline, pin.as_deref()).await;
        playback_routes::with_state(|state| {
            state.note_rotate(playback_routes::now_ms(), rotated.is_some())
        });
        match rotated {
            Some(device_id) => {
                pin = Some(device_id);
                continue;
            }
            None => break,
        }
    }

    playback_routes::with_state(|state| state.note_round(all_empty));
    let (empty_rounds, rotations) =
        playback_routes::with_state(|state| (state.empty_rounds(), state.rotations()));
    log::warn!(
        "v5 trace request={request_id} purpose={purpose} event=final result=empty attempts={attempts} empty_rounds={empty_rounds} rotations={rotations}"
    );
    Err(ApiError::Internal("视频取流失败,请稍后重试".to_string()))
}

async fn fetch_parsed_video_response(
    source: &str,
    video_id: &str,
    deadline: Instant,
    request: impl std::future::Future<Output = ApiResult<Vec<u8>>>,
) -> Option<ParsedVideoResponse> {
    let trace = crate::upstream::playback_trace::current();
    let request_id = trace.as_ref().map_or(0, |trace| trace.request_id);
    let purpose = trace.as_ref().map_or("other", |trace| trace.purpose);
    let raw = match tokio::time::timeout_at(deadline, request).await {
        Ok(Ok(raw)) => raw,
        Ok(Err(_)) => {
            log::warn!(
                "v5 trace request={request_id} purpose={purpose} source={source} event=fetch error=request"
            );
            return None;
        }
        Err(_) => {
            log::warn!(
                "v5 trace request={request_id} purpose={purpose} source={source} event=fetch error=deadline"
            );
            return None;
        }
    };
    if raw.is_empty() {
        log::warn!(
            "v5 trace request={request_id} purpose={purpose} source={source} event=fetch error=empty body_len=0"
        );
        return None;
    }
    let parsed = match ParsedVideoResponse::parse(&raw, Some(video_id)) {
        Ok(parsed) => parsed,
        Err(_) => {
            log::warn!(
                "v5 trace request={request_id} purpose={purpose} source={source} event=fetch error=json body_len={}",
                raw.len(),
            );
            return None;
        }
    };
    if upstream_response_is_failure(&parsed.root) {
        log::warn!(
            "v5 trace request={request_id} purpose={purpose} source={source} event=fetch error=business body_len={}",
            raw.len(),
        );
        return None;
    }
    if parsed.models.is_empty()
        && !parsed
            .root
            .get("data")
            .is_some_and(|data| has_compatible_playable_url(data, 0))
    {
        log::warn!(
            "v5 trace request={request_id} purpose={purpose} source={source} event=fetch error=no_model body_len={}",
            raw.len(),
        );
    }
    log::info!(
        "v5 trace request={request_id} purpose={purpose} source={source} event=fetch body_len={} model_count={}",
        raw.len(),
        parsed.models.len(),
    );
    Some(parsed)
}

fn upstream_response_is_failure(root: &Value) -> bool {
    if root.get("success").and_then(Value::as_bool) == Some(false)
        || ["code", "Code"]
            .iter()
            .any(|key| upstream_code_is_failure(root.get(*key)))
    {
        return true;
    }
    root.get("BaseResp")
        .and_then(Value::as_object)
        .is_some_and(|base| {
            ["code", "Code", "StatusCode"]
                .iter()
                .any(|key| upstream_code_is_failure(base.get(*key)))
        })
}

fn upstream_code_is_failure(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Number(code)) => code
            .as_i64()
            .map(|code| code != 0 && code != 200)
            .unwrap_or(false),
        Some(Value::String(code)) => code
            .trim()
            .parse::<i64>()
            .map(|code| code != 0 && code != 200)
            .unwrap_or(false),
        _ => false,
    }
}

fn legacy_raw_response_has_playable_url(parsed: &ParsedVideoResponse) -> bool {
    if !parsed.models.is_empty()
        || upstream_response_is_failure(&parsed.root)
        || parsed.root.get("data").is_some_and(|data| {
            data.get("1004").is_some_and(Value::is_object) || contains_known_video_shape(data, 0)
        })
    {
        return false;
    }
    parsed
        .root
        .get("data")
        .and_then(Value::as_object)
        .is_some_and(|data| {
            !data.is_empty()
                && parsed
                    .root
                    .get("data")
                    .is_some_and(|data| has_compatible_playable_url(data, 0))
        })
}

fn contains_known_video_shape(value: &Value, depth: usize) -> bool {
    if depth > 8 {
        return false;
    }
    match value {
        Value::Object(map) => {
            map.keys().any(|key| {
                matches!(
                    key.as_str(),
                    "video_model" | "video_info_list_map" | "video_list" | "play_info_list"
                )
            }) || map
                .values()
                .any(|nested| contains_known_video_shape(nested, depth + 1))
        }
        Value::Array(list) => list
            .iter()
            .any(|nested| contains_known_video_shape(nested, depth + 1)),
        _ => false,
    }
}

fn has_compatible_playable_url(value: &Value, depth: usize) -> bool {
    if depth > 8 {
        return false;
    }
    match value {
        Value::Object(map) => {
            if video_quality_score(map).is_some()
                && [
                    "video_url",
                    "play_url",
                    "main_url",
                    "backup_url",
                    "backup_url_1",
                ]
                .iter()
                .filter_map(|key| map.get(*key).and_then(Value::as_str))
                .any(playable_url_text)
            {
                return true;
            }
            map.iter().any(|(key, nested)| {
                key != "fallback_api" && has_compatible_playable_url(nested, depth + 1)
            })
        }
        Value::Array(list) => list
            .iter()
            .any(|nested| has_compatible_playable_url(nested, depth + 1)),
        _ => false,
    }
}

fn playable_url_text(url: &str) -> bool {
    let url = url.trim();
    url.starts_with("http://") || url.starts_with("https://") || url.starts_with("/src/")
}

/// Parses the multi_video_model response and extracts the best quality MP4 URL.
#[cfg(test)]
fn extract_video_url(raw: &[u8]) -> VideoSourceResolution {
    let Ok(parsed) = ParsedVideoResponse::parse(raw, None) else {
        return VideoSourceResolution::NotFound;
    };
    extract_parsed_video_url(&parsed)
}

fn extract_parsed_video_url(parsed: &ParsedVideoResponse) -> VideoSourceResolution {
    let Some(data) = parsed.root.get("data").and_then(Value::as_object) else {
        return VideoSourceResolution::NotFound;
    };

    let direct = extract_video_info_list_map_url(data, parsed.requested_video_id.as_deref());
    if direct.is_terminal() {
        return direct;
    }

    for model in &parsed.models {
        let source = extract_video_model_url(model);
        if source.is_terminal() {
            return source;
        }
    }
    VideoSourceResolution::NotFound
}

fn extract_video_info_list_map_url(
    data: &Map<String, Value>,
    requested_video_id: Option<&str>,
) -> VideoSourceResolution {
    let Some(video_map) = data.get("video_info_list_map").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };

    let video_list = match requested_video_id.filter(|id| !id.is_empty()) {
        Some(video_id) => video_map.get(video_id).and_then(Value::as_array),
        None => video_map
            .values()
            .find_map(|value| value.as_array().filter(|entries| !entries.is_empty())),
    };
    let Some(video_list) = video_list else {
        return VideoSourceResolution::NotFound;
    };
    if video_list.is_empty() {
        return VideoSourceResolution::NotFound;
    }
    let Some(video_info) = video_list[0].as_object() else {
        return VideoSourceResolution::NotFound;
    };
    let Some(play_info_list) = video_info.get("play_info_list").and_then(|v| v.as_array()) else {
        return VideoSourceResolution::NotFound;
    };
    extract_video_list_source(play_info_list)
}

/// The episode's `vertical` flag from a multi_video_model response.
///
/// Official models it as `com.bytedance.rpc.model.VideoInfo.vertical` (a
/// `short`) on each entry of `data.video_info_list_map`; the short-drama page
/// shows 「全屏观看」 only when `!saasVideoData.isVertical()`
/// (`wp3/o1.java:301-347`, data copied from `EpisodeInfo.vertical` in
/// `th3/e.java:95`). `None` means the response carried no field at all — the
/// caller then leaves the client's old behaviour alone.
fn episode_vertical_value(resp: &Value, requested_video_id: Option<&str>) -> Option<bool> {
    let data = resp.get("data")?.as_object()?;
    if let Some(video_id) = requested_video_id.filter(|id| !id.is_empty()) {
        if let Some(group) = data.get("1004").and_then(Value::as_object) {
            return group
                .get(video_id)
                .and_then(Value::as_object)
                .and_then(|entry| entry.get("vertical"))
                .and_then(vertical_flag);
        }
        if let Some(entry) = data.get(video_id).and_then(Value::as_object) {
            return entry.get("vertical").and_then(vertical_flag);
        }
        if let Some(entries) = data
            .get("video_info_list_map")
            .and_then(Value::as_object)
            .and_then(|map| map.get(video_id))
            .and_then(Value::as_array)
        {
            return entries
                .iter()
                .find_map(|entry| entry.get("vertical").and_then(vertical_flag));
        }
        return None;
    }
    if let Some(found) = data.get("vertical").and_then(vertical_flag) {
        return Some(found);
    }
    if let Some(video_map) = data.get("video_info_list_map").and_then(|v| v.as_object()) {
        for list in video_map.values() {
            let Some(arr) = list.as_array() else { continue };
            for entry in arr {
                if let Some(found) = entry.get("vertical").and_then(vertical_flag) {
                    return Some(found);
                }
            }
        }
    }
    // Shortplay shape: `data.<vid>` is the VideoInfo itself (beside its
    // `video_model` string), so the flag sits one level up from the quality
    // list rather than in `video_info_list_map`.
    for value in data.values() {
        if let Some(found) = value.get("vertical").and_then(vertical_flag) {
            return Some(found);
        }
    }
    None
}

#[cfg(test)]
fn episode_vertical(raw: &[u8]) -> Option<bool> {
    episode_vertical_value(&serde_json::from_slice::<Value>(raw).ok()?, None)
}

/// Lenient `vertical` decoding: upstream may send bool, 0/1, or "true"/"1".
fn vertical_flag(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) => number.as_i64().map(|v| v != 0),
        Value::String(text) => match text.trim().to_ascii_lowercase().as_str() {
            "true" | "1" => Some(true),
            "false" | "0" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn resolve_video_source_direct(parsed: &ParsedVideoResponse) -> VideoSourceResolution {
    let mut codec_rejected = false;
    for model in &parsed.models {
        match extract_shortplay_video_model_source(model) {
            VideoSourceResolution::Found(url, key) => {
                return VideoSourceResolution::Found(url, key);
            }
            VideoSourceResolution::CodecRejected => codec_rejected = true,
            VideoSourceResolution::NotFound => {}
        }
    }
    if parsed.models.iter().any(model_needs_fallback) {
        return if codec_rejected {
            VideoSourceResolution::CodecRejected
        } else {
            VideoSourceResolution::NotFound
        };
    }
    match extract_parsed_video_url(parsed) {
        VideoSourceResolution::Found(url, key) => VideoSourceResolution::Found(url, key),
        VideoSourceResolution::CodecRejected => VideoSourceResolution::CodecRejected,
        VideoSourceResolution::NotFound if codec_rejected => VideoSourceResolution::CodecRejected,
        VideoSourceResolution::NotFound => VideoSourceResolution::NotFound,
    }
}

async fn resolve_video_source_fallback_status(
    ctx: &Ctx,
    video_id: &str,
    source: &str,
    parsed: &ParsedVideoResponse,
    fallback_bodies: Option<&FallbackBodyCache>,
    deadline: Instant,
) -> FallbackResolution {
    let mut codec_rejected = false;
    let mut conclusive = true;
    let mut attempted_fallback = false;
    for model in &parsed.models {
        if !video_model_encrypted(model) {
            continue;
        }
        let fallback_url = fallback_api_url(model);
        if fallback_url.is_empty() {
            continue;
        }
        attempted_fallback = true;
        let cached = fallback_bodies.and_then(|cache| {
            let cache = cache.lock().unwrap_or_else(|error| error.into_inner());
            cache.get(&fallback_url).cloned()
        });
        if cached.is_none() && Instant::now() >= deadline {
            conclusive = false;
            break;
        }
        let fallback_result = match cached {
            Some(fallback_data) => Ok(fallback_data),
            None => fetch_fallback_video_info(ctx, video_id, source, &fallback_url, deadline)
                .await
                .map(Arc::new),
        };
        match fallback_result {
            Ok(fallback_data) => match extract_fallback_video_source(fallback_data.as_ref()) {
                VideoSourceResolution::Found(url, key) => {
                    if let Some(cache) = fallback_bodies {
                        let mut cache = cache.lock().unwrap_or_else(|error| error.into_inner());
                        cache
                            .entry(fallback_url)
                            .or_insert_with(|| fallback_data.clone());
                    }
                    return FallbackResolution::Found(url, key);
                }
                VideoSourceResolution::CodecRejected => codec_rejected = true,
                VideoSourceResolution::NotFound => conclusive = false,
            },
            Err(_) => conclusive = false,
        }
    }
    if !codec_rejected && !attempted_fallback {
        match extract_parsed_video_url(parsed) {
            VideoSourceResolution::Found(url, key) => {
                return FallbackResolution::Found(url, key);
            }
            VideoSourceResolution::CodecRejected => codec_rejected = true,
            VideoSourceResolution::NotFound => {}
        }
    }
    if !conclusive {
        FallbackResolution::Inconclusive
    } else if codec_rejected {
        FallbackResolution::CodecRejected
    } else {
        FallbackResolution::NotFound
    }
}

fn model_needs_fallback(model: &Map<String, Value>) -> bool {
    video_model_encrypted(model) && !fallback_api_url(model).is_empty()
}

async fn resolve_video_source_until(
    ctx: &Ctx,
    video_id: &str,
    source: &str,
    parsed: &ParsedVideoResponse,
    fallback_bodies: &FallbackBodyCache,
    deadline: Instant,
) -> VideoSourceResolution {
    let direct = resolve_video_source_direct(parsed);
    if matches!(direct, VideoSourceResolution::Found(_, _)) {
        return direct;
    }
    match resolve_video_source_fallback_status(
        ctx,
        video_id,
        source,
        parsed,
        Some(fallback_bodies),
        deadline,
    )
    .await
    {
        FallbackResolution::Found(url, key) => VideoSourceResolution::Found(url, key),
        FallbackResolution::CodecRejected => VideoSourceResolution::CodecRejected,
        FallbackResolution::Inconclusive => VideoSourceResolution::NotFound,
        FallbackResolution::NotFound => {
            if matches!(direct, VideoSourceResolution::CodecRejected) {
                VideoSourceResolution::CodecRejected
            } else {
                VideoSourceResolution::NotFound
            }
        }
    }
}

fn extract_shortplay_video_model_source(model: &Map<String, Value>) -> VideoSourceResolution {
    let key_seed = model
        .get("key_seed")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .and_then(|s| audio_b64_decode(s).ok());
    let encrypted_without_seed = video_model_encrypted(model) && key_seed.is_none();
    let resolve = |info: &Map<String, Value>| {
        if encrypted_without_seed {
            None
        } else {
            decrypt_variant_entry(info, key_seed.as_deref())
        }
    };
    match model.get("video_list") {
        Some(Value::Object(video_list)) => select_video_source(video_list.values(), resolve),
        Some(Value::Array(video_list)) => select_video_source(video_list.iter(), resolve),
        _ => VideoSourceResolution::NotFound,
    }
}

/// Decrypts one `video_list` entry into a playable (url, content key) pair.
/// Shared by the best-stream selector and the multi-variant listing so both
/// apply the same URL decryption and per-variant spade key derivation.
/// `key_seed` is the model-level decoded seed bytes shared by every variant.
fn decrypt_variant_entry(
    info: &Map<String, Value>,
    key_seed: Option<&[u8]>,
) -> Option<(String, Vec<u8>)> {
    let mut unresolved = None;
    for field in ["main_url", "backup_url", "backup_url_1", "play_url"] {
        let Some(raw_url) = info.get(field).and_then(Value::as_str) else {
            continue;
        };
        let mut raw_url = raw_url.trim().to_string();
        // `main_url` 有两种形态，不能一律先解一层 base64：
        //   1) base64 包着的明文地址（解码后以 `http` 开头）；
        //   2) spade 密文（base64 解出来以 a8 00 01 00 开头），要用 key_seed 解。
        // 旧实现无条件先解一层，把第 2 种毁成了不可再解的字节串——实测
        // 2026-10-12：fallback 列表（含 1080p 那一档）全部解不出来，面板因此
        // 拿到一个不是 URL 的垃圾串。这里只认第 1 种，第 2 种把**原始 base64**
        // 交给 decrypt_spade_url 自己再解一层。
        if !raw_url.is_empty() && !playable_url_text(&raw_url) {
            if let Ok(dec) = audio_b64_decode(&raw_url) {
                if dec.starts_with(b"http") {
                    raw_url = String::from_utf8_lossy(&dec).into_owned();
                }
            }
        }
        let url = if playable_url_text(&raw_url) {
            raw_url
        } else if let Some(key_seed) = key_seed {
            decrypt_spade_url(&raw_url, key_seed)
        } else {
            continue;
        };
        if playable_url_text(&url) {
            return Some((url, derive_variant_content_key(info)));
        }
        if !url.is_empty() && unresolved.is_none() {
            unresolved = Some(url);
        }
    }
    unresolved.map(|url| (url, derive_variant_content_key(info)))
}

/// The CENC key fixture may sit at the entry root or inside `encrypt_info`
/// (the HAR batch response uses the latter).
fn derive_variant_content_key(info: &Map<String, Value>) -> Vec<u8> {
    let spade_a = info
        .get("spade_a")
        .and_then(Value::as_str)
        .or_else(|| {
            info.get("encrypt_info")
                .and_then(Value::as_object)
                .and_then(|encrypt| encrypt.get("spade_a"))
                .and_then(Value::as_str)
        })
        .unwrap_or("");
    derive_spade_content_key(spade_a)
}

/// Display name for a variant height, mirroring the official mapping
/// (`zj3/b.java:76-99`): 360P/480P/540P/720P/1080P. The official panel maps
/// TwoK/FourK to an empty label, but the engine enum carries them
/// (`ttvideoengine/Resolution.java`), so taller variants use 2K/4K instead of
/// rendering a blank row.
fn variant_display_name(height: i64) -> String {
    if height <= 0 {
        return String::new();
    }
    if height <= 360 {
        "360P".to_string()
    } else if height <= 480 {
        "480P".to_string()
    } else if height <= 540 {
        "540P".to_string()
    } else if height <= 720 {
        "720P".to_string()
    } else if height <= 1080 {
        "1080P".to_string()
    } else if height <= 1440 {
        "2K".to_string()
    } else {
        "4K".to_string()
    }
}

/// Every playable variant in the v5 model, best-quality first
/// (official panel lists resolutions high→low,
/// `ShortSeriesMorePanelDialogV2$d$C0025d.a()` with `CollectionsKt.reversed`).
/// bytevc2/VVC tiers are included: the OHOS player (mpv / FFmpeg 8.0)
/// soft-decodes VVC, so no codec is filtered here.
///
/// The model's own `video_list` and `fallback_api` list are merged. Returns
/// `[]` when neither yields a playable variant; the client then hides the
/// quality row (official `oi3/k.P()` gate). The counters ride alongside so a
/// log line can say whether upstream sent one entry or sent five and our gates
/// kept one (`quality_count` alone has no denominator).
async fn extract_stream_variants(
    ctx: &Ctx,
    video_id: &str,
    parsed: &ParsedVideoResponse,
    fallback_bodies: &FallbackBodyCache,
    primary_url: &str,
    source_trace_id: u64,
    deadline: Instant,
) -> (Vec<Value>, VariantCounts) {
    let trace_started = Instant::now();
    let mut scored = Vec::new();
    let mut batches: Vec<VariantCounts> = Vec::new();
    let mut fallback_requests = Vec::new();
    let mut seen_fallback_urls = HashSet::new();
    let mut local_tiers = 0;
    let mut fallback_models = 0;
    for (model_id, model) in parsed.models.iter().enumerate() {
        // NOTE: 不用 video_model_encrypted() 做前置——它只认数组形状的
        // video_list;实测漫剧(series 7686494169098898456)的 video_list 是
        // object 且未标 encrypt,但每档照常带 spade_a/kid,选流门照常适用。
        let batch = variant_rows_scored_any(
            model.get("video_list"),
            model
                .get("key_seed")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .and_then(|s| audio_b64_decode(s).ok()),
        );
        local_tiers += playable_variant_tier_count(&batch.rows);
        batches.push(batch.counts);
        scored.extend(batch.rows);
        let fallback_url = fallback_api_url(model);
        if !fallback_url.is_empty() && seen_fallback_urls.insert(fallback_url) {
            fallback_models += 1;
            let fallback_cache = fallback_bodies.clone();
            fallback_requests.push(Box::pin(async move {
                let (batch, from_cache) =
                    fallback_variant_rows(ctx, video_id, "v5", model, &fallback_cache, deadline)
                        .await;
                (model_id, from_cache, batch)
            }));
        }
    }
    log::info!(
        "stream trace request={source_trace_id} source=v5 event=variants_body elapsed_ms={} playable_tiers={local_tiers} fallback_models={fallback_models}",
        trace_started.elapsed().as_millis(),
    );
    for (model_id, from_cache, batch) in futures::future::join_all(fallback_requests).await {
        log::info!(
            "stream trace request={source_trace_id} source=v5 model={model_id} event=variants_fallback elapsed_ms={} from_cache={from_cache} playable_tiers={}",
            trace_started.elapsed().as_millis(),
            playable_variant_tier_count(&batch.rows),
        );
        batches.push(batch.counts);
        scored.extend(batch.rows);
    }
    prioritize_primary_variant(&mut scored, primary_url);
    tally_variants(scored, &batches)
}

/// The model's `fallback_api` list as scored rows; empty when the model has no
/// fallback URL or it cannot be fetched before the metadata deadline.
async fn fallback_variant_rows(
    ctx: &Ctx,
    video_id: &str,
    source: &str,
    model: &Map<String, Value>,
    cache: &FallbackBodyCache,
    deadline: Instant,
) -> (VariantBatch, bool) {
    let fallback_url = fallback_api_url(model);
    if fallback_url.is_empty() {
        // 多数模型本来就没有这一条,不是异常。
        return (VariantBatch::default(), false);
    }
    let cached = {
        let cache = cache.lock().unwrap_or_else(|error| error.into_inner());
        cache.get(&fallback_url).cloned()
    };
    if let Some(fallback_data) = cached {
        return (fallback_rows_from_body(fallback_data.as_ref()), true);
    }
    if Instant::now() >= deadline {
        return (VariantBatch::default(), false);
    }
    let fallback_data =
        match fetch_fallback_video_info(ctx, video_id, source, &fallback_url, deadline).await {
            Ok(fallback_data) => fallback_data,
            Err(_) => {
                // 有地址却拉不到,是这一档列表整片消失的另一种静默路径。
                log::warn!(
                    "video {video_id}: {source} fallback_api fetch failed (quality tiers lost)"
                );
                return (VariantBatch::default(), false);
            }
        };
    let fallback_data = Arc::new(fallback_data);
    let batch = fallback_rows_from_body(fallback_data.as_ref());
    if playable_variant_tier_count(&batch.rows) > 0 {
        let mut cache = cache.lock().unwrap_or_else(|error| error.into_inner());
        cache
            .entry(fallback_url)
            .or_insert_with(|| fallback_data.clone());
    }
    (batch, false)
}

fn fallback_rows_from_body(fallback_data: &Map<String, Value>) -> VariantBatch {
    let list = fallback_data
        .get("video_info")
        .and_then(|v| v.get("data"))
        .and_then(|v| v.as_object());
    let key_seed = list
        .and_then(|d| d.get("key_seed"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .and_then(|s| audio_b64_decode(s).ok());
    let list = list.and_then(|d| d.get("video_list"));
    variant_rows_scored_any(list, key_seed)
}

/// Why an entry in an upstream variant list never became a playable tier.
/// Counts only: this rides in a log line that gets pasted around, so it must
/// never carry a url, a body, a signature, a key or a device identifier.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct VariantDropCounts {
    /// `video_quality_score` returned `None`; bytevc2 is the only such codec
    /// (`CRIT-004`: no decoder on the playback path).
    bytevc2: usize,
    /// `decrypt_variant_entry` found no playable url in any url field.
    no_url: usize,
    /// No usable width/height pair, so no quality name exists to show.
    no_meta: usize,
    /// Folded away by the merge: the resolution name or the url was already
    /// claimed by an earlier row.
    duplicate: usize,
}

impl VariantDropCounts {
    fn total(&self) -> usize {
        self.bytevc2 + self.no_url + self.no_meta + self.duplicate
    }

    /// Compact `bytevc2:3,no_url:0,no_meta:0,dup:1` for the trace line.
    fn summary(&self) -> String {
        format!(
            "bytevc2:{},no_url:{},no_meta:{},dup:{}",
            self.bytevc2, self.no_url, self.no_meta, self.duplicate
        )
    }
}

/// What the variant extraction did with a request's entries. `kept + dropped`
/// must equal `raw_entries`, which is the denominator `quality_count` lacked:
/// without it a log cannot tell "upstream sent one entry" from "upstream sent
/// five and our codec/metadata gates kept one".
///
/// For a single list batch `kept` is pre-merge; `tally_variants` recomputes it
/// for the whole request, so a batch's `kept` is informational only.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct VariantCounts {
    raw_entries: usize,
    kept: usize,
    dropped: VariantDropCounts,
}

/// One upstream `video_list` / `fallback_api` list: the rows it yielded plus
/// the counters that explain every entry it was handed.
#[derive(Debug, Default)]
struct VariantBatch {
    rows: Vec<(i64, Value)>,
    counts: VariantCounts,
}

/// Folds the per-list counters into one request-level tally and returns the
/// final rows. Pure: no network, no `Ctx`, so the async path only reports what
/// this returns and a test can drive the same code with fixtures.
fn tally_variants(
    scored: Vec<(i64, Value)>,
    batches: &[VariantCounts],
) -> (Vec<Value>, VariantCounts) {
    let mut counts = VariantCounts::default();
    for batch in batches {
        counts.raw_entries += batch.raw_entries;
        counts.dropped.bytevc2 += batch.dropped.bytevc2;
        counts.dropped.no_url += batch.dropped.no_url;
        counts.dropped.no_meta += batch.dropped.no_meta;
    }
    let (rows, duplicates) = merge_variant_rows_counted(scored);
    counts.dropped.duplicate = duplicates;
    counts.kept = rows.len();
    debug_assert_eq!(
        counts.kept + counts.dropped.total(),
        counts.raw_entries,
        "every upstream variant entry must be kept or explained: {counts:?}"
    );
    (rows, counts)
}

fn playable_variant_tier_count(rows: &[(i64, Value)]) -> usize {
    rows.iter()
        .filter(|(_, row)| {
            row.get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| !name.is_empty())
        })
        .count()
}

fn prioritize_primary_variant(scored: &mut Vec<(i64, Value)>, primary_url: &str) {
    let Some(index) = scored
        .iter()
        .position(|(_, row)| row.get("url").and_then(Value::as_str) == Some(primary_url))
    else {
        return;
    };
    let primary = scored.remove(index);
    scored.insert(0, primary);
}

/// Ranks rows best-first and keeps one row per resolution and URL. A row that
/// passes both checks claims both keys; rejected aliases must not consume a key
/// needed by a later real stream. The panel matches the current tier by URL, so
/// duplicate URLs would highlight multiple rows.
/// Test-facing face of the counted merge. The production path needs the
/// duplicate count, so only the tests keep the bare-row form.
#[cfg(test)]
fn merge_variant_rows(scored: Vec<(i64, Value)>) -> Vec<Value> {
    merge_variant_rows_counted(scored).0
}

/// Ranks rows best-first and keeps one row per resolution and URL. A row that
/// passes both checks claims both keys; rejected aliases must not consume a key
/// needed by a later real stream. The panel matches the current tier by URL, so
/// duplicate URLs would highlight multiple rows.
///
/// Also reports how many rows it folded away so the trace can account for every
/// entry. Every fold-away is counted as a duplicate, which keeps
/// `kept + dropped == raw_entries` exact: `variant_rows_from_entries` already
/// drops nameless and url-less entries, so a row that cannot claim both keys can
/// only be a repeat of an earlier one.
fn merge_variant_rows_counted(scored: Vec<(i64, Value)>) -> (Vec<Value>, usize) {
    let mut seen_names: HashSet<String> = HashSet::new();
    let mut seen_urls: HashSet<String> = HashSet::new();
    let mut out: Vec<(i64, Value)> = Vec::with_capacity(scored.len());
    let mut duplicates = 0;
    for (score, row) in scored {
        let Some(name) = row
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty())
        else {
            duplicates += 1;
            continue;
        };
        let Some(url) = row
            .get("url")
            .and_then(Value::as_str)
            .filter(|url| !url.is_empty())
        else {
            duplicates += 1;
            continue;
        };
        let name = name.to_string();
        let url = url.to_string();
        if seen_names.contains(&name) || seen_urls.contains(&url) {
            duplicates += 1;
            continue;
        }
        seen_names.insert(name);
        seen_urls.insert(url);
        out.push((score, row));
    }
    out.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    (
        out.into_iter().map(|(_, row)| row).collect(),
        duplicates,
    )
}

/// 把一份响应的**外壳**压成一行：顶层键名、`data` 的类型、`code`/`Code`、
/// `message`/`Message` 与 `BaseResp`。
///
/// 只记键名、类型、状态码与上游消息（截断），**不记 `data` 里的值**：值里可能是带签名的
/// URL 与令牌，而这份日志会被导出给人看。上游拒绝时只给 `110001` 这类通用码，把外壳与
/// 它给的原话留在日志里，是下一次"某一档无声消失"唯一能查的线索。
fn body_envelope(resp: &Value) -> String {
    let keys = resp
        .as_object()
        .map(|map| map.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let mut line = format!(
        "keys={keys:?} data={} code={} message={}",
        json_type_of(resp.get("data")),
        envelope_scalar(resp, &["code", "Code"]),
        envelope_scalar(resp, &["message", "Message"]),
    );
    if let Some(base) = resp.get("BaseResp") {
        line.push_str(&format!(" BaseResp={}", truncated(base, 240)));
    }
    line
}

/// 按候选键名取一个标量并渲染成短字符串，都取不到给 `-`。
fn envelope_scalar(resp: &Value, names: &[&str]) -> String {
    for name in names {
        match resp.get(*name) {
            Some(Value::String(text)) => return text.chars().take(120).collect(),
            Some(Value::Null) | None => continue,
            Some(other) => return other.to_string(),
        }
    }
    "-".to_string()
}

/// 把一段 JSON 压成一行并截断，避免错误包里的长文案把日志撑爆。
fn truncated(value: &Value, limit: usize) -> String {
    let text = value.to_string();
    if text.chars().count() <= limit {
        text
    } else {
        format!("{}…", text.chars().take(limit).collect::<String>())
    }
}

/// JSON 值的类型标签，`absent` 表示键根本不在。
fn json_type_of(value: Option<&Value>) -> &'static str {
    match value {
        None => "absent",
        Some(Value::Null) => "null",
        Some(Value::Bool(_)) => "bool",
        Some(Value::Number(_)) => "number",
        Some(Value::String(_)) => "string",
        Some(Value::Array(_)) => "array",
        Some(Value::Object(_)) => "object",
    }
}

/// Builds the variant rows from one `video_list` object, keeping the quality
/// score so callers can merge several upstream lists before ranking them.
#[cfg(test)]
fn variant_rows_scored(
    video_list: Option<&Map<String, Value>>,
    key_seed: Option<Vec<u8>>,
) -> Vec<(i64, Value)> {
    variant_rows_scored_with_counts(video_list, key_seed).rows
}

/// Counting face of [`variant_rows_scored`]: same rows, plus the counters that
/// explain every entry the list handed us.
#[cfg(test)]
fn variant_rows_scored_with_counts(
    video_list: Option<&Map<String, Value>>,
    key_seed: Option<Vec<u8>>,
) -> VariantBatch {
    let entries: Vec<(String, &Map<String, Value>)> = video_list
        .into_iter()
        .flat_map(|list| {
            list.iter()
                .filter_map(|(slot, value)| value.as_object().map(|info| (slot.clone(), info)))
        })
        .collect();
    variant_rows_from_entries(entries, key_seed)
}

fn variant_rows_scored_any(video_list: Option<&Value>, key_seed: Option<Vec<u8>>) -> VariantBatch {
    let entries: Vec<(String, &Map<String, Value>)> = match video_list {
        Some(Value::Object(list)) => list
            .iter()
            .filter_map(|(slot, value)| value.as_object().map(|info| (slot.clone(), info)))
            .collect(),
        Some(Value::Array(list)) => list
            .iter()
            .enumerate()
            .filter_map(|(index, value)| value.as_object().map(|info| (index.to_string(), info)))
            .collect(),
        _ => return VariantBatch::default(),
    };
    variant_rows_from_entries(entries, key_seed)
}

fn variant_rows_from_entries(
    entries: Vec<(String, &Map<String, Value>)>,
    key_seed: Option<Vec<u8>>,
) -> VariantBatch {
    let mut counts = VariantCounts {
        raw_entries: entries.len(),
        ..Default::default()
    };
    let mut rows: Vec<(i64, Value)> = Vec::with_capacity(entries.len());
    for (slot, info) in entries {
        let w = video_quality_metric(info, &["vwidth"]);
        let h = video_quality_metric(info, &["vheight"]);
        // 档位语义按**短边**:竖屏剧 1280×720 是 720P 而非 2K
        // (官方 Resolution 枚举同样以短边为准)。缺任一边时不能宣称画质。
        let short_edge = if w > 0 && h > 0 { w.min(h) } else { 0 };
        let name = variant_display_name(short_edge);
        // 编码门丢 bytevc2 是**预期行为**(`CRIT-004`:该编码没有解码器),不打点。
        let Some(score) = video_quality_score(info) else {
            counts.dropped.bytevc2 += 1;
            continue;
        };
        let Some((url, key)) = decrypt_variant_entry(info, key_seed.as_deref()) else {
            // 地址解不出来是静默丢**整档**的一类——`4e85437` 修过同款缺陷,且
            // 实测夹具的 `main_url` 形态一向比线上少,缺陷容易被盖住,所以留告警。
            log::warn!("variant {slot} dropped, url undecodable ({w}x{h} {name})");
            counts.dropped.no_url += 1;
            continue;
        };
        if short_edge == 0 {
            // 缺任一边就拼不出画质名,`merge_variant_rows` 只会把它当无名行丢掉。
            // 在入口就归类,`kept + dropped == raw_entries` 才对得上。
            counts.dropped.no_meta += 1;
            continue;
        }
        rows.push((
            score,
            json!({
                "name": name,
                "width": w,
                "height": h,
                "quality_height": short_edge,
                "codec": variant_codec_tag(info),
                "url": url,
                "key_hex": hex::encode(&key),
            }),
        ));
    }
    rows.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    counts.kept = rows.len();
    VariantBatch { rows, counts }
}

pub(crate) fn decode_video_model_str(s: &str) -> Option<Map<String, Value>> {
    if s.is_empty() {
        return None;
    }
    match serde_json::from_str::<Value>(s) {
        Ok(Value::Object(m)) => Some(m),
        _ => None,
    }
}

fn model_from_video_entry(entry: &Map<String, Value>) -> Option<Map<String, Value>> {
    entry
        .get("video_model")
        .and_then(decode_video_model)
        .or_else(|| entry.contains_key("video_list").then(|| entry.clone()))
}

/// Resolves the requested episode first, then falls back to the legacy
/// response shapes used by audio and older video endpoints.
fn video_models(
    data: &Map<String, Value>,
    requested_video_id: Option<&str>,
) -> Vec<Map<String, Value>> {
    if let Some(video_id) = requested_video_id.filter(|id| !id.is_empty()) {
        if let Some(group) = data.get("1004").and_then(Value::as_object) {
            return group
                .get(video_id)
                .and_then(Value::as_object)
                .and_then(model_from_video_entry)
                .into_iter()
                .collect();
        }
        if let Some(model) = data
            .get(video_id)
            .and_then(Value::as_object)
            .and_then(model_from_video_entry)
        {
            return vec![model];
        }
        for group in data.values().filter_map(Value::as_object) {
            if let Some(model) = group
                .get(video_id)
                .and_then(Value::as_object)
                .and_then(model_from_video_entry)
            {
                return vec![model];
            }
        }
        return data
            .get("video_model")
            .and_then(decode_video_model)
            .into_iter()
            .collect();
    }

    data.get("video_model")
        .and_then(decode_video_model)
        .into_iter()
        .chain(
            data.values()
                .filter_map(Value::as_object)
                .filter_map(model_from_video_entry),
        )
        .collect()
}

fn decode_video_model(v: &Value) -> Option<Map<String, Value>> {
    match v {
        Value::Object(m) => Some(m.clone()),
        Value::String(s) => decode_video_model_str(s),
        _ => None,
    }
}

fn extract_video_model_url(model: &Map<String, Value>) -> VideoSourceResolution {
    let Some(video_list) = model.get("video_list").and_then(|v| v.as_array()) else {
        return VideoSourceResolution::NotFound;
    };
    let has_quality_metadata = video_list.iter().any(|item| {
        item.as_object().is_some_and(|info| {
            ["vwidth", "vheight", "bitrate", "real_bitrate", "video_meta"]
                .iter()
                .any(|key| info.contains_key(*key))
        })
    });
    if has_quality_metadata {
        select_video_source(video_list.iter(), |info| decrypt_variant_entry(info, None))
    } else {
        // Legacy arrays without ranking metadata used their last entry.
        select_video_source(video_list.iter().rev(), |info| {
            decrypt_variant_entry(info, None)
        })
    }
}

fn extract_video_list_source(video_list: &[Value]) -> VideoSourceResolution {
    // Preserve the legacy last-entry preference when quality metadata is absent.
    select_video_source(video_list.iter().rev(), |info| {
        ["play_url", "main_url", "backup_url", "backup_url_1"]
            .iter()
            .filter_map(|key| info.get(*key).and_then(|v| v.as_str()))
            .find(|url| !url.is_empty())
            .map(|url| (url.to_string(), Vec::new()))
    })
}

fn video_model_encrypted(model: &Map<String, Value>) -> bool {
    let Some(video_list) = model.get("video_list").and_then(|v| v.as_array()) else {
        return false;
    };
    for item in video_list {
        let Some(info) = item.as_object() else {
            continue;
        };
        let Some(encrypt_info) = info.get("encrypt_info").and_then(|v| v.as_object()) else {
            continue;
        };
        if encrypt_info
            .get("encrypt")
            .and_then(|b| b.as_bool())
            .unwrap_or(false)
        {
            return true;
        }
    }
    false
}

fn fallback_api_url(model: &Map<String, Value>) -> String {
    let mut u = String::new();
    match model.get("fallback_api") {
        Some(Value::Object(f)) => {
            u = f
                .get("fallback_api")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
        }
        Some(Value::String(f)) => {
            if let Ok(Value::Object(m)) = serde_json::from_str::<Value>(f) {
                u = m
                    .get("fallback_api")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
            }
            if u.is_empty() {
                u = f.clone();
            }
        }
        _ => {}
    }
    u = u.replace("&stream_type=audio_encrypt", "");
    u = u.replace("?stream_type=audio_encrypt&", "?");
    u
}

async fn fetch_fallback_video_info(
    ctx: &Ctx,
    video_id: &str,
    source: &str,
    u: &str,
    deadline: Instant,
) -> Result<Map<String, Value>, FallbackFetchFailure> {
    // JSON response: same 64 MiB cap as every other API call.
    let raw = match tokio::time::timeout_at(
        deadline,
        unsigned_get(
            ctx,
            u,
            FALLBACK_USER_AGENT,
            crate::upstream::http::API_BODY_LIMIT_BYTES,
        ),
    )
    .await
    {
        Ok(Some(raw)) => raw,
        Ok(None) => {
            log::warn!("video {video_id}: {source} fallback_api request failed");
            return Err(FallbackFetchFailure::Retryable);
        }
        Err(_) => {
            log::warn!("video {video_id}: {source} fallback_api request deadline exceeded");
            return Err(FallbackFetchFailure::Retryable);
        }
    };
    if raw.is_empty() {
        log::warn!("video {video_id}: {source} fallback_api empty response body; body_len=0");
        return Err(FallbackFetchFailure::Retryable);
    }
    let root = match serde_json::from_slice::<Value>(&raw) {
        Ok(root) => root,
        Err(error) => {
            log::warn!(
                "video {video_id}: {source} fallback_api response unusable: {error}; body_len={}",
                raw.len()
            );
            return Err(FallbackFetchFailure::Retryable);
        }
    };
    if upstream_response_is_failure(&root) {
        log::warn!(
            "video {video_id}: {source} fallback_api business rejection: {}",
            body_envelope(&root)
        );
        return Err(FallbackFetchFailure::Permanent);
    }
    root.as_object()
        .cloned()
        .ok_or(FallbackFetchFailure::Retryable)
}

fn extract_fallback_video_source(root: &Map<String, Value>) -> VideoSourceResolution {
    let Some(video_info) = root.get("video_info").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };
    let Some(data_root) = video_info.get("data").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };
    let key_seed = data_root
        .get("key_seed")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .and_then(|s| audio_b64_decode(s).ok());
    let Some(video_list) = data_root.get("video_list").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };

    select_video_source(video_list.values(), |info| {
        decrypt_variant_entry(info, key_seed.as_deref())
    })
}

fn select_video_source<'a>(
    variants: impl Iterator<Item = &'a Value>,
    mut resolve: impl FnMut(&Map<String, Value>) -> Option<(String, Vec<u8>)>,
) -> VideoSourceResolution {
    let mut unresolved = VideoSourceResolution::NotFound;
    let mut infos: Vec<_> = variants
        .filter_map(|v| v.as_object())
        .filter_map(|info| match video_quality_score(info) {
            Some(score) => Some((score, info)),
            None => {
                unresolved = VideoSourceResolution::CodecRejected;
                None
            }
        })
        .collect();
    infos.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    for (_, info) in infos {
        if let Some((url, key)) = resolve(info) {
            return VideoSourceResolution::Found(url, key);
        }
    }
    unresolved
}

/// Newer models keep quality under `video_meta`; older models put it on the entry.
fn video_quality_metric(info: &Map<String, Value>, names: &[&str]) -> i64 {
    let meta = info.get("video_meta").and_then(Value::as_object);
    for source in [meta, Some(info)].into_iter().flatten() {
        for name in names {
            let value = source.get(*name).map(int64_from_any).unwrap_or(0);
            if value > 0 {
                return value;
            }
        }
    }
    0
}

/// 行内编码标签（entry 与 `video_meta` 的 `codec_type` 小写拼接）：上游把
/// 编码放在两处之一。stream 模式的 VVC 回退判定靠它在行级识别 bytevc2。
fn variant_codec_tag(info: &Map<String, Value>) -> String {
    let mut value = String::new();
    if let Some(v) = info.get("codec_type").and_then(Value::as_str) {
        value.push_str(&v.to_lowercase());
    }
    if let Some(meta) = info.get("video_meta").and_then(Value::as_object) {
        if let Some(v) = meta.get("codec_type").and_then(Value::as_str) {
            if !value.is_empty() {
                value.push(' ');
            }
            value.push_str(&v.to_lowercase());
        }
    }
    value
}

fn video_quality_score(info: &Map<String, Value>) -> Option<i64> {
    // 本项目播放内核是 mpv（FFmpeg 8.0，含原生 VVC 软解与 NEON 优化），
    // bytevc2/H.266 档位照常参选并进清晰度面板——上游 fqapp 面向的 Flutter
    // 播放器解不了 VVC 才设此门，实测 2026-11-08 漫剧 4K 集因全档 bytevc2
    // 被整集 500「该视频暂不支持播放」，故在此完全放行。
    // H.264 decodes everywhere, so it wins ties at equal quality.
    let codec = {
        let mut value = String::new();
        if let Some(v) = info.get("codec_type").and_then(|v| v.as_str()) {
            value.push_str(&v.to_lowercase());
        }
        if let Some(meta) = info.get("video_meta").and_then(|v| v.as_object()) {
            if let Some(v) = meta.get("codec_type").and_then(|v| v.as_str()) {
                value.push(' ');
                value.push_str(&v.to_lowercase());
            }
        }
        if let Some(v) = info.get("gear_des_key").and_then(|v| v.as_str()) {
            value.push(' ');
            value.push_str(&v.to_lowercase());
        }
        value
    };
    let w = video_quality_metric(info, &["vwidth"]);
    let h = video_quality_metric(info, &["vheight"]);
    let b = video_quality_metric(info, &["bitrate", "real_bitrate"]);
    let bonus = i64::from(codec.contains("h264") || codec.contains("avc1"));
    Some(w * 1_000_000_000 + h * 1_000_000 + b + bonus)
}

fn int64_from_any(v: &Value) -> i64 {
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i
            } else if let Some(u) = n.as_u64() {
                u as i64
            } else {
                n.as_f64().unwrap_or(0.0) as i64
            }
        }
        Value::String(s) => scan_i64(s),
        _ => 0,
    }
}

fn scan_i64(s: &str) -> i64 {
    let t = s.trim();
    let mut chars = t.chars().peekable();
    let mut sign = 1i64;
    match chars.peek() {
        Some('-') => {
            sign = -1;
            chars.next();
        }
        Some('+') => {
            chars.next();
        }
        _ => {}
    }
    let mut digits = String::new();
    while let Some(&c) = chars.peek() {
        if c.is_ascii_digit() {
            digits.push(c);
            chars.next();
        } else {
            break;
        }
    }
    if digits.is_empty() {
        0
    } else {
        digits.parse::<i64>().unwrap_or(0) * sign
    }
}

pub(crate) fn audio_b64_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let trimmed = s.trim();
    let pad = (4 - trimmed.len() % 4) % 4;
    let mut padded = trimmed.to_string();
    for _ in 0..pad {
        padded.push('=');
    }
    let cleaned: String = padded
        .chars()
        .filter(|c| *c != '\r' && *c != '\n')
        .collect();
    base64::engine::general_purpose::STANDARD.decode(cleaned)
}

pub(crate) fn decrypt_spade_url(value: &str, key_seed: &[u8]) -> String {
    if value.is_empty() {
        return String::new();
    }
    let Ok(raw) = audio_b64_decode(value) else {
        return value.to_string();
    };
    if raw.len() < 5 || raw[0] != 168 || raw[2] != 1 || raw[3] != 0 {
        return value.to_string();
    }
    let mut cipher_data = &raw[4..];
    let cipher_len = cipher_data.len() / 16 * 16;
    cipher_data = &cipher_data[..cipher_len];
    if cipher_data.is_empty() {
        return value.to_string();
    }

    let mut h1 = Sha512::new();
    h1.update(key_seed);
    let h1 = h1.finalize();
    let mut seed = Vec::with_capacity(64 + SPADE_CONSTANTS.len());
    seed.extend_from_slice(&h1);
    seed.extend_from_slice(&SPADE_CONSTANTS);
    let mut h2 = Sha512::new();
    h2.update(&seed);
    let h2 = h2.finalize();

    let out = crate::crypto::aes_cbc_decrypt(cipher_data, &h2[..16], &h2[16..32]);
    let out = crate::crypto::pkcs7_unpad(&out, 16);
    String::from_utf8_lossy(out)
        .trim_end_matches('\0')
        .to_string()
}

pub(crate) fn derive_spade_content_key(value: &str) -> Vec<u8> {
    if value.is_empty() {
        return Vec::new();
    }
    let Ok(raw) = audio_b64_decode(value) else {
        return Vec::new();
    };
    if raw.len() < 3 {
        return Vec::new();
    }
    let out_len = raw.len() as i64 - (raw[0] ^ raw[1] ^ raw[2]) as i64 + 0x2F;
    if out_len < 33 || out_len + 1 > raw.len() as i64 {
        return Vec::new();
    }
    let out_len = out_len as usize;
    let mut buf = raw[1..1 + out_len].to_vec();
    let src = buf.clone();
    let mut prev_a: u8 = 0x55;
    let mut prev_b: u8 = 0xF6;
    for (i, &cur) in src.iter().enumerate() {
        let keep;
        if i & 1 == 1 {
            keep = cur;
        } else {
            keep = prev_a;
            prev_a = prev_b;
            prev_b = cur;
        }
        buf[i] = (((prev_a ^ cur) as i32 - bit_count(i as u32) - 0x15) & 0xFF) as u8;
        prev_a = keep;
    }
    let key_hex = String::from_utf8_lossy(&buf[1..33]);
    match hex::decode(key_hex.as_bytes()) {
        Ok(key) if key.len() == 16 => key,
        _ => Vec::new(),
    }
}

fn bit_count(n: u32) -> i32 {
    n.count_ones() as i32
}

// ---------------------------------------------------------------------------
// video_detail.go
// ---------------------------------------------------------------------------

fn handle_video_detail<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let series_id = video_detail_series_id(params)?;
        let (platform, has_platform) = optional_int(&params.get_str("video_platform"));
        let body = video_detail_body(
            &series_id,
            int_default(&params.get_str("video_id_type"), 1),
            int_default(&params.get_str("source"), 5),
            platform,
            has_platform,
        )?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                raw_url: Some(video_detail_url()),
                body: Some(body),
                headers: video_detail_headers(),
                ..Default::default()
            })
            .await
    })
}

fn video_detail_series_id(params: &Params) -> ApiResult<String> {
    let series_id = {
        let primary = params.get_str("series_id");
        if primary.is_empty() {
            default_val(&params.get_str("video_id"), &params.get_str("item_ids"))
        } else {
            primary
        }
    };
    if series_id.is_empty() {
        return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
    }
    Ok(series_id)
}

fn optional_int(raw: &str) -> (i64, bool) {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return (0, false);
    }
    (int_default(trimmed, 0), true)
}

fn video_detail_body(
    series_id: &str,
    video_id_type: i64,
    source: i64,
    video_platform: i64,
    has_platform: bool,
) -> ApiResult<Vec<u8>> {
    let mut biz_param = Map::new();
    biz_param.insert("device_level".to_string(), json!(3));
    biz_param.insert("need_all_video_definition".to_string(), json!(true));
    biz_param.insert("need_mp4_align".to_string(), json!(false));
    biz_param.insert("source".to_string(), json!(source));
    biz_param.insert("use_os_player".to_string(), json!(false));
    biz_param.insert("video_id_type".to_string(), json!(video_id_type));
    if has_platform {
        biz_param.insert("video_platform".to_string(), json!(video_platform));
    }

    let mut out = Map::new();
    out.insert(
        "series_id".to_string(),
        Value::String(series_id.to_string()),
    );
    out.insert("biz_param".to_string(), Value::Object(biz_param));
    serde_json::to_vec(&out)
        .map_err(|e| ApiError::Internal(format!("marshal video detail body: {e}")))
}

// ---------------------------------------------------------------------------
// pseries.go
// ---------------------------------------------------------------------------

fn handle_pseries<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let pseries_id = params.get_str("pseries_id");
        if pseries_id.is_empty() {
            return Err(ApiError::BadRequest("缺少pseries_id参数".to_string()));
        }
        directory_reading(ctx, &pseries_id).await
    })
}

/// The directory payload shared by novel, drama and manga routes.
async fn directory_reading(ctx: &Ctx, book_id: &str) -> ApiResult<Value> {
    let u = format!(
        "{DIRECTORY_READING_URL}book_type=0&item_data_list_md5=&catalog_data_md5=&book_id={}{DIRECTORY_READING_QUERY_SUFFIX}",
        go_query_escape(book_id)
    );
    Upstream::new(ctx.up.clone())
        .json(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(u),
            headers: user_agent_headers(UA_ANDROID_BROWSER),
            ..Default::default()
        })
        .await
}

// ---------------------------------------------------------------------------
// HTTP + on-disk cache
// ---------------------------------------------------------------------------

/// Plain, unsigned GET with an explicit User-Agent. The body is rejected once
/// it exceeds `max_bytes`; callers pass the shared API cap for JSON responses
/// and the per-file video cap for whole-body download fallbacks.
async fn unsigned_get(ctx: &Ctx, url: &str, user_agent: &str, max_bytes: usize) -> Option<Vec<u8>> {
    let req = UpstreamRequest {
        method: Some("GET".to_string()),
        url: url.to_string(),
        body: None,
        headers: vec![("User-Agent".to_string(), user_agent.to_string())],
        no_sign: true,
        pin: None,
    };
    match ctx.up.do_request_capped(&req, max_bytes).await {
        Ok((body, _)) => Some(body),
        Err(_) => None,
    }
}

/// Hard per-file bound for a single downloaded / cached video. A short-drama
/// episode is far below this; the cap only stops a lying `Content-Length`
/// or an endless body from filling the disk or memory.
const MAX_VIDEO_DOWNLOAD_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Total timeout for one video download, matching the 15 s the shared
/// upstream transport applies to the old whole-body download.
const VIDEO_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(15);

/// A plain reqwest client for streaming video downloads. The shared upstream
/// transport (`upstream/http.rs`) only exposes a whole-body API, so the
/// download path keeps its own client; it sends the same unsigned GET with
/// the same User-Agent as `unsigned_get` (no signing, no device headers).
/// Rotates with the core's outbound policy so downloads never reuse an old proxy pool.
static STREAMING_CLIENT: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn streaming_client() -> Option<&'static reqwest::Client> {
    STREAMING_CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .timeout(VIDEO_DOWNLOAD_TIMEOUT)
                .build()
                .ok()
        })
        .as_ref()
}

/// Streams a video body to `part_path` chunk by chunk, never holding the
/// whole file in memory. Enforces the per-file cap from `Content-Length`
/// when present and from the running byte count while streaming. Leaves a
/// partial file behind on error; the caller deletes it.
async fn stream_download_to_file(
    url: &str,
    user_agent: &str,
    part_path: &Path,
) -> Result<u64, String> {
    stream_download_to_file_with_cap(url, user_agent, part_path, MAX_VIDEO_DOWNLOAD_BYTES).await
}

pub(crate) async fn stream_download_to_file_with_cap(
    url: &str,
    user_agent: &str,
    part_path: &Path,
    cap_bytes: u64,
) -> Result<u64, String> {
    let client = streaming_client().ok_or_else(|| "streaming client unavailable".to_string())?;
    let mut resp = client
        .get(url)
        .timeout(crate::upstream::budget::cap_timeout(VIDEO_DOWNLOAD_TIMEOUT))
        .header(reqwest::header::USER_AGENT, user_agent)
        .send()
        .await
        .map_err(|e| format!("download video: {e}"))?;
    // The whole-body path rejects anything but 200; keep that contract.
    if resp.status() != reqwest::StatusCode::OK {
        return Err(format!("download video: HTTP {}", resp.status()));
    }
    if let Some(len) = resp.content_length() {
        if len > cap_bytes {
            return Err(format!(
                "download video: content-length {len} exceeds cap {cap_bytes}"
            ));
        }
    }
    let mut file = tokio::fs::File::create(part_path)
        .await
        .map_err(|e| e.to_string())?;
    let mut total: u64 = 0;
    loop {
        match resp.chunk().await {
            Ok(Some(bytes)) => {
                total = total
                    .checked_add(bytes.len() as u64)
                    .ok_or_else(|| "download video: size overflow".to_string())?;
                if total > cap_bytes {
                    return Err(format!(
                        "download video: streamed {total} bytes exceeds cap {cap_bytes}"
                    ));
                }
                file.write_all(&bytes).await.map_err(|e| e.to_string())?;
            }
            Ok(None) => break,
            Err(e) => return Err(format!("download video: {e}")),
        }
    }
    file.flush().await.map_err(|e| e.to_string())?;
    Ok(total)
}

#[derive(Clone, Copy)]
pub(crate) enum DownloadKind {
    Video,
    /// ohos 听书：mpv 解不了 CENC 密文，音频与视频同样整段下载解密供流。
    /// CENC 音频是 ISO-BMFF 容器，缓存恒落 `.m4a`（不采纳 URL 后缀）。
    Audio,
}

impl DownloadKind {
    fn default_ext(self) -> &'static str {
        match self {
            DownloadKind::Video => ".mp4",
            DownloadKind::Audio => ".m4a",
        }
    }

    fn accepts_url_ext(self, candidate: &str) -> bool {
        match self {
            DownloadKind::Video => candidate == ".mp4" || candidate == ".m4s" || candidate == ".ts",
            // ohos 听书：Audio 只在 playinfo 命中加密流时下载（CENC 音频恒为
            // ISO-BMFF/.m4a 容器）。若采纳 URL 后缀（.m4s/.ts/.mp3），缓存文件
            // 会绕过 serve_src_file 的 mp4/m4a 解密门槛，密文被静态直出成电流
            // 音，故 Audio 一律不采纳 URL 后缀、统一落 .m4a。
            DownloadKind::Audio => {
                let _ = candidate;
                false
            }
        }
    }
}

/// Downloads the media file, saves it to src/ (CENC-decrypting when a key is
/// given), and returns the served path.
pub(crate) async fn download_and_save(
    ctx: &Ctx,
    cache_id: &str,
    media_url: &str,
    content_key: &[u8],
    kind: DownloadKind,
) -> Result<String, String> {
    let src_dir = if ctx.src_dir.is_empty() {
        "src".to_string()
    } else {
        ctx.src_dir.clone()
    };
    tokio::fs::create_dir_all(&src_dir)
        .await
        .map_err(|e| e.to_string())?;

    let mut ext = kind.default_ext().to_string();
    if let Some(idx) = media_url.rfind('.') {
        if idx > 0 {
            let candidate = media_url[idx..].to_lowercase();
            if candidate.len() <= 5 && kind.accepts_url_ext(&candidate) {
                ext = candidate;
            }
        }
    }

    let filename = format!("{cache_id}{ext}");
    let fp = Path::new(&src_dir).join(&filename);
    let guard = cache_entry_lock(&fp).lock_owned().await;

    if let Ok(info) = tokio::fs::metadata(&fp).await {
        if info.len() > 0 {
            // The cache keeps the downloaded bytes exactly as they arrived
            // (CENC-encrypted when the source is encrypted); the serve path
            // decrypts ranges on demand. All this path has to do is keep the
            // key sidecar in place — which also repairs a sidecar lost to a
            // crash between the download's rename and its sidecar write.
            // The moov/sidecar reads are blocking file I/O, so they run on
            // the blocking pool instead of an async worker.
            let cache_path = fp.clone();
            let cache_key = content_key.to_vec();
            tokio::task::spawn_blocking(move || {
                let _guard = guard;
                if !cache_key.is_empty()
                    && cache_cenc_state(&cache_path) == CacheCencState::Encrypted
                    && read_key_sidecar(&cache_path).as_deref() != Some(cache_key.as_slice())
                {
                    write_key_sidecar(&cache_path, &cache_key)?;
                }
                Ok::<(), String>(())
            })
            .await
            .map_err(|e| e.to_string())??;
            return Ok(format!("/src/{filename}"));
        }
    }

    // Cache hits do not queue behind unrelated downloads. Same-file callers
    // share the entry lock; different misses use a small global IO budget.
    let download_slot = VIDEO_DOWNLOADS.acquire().await.map_err(|e| e.to_string())?;
    let part_path = PathBuf::from(format!("{}.part", fp.display()));
    let _ = tokio::fs::remove_file(&part_path).await;

    if streaming_client().is_some() {
        // Streaming download: the body is written chunk by chunk and never
        // held whole in memory (P1-9). The entry lock keeps the cache file
        // and its key sidecar serialized for the same video.
        // The streaming client bypasses `UpstreamClient::do_request`, so
        // apply the mock-origin rewrite here; without it the download
        // would go to the real upstream instead of the mock server and
        // the codec-gate download tests would never see the request.
        let download_url = ctx.up.effective_url(media_url);
        if let Err(err) =
            stream_download_to_file(&download_url, UA_WINDOWS_BROWSER, &part_path).await
        {
            let _ = tokio::fs::remove_file(&part_path).await;
            return Err(err);
        }
    } else {
        // No TLS provider installed in this process (unit-test embedding
        // without the upstream transport): fall back to the shared
        // whole-body download instead of failing outright. The per-file
        // video cap still bounds the read.
        let data = unsigned_get(
            ctx,
            media_url,
            UA_WINDOWS_BROWSER,
            MAX_VIDEO_DOWNLOAD_BYTES as usize,
        )
        .await
        .ok_or_else(|| "download video: request failed".to_string())?;
        if data.len() as u64 > MAX_VIDEO_DOWNLOAD_BYTES {
            return Err(format!(
                "download video: {} bytes exceeds cap {MAX_VIDEO_DOWNLOAD_BYTES}",
                data.len()
            ));
        }
        tokio::fs::write(&part_path, &data)
            .await
            .map_err(|e| e.to_string())?;
    }

    // The bytes on disk stay exactly as downloaded — encrypted when the
    // source is CENC (P1-7). The key sidecar is what lets the serve path
    // decrypt ranges on demand, now and in later processes; if it cannot be
    // written the entry would be undecodable, so fail the download instead
    // of leaving a dead cache file behind.
    let key_path = fp.clone();
    let key = content_key.to_vec();
    tokio::task::spawn_blocking(move || {
        // Finalization owns both guards even if the request is cancelled.
        let _guard = guard;
        let _download_slot = download_slot;
        if let Err(err) = std::fs::rename(&part_path, &key_path) {
            let _ = std::fs::remove_file(&part_path);
            return Err(err.to_string());
        }
        if !key.is_empty() && cache_cenc_state(&key_path) == CacheCencState::Encrypted {
            if let Err(err) = write_key_sidecar(&key_path, &key) {
                let _ = std::fs::remove_file(&key_path);
                return Err(err);
            }
        }
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())??;
    // Eviction walks the whole cache directory, so it must not run on the
    // request path; schedule it instead of awaiting it.
    schedule_prune_src_cache(&src_dir, fp);

    Ok(format!("/src/{filename}"))
}

const MAX_VIDEO_CACHE_BYTES: i64 = 512 * 1024 * 1024;

struct CacheEntry {
    path: PathBuf,
    size: u64,
    when: std::time::SystemTime,
}

/// Serializes background prune passes: at most one runs at a time, and a
/// request that arrives while one is running does not queue another.
static PRUNE_LOCK: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));

/// Requests a cache-eviction pass off the request path.
///
/// The pass walks the whole `src_dir` and stats every candidate, so it must
/// not run on an async worker or hold up the response; it is spawned and
/// never awaited. At most one pass runs at a time; a request that arrives
/// while a pass is in flight is skipped (the next download schedules again).
pub(crate) fn schedule_prune_src_cache(src_dir: &str, keep: PathBuf) {
    schedule_prune_src_cache_with_budget(src_dir, keep, MAX_VIDEO_CACHE_BYTES);
}

fn schedule_prune_src_cache_with_budget(src_dir: &str, keep: PathBuf, max_bytes: i64) {
    let src_dir = src_dir.to_string();
    tokio::spawn(async move {
        let Ok(_guard) = PRUNE_LOCK.try_lock() else {
            return;
        };
        let outcome = tokio::task::spawn_blocking(move || {
            prune_src_cache_with_budget(&src_dir, &keep, max_bytes)
        })
        .await;
        if let Err(err) = outcome {
            log::warn!("cache prune task failed: {err}");
        }
    });
}

/// Removes the oldest completed cached files once the cache exceeds the
/// limit. Videos and manga images share `src_dir`, so both count toward the
/// same budget: manga images are the content-addressed `img_<sha256>.<ext>`
/// files, and they are evictable like videos (re-downloadable on demand).
/// In-flight downloads (`.part` / `.tmp`) are never counted or deleted.
fn prune_src_cache_with_budget(src_dir: &str, keep: &Path, max_bytes: i64) {
    let Ok(entries) = std::fs::read_dir(src_dir) else {
        return;
    };
    let entries: Vec<(String, PathBuf)> = entries
        .flatten()
        .map(|entry| {
            (
                entry.file_name().to_string_lossy().into_owned(),
                entry.path(),
            )
        })
        .collect();
    let names: HashSet<&str> = entries.iter().map(|(name, _)| name.as_str()).collect();
    // Key sidecars (`<video>.key`, P1-7) belong to their video entry: one
    // whose video (or in-flight `.part`) is gone can never serve again.
    for (name, path) in &entries {
        if let Some(stem) = name.strip_suffix(".key") {
            if !names.contains(stem) && !names.contains(format!("{stem}.part").as_str()) {
                let video = Path::new(src_dir).join(stem);
                let Ok(_guard) = cache_entry_lock(&video).try_lock_owned() else {
                    continue;
                };
                // The directory snapshot may predate another download's commit.
                if !video.exists() && !Path::new(src_dir).join(format!("{stem}.part")).exists() {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }
    let mut items: Vec<CacheEntry> = Vec::new();
    let mut total: i64 = 0;
    for entry in entries.iter().map(|(name, _)| name) {
        let name = entry.as_str();
        if name.ends_with(".part") || name.ends_with(".tmp") {
            continue;
        }
        let ext = Path::new(name)
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let is_video = ext == "mp4" || ext == "m4s" || ext == "ts";
        // Manga images are written as `img_<sha256>.<jpg|png|gif|webp>`; the
        // `img_` prefix keeps unrelated files out of the eviction set.
        let is_manga_image = name.starts_with("img_")
            && (ext == "jpg" || ext == "png" || ext == "gif" || ext == "webp");
        if !is_video && !is_manga_image {
            continue;
        }
        let path = Path::new(src_dir).join(name);
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        if !meta.is_file() || meta.len() == 0 {
            continue;
        }
        let when = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        total += meta.len() as i64;
        items.push(CacheEntry {
            path,
            size: meta.len(),
            when,
        });
    }
    if total <= max_bytes {
        return;
    }
    items.sort_by_key(|a| a.when);
    for item in items {
        if total <= max_bytes {
            continue;
        }
        if item.path.as_path() == keep {
            continue;
        }
        let Ok(_guard) = cache_entry_lock(&item.path).try_lock_owned() else {
            continue;
        };
        if std::fs::remove_file(&item.path).is_ok() {
            // A video's key sidecar (P1-7) is part of the entry, not a
            // separate cache citizen.
            let _ = std::fs::remove_file(key_sidecar_path(&item.path));
            total -= item.size as i64;
        }
    }
}

// ---------------------------------------------------------------------------
// Encrypted on-disk video cache (P1-7)
//
// Downloaded bytes are stored exactly as they arrived — CENC-encrypted when
// the source is encrypted — and the decrypted view exists only in memory, one
// served range at a time. The per-video content key (derived from `spade_a`
// during source resolution, never persisted before) travels in a sidecar
// file next to the cache entry: `<name>.mp4.key`, hex encoded. The cache
// directory is app-private; the sidecar is what lets a later process serve a
// cached file without re-resolving the source, and `download_and_save`'s
// cache-hit path rewrites it if it ever goes missing.
// ---------------------------------------------------------------------------

/// Upper bound for the `moov` box read at serve/migration time, matching the
/// native player core's SP_MAX_MOOV_BYTES. A larger moov is treated as
/// undetectable rather than read without bound.
const MAX_MOOV_BYTES: u64 = 16 * 1024 * 1024;

fn key_sidecar_path(fp: &Path) -> PathBuf {
    PathBuf::from(format!("{}.key", fp.display()))
}

fn write_key_sidecar(fp: &Path, content_key: &[u8]) -> Result<(), String> {
    let sidecar = key_sidecar_path(fp);
    let tmp = PathBuf::from(format!("{}.tmp", sidecar.display()));
    std::fs::write(&tmp, hex::encode(content_key)).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &sidecar).map_err(|e| e.to_string())
}

fn read_key_sidecar(fp: &Path) -> Option<Vec<u8>> {
    let raw = std::fs::read_to_string(key_sidecar_path(fp)).ok()?;
    let key = hex::decode(raw.trim()).ok()?;
    if key.len() == 16 || key.len() == 24 || key.len() == 32 {
        Some(key)
    } else {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CacheCencState {
    /// The file's `moov` carries an encrypted sample entry (encv/enca).
    Encrypted,
    /// The file parses as MP4 and no track is encrypted: either an
    /// originally-clear download or a plaintext file left by the pre-P1-7
    /// in-place decrypt. The two are indistinguishable from the bytes.
    Clear,
    /// No readable `moov` (truncated, not MP4, moov over the cap): nothing
    /// can be concluded, so callers leave the file alone.
    Unknown,
}

/// Locates the top-level `moov` box by walking box headers only.
fn locate_moov(file: &mut std::fs::File, len: u64) -> Option<(u64, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut off = 0u64;
    while off + 8 <= len {
        file.seek(SeekFrom::Start(off)).ok()?;
        let mut hdr = [0u8; 16];
        file.read_exact(&mut hdr[..8]).ok()?;
        let size32 = u32::from_be_bytes(hdr[..4].try_into().ok()?);
        let (size, header) = if size32 == 1 {
            file.read_exact(&mut hdr[8..16]).ok()?;
            (u64::from_be_bytes(hdr[8..16].try_into().ok()?), 16u64)
        } else if size32 == 0 {
            (len - off, 8u64)
        } else {
            (size32 as u64, 8u64)
        };
        if size < header || off + size > len {
            return None;
        }
        if &hdr[4..8] == b"moov" {
            return Some((off, size));
        }
        off += size;
    }
    None
}

/// Reads exactly the `moov` box bytes and its file offset.
fn read_moov_bytes(path: &Path) -> Option<(u64, Vec<u8>)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let (off, size) = locate_moov(&mut file, len)?;
    if size > MAX_MOOV_BYTES {
        return None;
    }
    file.seek(SeekFrom::Start(off)).ok()?;
    let mut buf = vec![0u8; size as usize];
    file.read_exact(&mut buf).ok()?;
    Some((off, buf))
}

fn cache_cenc_state(path: &Path) -> CacheCencState {
    match read_moov_bytes(path) {
        Some((_, moov)) => {
            if mp4_needs_cenc_decrypt(&moov) {
                CacheCencState::Encrypted
            } else {
                CacheCencState::Clear
            }
        }
        None => CacheCencState::Unknown,
    }
}

/// Per-file CENC index cache: range requests from a player arrive in
/// bursts, and re-reading the moov for each one would be wasteful. Keyed by
/// path and invalidated by (length, mtime), which a re-download changes.
type CencIndexCache =
    std::sync::Mutex<HashMap<PathBuf, (u64, std::time::SystemTime, Arc<CencIndex>)>>;

static CENC_INDEX_CACHE: OnceLock<CencIndexCache> = OnceLock::new();

fn cenc_index_for_file(path: &Path) -> Result<Option<Arc<CencIndex>>, String> {
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    let len = meta.len();
    let modified = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
    let cache = CENC_INDEX_CACHE.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((cached_len, cached_mtime, index)) = guard.get(path) {
            if *cached_len == len && *cached_mtime == modified {
                return Ok(Some(index.clone()));
            }
        }
    }
    let Some((moov_off, moov)) = read_moov_bytes(path) else {
        return Ok(None);
    };
    let Some(index) = build_cenc_index(&moov, moov_off, len)? else {
        return Ok(None);
    };
    let index = Arc::new(index);
    if let Ok(mut guard) = cache.lock() {
        guard.insert(path.to_path_buf(), (len, modified, index.clone()));
    }
    Ok(Some(index))
}

/// Serves one `/src/*` request for a CENC-encrypted cache file, decrypting
/// only the requested range. Returns `None` for anything that is not an
/// encrypted MP4 with a sidecar key question to answer — the caller falls
/// back to the plain static file path (clear MP4s, manga images, ...).
pub(crate) async fn serve_src_file(
    src_dir: &str,
    rest: &str,
    req: &crate::dispatch::Request,
) -> Option<crate::dispatch::Response> {
    use crate::dispatch::{Response, ResponseBody};
    let root = Path::new(src_dir);
    let path = crate::static_files::resolve_confined(root, rest).await?;
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    // CENC-encrypted cache entries are ISO-BMFF files: video episodes land
    // here as `.mp4` and online-TTS audio chapters as `.m4a` (see
    // `DownloadKind::Audio`). Both carry `enca`/`encv` sample entries and
    // share the same range-decrypt path, so either extension qualifies;
    // everything else (manga images, `.ts`, ...) falls through to plain
    // static serving.
    if ext != "mp4" && ext != "m4a" {
        return None;
    }
    if cache_cenc_state(&path) != CacheCencState::Encrypted {
        return None;
    }
    // The file is encrypted: serving the raw bytes would hand the player
    // undecodable data with a success status, so a missing key is an
    // explicit error instead. Re-resolving the source rewrites the sidecar
    // through the cache-hit path in `download_and_save`.
    let Some(key) = read_key_sidecar(&path) else {
        return Some(Response::json(
            503,
            &serde_json::json!({
                "success": false,
                "error": "cached video key missing; re-resolve the source",
            }),
        ));
    };
    let index = match cenc_index_for_file(&path) {
        Ok(Some(index)) => index,
        Ok(None) => return None,
        Err(err) => {
            return Some(Response::json(
                500,
                &serde_json::json!({ "success": false, "error": err }),
            ));
        }
    };
    let meta = std::fs::metadata(&path).ok()?;
    let total = meta.len();
    let content_type = crate::dispatch::mime_for(&path).to_string();
    let range = crate::static_files::parse_range(req.header("range"), total);
    let is_head = req.method.eq_ignore_ascii_case("HEAD");
    let (status, offset, length, extra) = match range {
        crate::static_files::ByteRange::Full => (200u16, 0u64, total, Vec::new()),
        crate::static_files::ByteRange::Partial { start, end } => (
            206u16,
            start,
            end - start + 1,
            vec![(
                "content-range".to_string(),
                format!("bytes {start}-{end}/{total}"),
            )],
        ),
        crate::static_files::ByteRange::Unsatisfiable => {
            return Some(Response {
                status: 416,
                content_type,
                headers: vec![
                    ("accept-ranges".to_string(), "bytes".to_string()),
                    ("content-range".to_string(), format!("bytes */{total}")),
                    ("content-length".to_string(), "0".to_string()),
                ],
                body: ResponseBody::Bytes(Vec::new()),
            });
        }
    };
    let mut headers = vec![
        ("accept-ranges".to_string(), "bytes".to_string()),
        ("content-length".to_string(), length.to_string()),
    ];
    headers.extend(extra);
    let body = if is_head {
        ResponseBody::Bytes(Vec::new())
    } else {
        ResponseBody::FileDecrypted {
            path,
            offset,
            length,
            total,
            index,
            key,
        }
    };
    Some(Response {
        status,
        content_type,
        headers,
        body,
    })
}

// ---------------------------------------------------------------------------
// One-time migration: plaintext video cache cleanup (P1-7 follow-up)
//
// Versions before the streaming-decrypt change decrypted cached videos in
// place, so an upgraded install can hold plaintext MP4s in the cache
// directory. The user-facing decision (2026-10-25) is to remove them
// automatically on the first launch of the new version. The sweep is scoped
// to the Rust cache directory (`<runtime>/src`) and to completed `.mp4` /
// `.m4s` entries whose moov proves them clear; the user's offline downloads
// live in a different directory (`offline-video`, managed by the Dart
// download store) and are never touched. Best-effort throughout: failures
// are logged and retried on the next launch via the pending list, and
// nothing here may fail core init.
// ---------------------------------------------------------------------------

const CACHE_FORMAT_MARKER: &str = ".cachefmt-v2";
const CACHE_FORMAT_PENDING: &str = ".cachefmt-v2-pending";

pub(crate) fn migrate_plaintext_video_cache(src_dir: &Path) {
    let marker = src_dir.join(CACHE_FORMAT_MARKER);
    let pending_path = src_dir.join(CACHE_FORMAT_PENDING);
    let first_run = !marker.exists();

    let mut targets: Vec<PathBuf> = Vec::new();
    if first_run {
        let entries = match std::fs::read_dir(src_dir) {
            Ok(entries) => entries,
            Err(err) => {
                log::warn!("p17 migration: cannot scan {}: {err}", src_dir.display());
                return;
            }
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(".part") || name.ends_with(".tmp") {
                continue;
            }
            let ext = Path::new(&name)
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            // `.ts` entries never passed through the MP4 CENC decrypt, so
            // they are out of scope even though they are clear by nature.
            if ext != "mp4" && ext != "m4s" {
                continue;
            }
            if entry.metadata().map(|m| m.is_file()).unwrap_or(false) {
                targets.push(entry.path());
            }
        }
    } else if let Ok(list) = std::fs::read_to_string(&pending_path) {
        // Later launches only retry the names a previous run failed to
        // remove; each one is re-tested below, so a name since reused by an
        // encrypted cache entry is kept.
        targets = list
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(|line| src_dir.join(line))
            .collect();
    } else {
        return;
    }

    let mut failed: Vec<String> = Vec::new();
    let mut removed = 0usize;
    for path in &targets {
        // Only a file that provably parses as a clear MP4 is removed. An
        // encrypted entry is the new cache format and stays; an unreadable
        // one cannot be told apart from user data and also stays (the
        // regular LRU prune ages it out).
        if cache_cenc_state(path) != CacheCencState::Clear {
            continue;
        }
        match std::fs::remove_file(path) {
            Ok(()) => {
                removed += 1;
                let _ = std::fs::remove_file(key_sidecar_path(path));
            }
            Err(err) => {
                log::warn!(
                    "p17 migration: cannot remove plaintext cache {}: {err}",
                    path.display()
                );
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    failed.push(name.to_string());
                }
            }
        }
    }
    if removed > 0 {
        log::info!("p17 migration: removed {removed} plaintext video cache file(s)");
    }
    if first_run {
        let _ = std::fs::write(&marker, b"2\n");
    }
    if failed.is_empty() {
        let _ = std::fs::remove_file(&pending_path);
    } else {
        let _ = std::fs::write(&pending_path, failed.join("\n"));
    }
}

// ---------------------------------------------------------------------------
// MP4 CENC decryption
// ---------------------------------------------------------------------------

fn u16_be(data: &[u8], off: usize) -> u16 {
    if off + 2 > data.len() {
        return 0;
    }
    u16::from_be_bytes([data[off], data[off + 1]])
}

fn u32_be(data: &[u8], off: usize) -> u32 {
    if off + 4 > data.len() {
        return 0;
    }
    u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
}

fn u64_be(data: &[u8], off: usize) -> u64 {
    if off + 8 > data.len() {
        return 0;
    }
    let mut b = [0u8; 8];
    b.copy_from_slice(&data[off..off + 8]);
    u64::from_be_bytes(b)
}

#[derive(Clone, Copy)]
struct Mp4Box {
    off: usize,
    size: usize,
    header: usize,
    typ: [u8; 4],
}

fn iter_boxes(data: &[u8], start: usize, end: usize) -> Vec<Mp4Box> {
    let end = end.min(data.len());
    let mut boxes = Vec::new();
    let mut off = start;
    while off + 8 <= end {
        let mut size = u32_be(data, off) as usize;
        let mut typ = [0u8; 4];
        typ.copy_from_slice(&data[off + 4..off + 8]);
        let mut header = 8usize;
        if size == 1 {
            if off + 16 > end {
                break;
            }
            let size64 = u64_be(data, off + 8);
            if size64 > isize::MAX as u64 {
                break;
            }
            size = size64 as usize;
            header = 16;
        } else if size == 0 {
            size = end - off;
        }
        if size < header || off + size > end {
            break;
        }
        boxes.push(Mp4Box {
            off,
            size,
            header,
            typ,
        });
        off += size;
    }
    boxes
}

fn box_children_start(typ: &[u8; 4], off: usize, header: usize) -> Option<usize> {
    match typ {
        b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl" | b"dinf" | b"edts" | b"udta" => {
            Some(off + header)
        }
        b"stsd" => Some(off + header + 8),
        b"encv" | b"avc1" | b"hvc1" | b"hev1" => Some(off + header + 78),
        b"enca" | b"mp4a" => Some(off + header + 28),
        _ => None,
    }
}

fn collect_track_boxes(data: &[u8], start: usize, end: usize) -> HashMap<[u8; 4], Vec<Mp4Box>> {
    let mut found: HashMap<[u8; 4], Vec<Mp4Box>> = HashMap::new();
    walk_boxes(data, start, end, &mut found);
    found
}

fn walk_boxes(
    data: &[u8],
    child_start: usize,
    child_end: usize,
    found: &mut HashMap<[u8; 4], Vec<Mp4Box>>,
) {
    for b in iter_boxes(data, child_start, child_end) {
        found.entry(b.typ).or_default().push(b);
        if let Some(nested_start) = box_children_start(&b.typ, b.off, b.header) {
            if nested_start < b.off + b.size {
                walk_boxes(data, nested_start, b.off + b.size, found);
            }
        }
    }
}

fn mp4_track_boxes(data: &[u8]) -> Vec<HashMap<[u8; 4], Vec<Mp4Box>>> {
    let mut tracks = Vec::new();
    for b in iter_boxes(data, 0, data.len()) {
        if b.typ != *b"moov" {
            continue;
        }
        for child in iter_boxes(data, b.off + b.header, b.off + b.size) {
            if child.typ == *b"trak" {
                tracks.push(collect_track_boxes(
                    data,
                    child.off + child.header,
                    child.off + child.size,
                ));
            }
        }
    }
    tracks
}

fn mp4_needs_cenc_decrypt(data: &[u8]) -> bool {
    for boxes in mp4_track_boxes(data) {
        if boxes.get(b"encv").is_some_and(|v| !v.is_empty())
            || boxes.get(b"enca").is_some_and(|v| !v.is_empty())
        {
            return true;
        }
    }
    false
}

// ---------------------------------------------------------------------------
// CENC index: everything needed to turn a byte range of the encrypted file
// into the same range of the decrypted view, without touching the rest of
// the file. Built from the `moov` box alone (sample data is never read), so
// the serve path can decrypt on demand per Range request (P1-7) — the same
// shape the native player core uses for offline files (sp_mp4_index).
// ---------------------------------------------------------------------------

/// A length-preserving header rewrite (sample-entry type, `sinf` -> `free`),
/// expressed as replacement bytes at an absolute file offset.
#[derive(Debug, Clone)]
pub struct CencPatch {
    pub off: u64,
    pub bytes: Vec<u8>,
}

/// One encrypted byte run inside a sample. `base` is the number of encrypted
/// bytes preceding this run *within the same sample*: the CENC CTR keystream
/// is continuous across a sample's encrypted runs (clear subsample parts do
/// not consume keystream), so a run's keystream starts at `counter0` advanced
/// by `base` bytes.
#[derive(Debug, Clone)]
pub struct CencEncRange {
    pub off: u64,
    pub size: u64,
    pub counter0: [u8; 16],
    pub base: u64,
}

#[derive(Debug, Clone, Default)]
pub struct CencIndex {
    /// Sorted by `off`.
    pub patches: Vec<CencPatch>,
    /// Sorted by `off`; ranges never overlap in a well-formed file.
    pub ranges: Vec<CencEncRange>,
}

/// Builds the index from a byte slice holding either a whole MP4 or exactly
/// its `moov` box. `base_off` is the file offset the slice starts at (0 for a
/// whole file, the moov offset for a moov-only slice); sample-data offsets
/// come from `stco`/`co64` values and are absolute either way. Returns `None`
/// when no track carries an encrypted sample entry.
fn build_cenc_index(
    data: &[u8],
    base_off: u64,
    file_len: u64,
) -> Result<Option<CencIndex>, String> {
    let mut index = CencIndex::default();
    let mut any_encrypted_entry = false;
    for boxes in mp4_track_boxes(data) {
        if boxes.get(b"encv").is_some_and(|v| !v.is_empty())
            || boxes.get(b"enca").is_some_and(|v| !v.is_empty())
        {
            any_encrypted_entry = true;
        }
        collect_sample_entry_patches(data, &boxes, base_off, &mut index.patches);
        let senc_boxes = boxes.get(b"senc").cloned().unwrap_or_default();
        let stsz_boxes = boxes.get(b"stsz").cloned().unwrap_or_default();
        let stsc_boxes = boxes.get(b"stsc").cloned().unwrap_or_default();
        if senc_boxes.is_empty() || stsz_boxes.is_empty() || stsc_boxes.is_empty() {
            continue;
        }
        let chunk_box = if let Some(b) = boxes.get(b"stco").and_then(|v| v.first()) {
            *b
        } else if let Some(b) = boxes.get(b"co64").and_then(|v| v.first()) {
            *b
        } else {
            continue;
        };

        let sample_sizes = parse_stsz(data, stsz_boxes[0]);
        let chunk_offsets = parse_chunk_offsets(data, chunk_box);
        let stsc_entries = parse_stsc(data, stsc_boxes[0]);
        let samples = sample_offsets(&stsc_entries, &chunk_offsets, &sample_sizes);
        let mut iv_size = track_iv_size(data, &boxes);
        if iv_size == 0 {
            iv_size = 8;
        }
        let senc_entries = parse_senc(data, senc_boxes[0], iv_size);
        let n = samples.len().min(senc_entries.len());
        for i in 0..n {
            let sample = samples[i];
            let entry = &senc_entries[i];
            if sample.size == 0 {
                continue;
            }
            // The whole-file decrypt only touches the keystream when the
            // sample actually has encrypted bytes; keep that tolerance so a
            // corrupt IV size on a clear sample cannot fail the whole file.
            let needs_keystream =
                entry.subsamples.is_empty() || entry.subsamples.iter().any(|s| s.encrypted > 0);
            if needs_keystream && entry.iv.len() != 8 && entry.iv.len() != 16 {
                return Err(format!("unsupported CENC IV size: {}", entry.iv.len()));
            }
            let mut counter0 = [0u8; 16];
            counter0[..entry.iv.len().min(16)].copy_from_slice(&entry.iv[..entry.iv.len().min(16)]);
            let mut base: u64 = 0;
            if !entry.subsamples.is_empty() {
                let mut pos = sample.off;
                for sub in &entry.subsamples {
                    pos += sub.clear;
                    if sub.encrypted > 0 {
                        let (off, size) = (pos as u64, sub.encrypted as u64);
                        // Mirror the whole-file decrypt: a run reaching past
                        // the end of the file is skipped and consumes no
                        // keystream.
                        if off + size <= file_len {
                            index.ranges.push(CencEncRange {
                                off,
                                size,
                                counter0,
                                base,
                            });
                            base += size;
                        }
                    }
                    pos += sub.encrypted;
                }
            } else {
                let (off, size) = (sample.off as u64, sample.size as u64);
                if off + size <= file_len {
                    index.ranges.push(CencEncRange {
                        off,
                        size,
                        counter0,
                        base: 0,
                    });
                }
            }
        }
    }
    if !any_encrypted_entry {
        return Ok(None);
    }
    index.patches.sort_by_key(|p| p.off);
    index.ranges.sort_by_key(|r| r.off);
    Ok(Some(index))
}

/// Records the rewrites `rewrite_encrypted_sample_entries` used to apply in
/// place (encv -> hvc1, enca -> mp4a, `sinf` blanked into a `free` box) as
/// offset patches instead, so the file on disk keeps its original bytes.
/// The replacement tag comes from `sinf/frma` when present, falling back to
/// the hardcoded pair. frma = bvc2 (ByteDance VVC) maps to vvi1 and the
/// sinf box becomes a minimal vvcC instead of a blank.
fn collect_sample_entry_patches(
    data: &[u8],
    boxes: &HashMap<[u8; 4], Vec<Mp4Box>>,
    base_off: u64,
    out: &mut Vec<CencPatch>,
) {
    for (typ, fallback) in [(b"encv", b"hvc1"), (b"enca", b"mp4a")] {
        let Some(list) = boxes.get(typ) else {
            continue;
        };
        for b in list {
            // The pre-encryption sample-entry tag lives in sinf/frma and must
            // be read before the sinf patch below is recorded. TTS voices
            // (升级版对话 / 多角色对话) are Opus (frma=opus): hardcoding mp4a
            // mislabels them, so the player parses the dOps config as AAC and
            // refuses to decode (real-device finding 2026-10-20).
            let mut target = *fallback;
            let mut sinf: Option<Mp4Box> = None;
            if let Some(child_start) = box_children_start(typ, b.off, b.header) {
                for child in iter_boxes(data, child_start, b.off + b.size) {
                    if child.typ != *b"sinf" {
                        continue;
                    }
                    if let Some(tag) = read_frma(data, child) {
                        target = tag;
                    }
                    sinf = Some(child);
                    break;
                }
            }
            // ByteDance VVC (frma = bvc2, config box bv2C) is a codec tag
            // libavformat does not know: map the entry to the in-band
            // parameter-set tag vvi1 and inject a minimal vvcC below so the
            // VVC decoder learns the NALFF length-prefix layout.
            let mut inject_vvcc = false;
            if *typ == *b"encv" && target == *b"bvc2" {
                target = *b"vvi1";
                inject_vvcc = true;
            }
            if b.off + 8 <= data.len() {
                out.push(CencPatch {
                    off: base_off + (b.off + 4) as u64,
                    bytes: target.to_vec(),
                });
            }
            let Some(child) = sinf else {
                continue;
            };
            if inject_vvcc && child.size >= 14 && child.off + child.size <= data.len() {
                // A 14-byte vvcC FullBox: mov.c skips the 4 version/flags
                // bytes and hands cbs_h266 the rest — 0xFE encodes
                // lengthSizeMinusOne = 3 (u32 NAL length prefixes) with
                // ptl_present_flag = 0, 0x00 declares no parameter-set
                // arrays (they ride in-band, which is what vvi1 means).
                // The remainder of the sinf box becomes a free box so the
                // entry's child box chain stays walkable; a tail too small
                // for a free box (< 8 bytes) is zeroed — demuxers ignore a
                // sub-8-byte remainder at the end of a container.
                let mut rep = Vec::with_capacity(child.size);
                rep.extend_from_slice(&14u32.to_be_bytes());
                rep.extend_from_slice(b"vvcC");
                rep.extend_from_slice(&[0u8; 4]);
                rep.extend_from_slice(&[0xFE, 0x00]);
                if child.size >= 22 {
                    rep.extend_from_slice(&((child.size - 14) as u32).to_be_bytes());
                    rep.extend_from_slice(b"free");
                }
                rep.resize(child.size, 0);
                out.push(CencPatch {
                    off: base_off + child.off as u64,
                    bytes: rep,
                });
                continue;
            }
            let mut header = Vec::with_capacity(8);
            header.extend_from_slice(&8u32.to_be_bytes());
            header.extend_from_slice(b"free");
            out.push(CencPatch {
                off: base_off + child.off as u64,
                bytes: header,
            });
            let start = child.off + 8;
            let end = (child.off + child.size).min(data.len());
            if start < end {
                out.push(CencPatch {
                    off: base_off + start as u64,
                    bytes: vec![0u8; end - start],
                });
            }
        }
    }
}

/// Reads the original (pre-encryption) sample-entry tag from the `frma` box
/// inside `sinf`. Returns `None` when it is absent or not a plausible tag so
/// the caller keeps its hardcoded fallback instead of writing garbage.
fn read_frma(data: &[u8], sinf: Mp4Box) -> Option<[u8; 4]> {
    for child in iter_boxes(data, sinf.off + sinf.header, sinf.off + sinf.size) {
        if child.typ != *b"frma" {
            continue;
        }
        let end = child.off + child.header + 4;
        if end > data.len() {
            break;
        }
        let mut tag = [0u8; 4];
        tag.copy_from_slice(&data[child.off + child.header..end]);
        if tag.iter().all(|c| c.is_ascii_graphic()) {
            return Some(tag);
        }
        break;
    }
    None
}

/// Advances a big-endian 128-bit CTR counter by `blocks` blocks.
fn ctr_counter_plus(counter0: &[u8; 16], blocks: u64) -> [u8; 16] {
    let hi = u64::from_be_bytes(counter0[0..8].try_into().expect("counter hi"));
    let lo = u64::from_be_bytes(counter0[8..16].try_into().expect("counter lo"));
    let (lo, carry) = lo.overflowing_add(blocks);
    let hi = hi.wrapping_add(carry as u64);
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&hi.to_be_bytes());
    out[8..16].copy_from_slice(&lo.to_be_bytes());
    out
}

/// Turns `buf` — the file bytes starting at absolute offset `buf_off` — into
/// the decrypted view of the same range: header patches applied, sample data
/// XORed with the keystream at the correct per-sample position. This is the
/// single transform behind the one-shot decrypt, the FFI body materialisation
/// and the loopback streaming body, so all three agree byte for byte.
pub(crate) fn apply_cenc_index(
    buf: &mut [u8],
    buf_off: u64,
    index: &CencIndex,
    content_key: &[u8],
) -> Result<(), String> {
    if content_key.len() != 16 && content_key.len() != 24 && content_key.len() != 32 {
        return Err("invalid CENC content key length".to_string());
    }
    let buf_start = buf_off;
    let buf_end = buf_off + buf.len() as u64;
    for patch in &index.patches {
        let patch_end = patch.off + patch.bytes.len() as u64;
        let s = patch.off.max(buf_start);
        let e = patch_end.min(buf_end);
        if s < e {
            let src = &patch.bytes[(s - patch.off) as usize..(e - patch.off) as usize];
            buf[(s - buf_start) as usize..(e - buf_start) as usize].copy_from_slice(src);
        }
    }
    for range in &index.ranges {
        let range_end = range.off + range.size;
        let s = range.off.max(buf_start);
        let e = range_end.min(buf_end);
        if s >= e {
            continue;
        }
        // Keystream position of byte `s` within the sample's encrypted
        // stream; CTR blocks are generated per 16 bytes from there.
        let mut stream_pos = range.base + (s - range.off);
        let mut pos = s;
        while pos < e {
            let counter = ctr_counter_plus(&range.counter0, stream_pos / 16);
            let keystream = aes_encrypt_block(content_key, &counter)?;
            let block_off = (stream_pos % 16) as usize;
            let take = (16 - block_off).min((e - pos) as usize);
            let dst = (pos - buf_start) as usize;
            for i in 0..take {
                buf[dst + i] ^= keystream[block_off + i];
            }
            pos += take as u64;
            stream_pos += take as u64;
        }
    }
    Ok(())
}

/// Whole-file in-place decrypt, kept as the reference transform the serve
/// path is validated against: it produces exactly the bytes the per-range
/// path serves. Only tests call it now — production never decrypts a whole
/// file — so it is compiled for tests only.
#[cfg(test)]
fn decrypt_cenc_mp4(data: &mut [u8], content_key: &[u8]) -> Result<(), String> {
    if content_key.len() != 16 && content_key.len() != 24 && content_key.len() != 32 {
        return Err("invalid CENC content key length".to_string());
    }
    let Some(index) = build_cenc_index(data, 0, data.len() as u64)? else {
        return Ok(());
    };
    apply_cenc_index(data, 0, &index, content_key)
}
/// hostile box with a huge `sample_count` can OOM the process.
const MAX_STSZ_SAMPLES: usize = 10_000_000;

fn parse_stsz(data: &[u8], b: Mp4Box) -> Vec<usize> {
    let mut p = b.off + 12;
    if p + 8 > data.len() {
        return Vec::new();
    }
    let sample_size = u32_be(data, p) as usize;
    let sample_count = u32_be(data, p + 4) as usize;
    p += 8;
    let mut out = Vec::new();
    if sample_size != 0 {
        // Fixed-size branch: the box carries no per-sample entries, so
        // `sample_count` alone must be checked against the file. The
        // declared samples must fit inside the file (they live in its
        // `mdat`), and the count itself is capped.
        if sample_count > MAX_STSZ_SAMPLES {
            return Vec::new();
        }
        match sample_count.checked_mul(sample_size) {
            Some(total) if total <= data.len() => {}
            _ => return Vec::new(),
        }
        for _ in 0..sample_count {
            out.push(sample_size);
        }
        return out;
    }
    let mut i = 0;
    while i < sample_count && p + i * 4 + 4 <= data.len() {
        out.push(u32_be(data, p + i * 4) as usize);
        i += 1;
    }
    out
}

fn parse_chunk_offsets(data: &[u8], b: Mp4Box) -> Vec<usize> {
    let mut p = b.off + 12;
    if p + 4 > data.len() {
        return Vec::new();
    }
    let entry_count = u32_be(data, p) as usize;
    p += 4;
    let mut out = Vec::new();
    if b.typ == *b"co64" {
        let mut i = 0;
        while i < entry_count && p + i * 8 + 8 <= data.len() {
            out.push(u64_be(data, p + i * 8) as usize);
            i += 1;
        }
        return out;
    }
    let mut i = 0;
    while i < entry_count && p + i * 4 + 4 <= data.len() {
        out.push(u32_be(data, p + i * 4) as usize);
        i += 1;
    }
    out
}

#[derive(Clone, Copy)]
struct StscEntry {
    first_chunk: usize,
    samples_per_chunk: usize,
}

fn parse_stsc(data: &[u8], b: Mp4Box) -> Vec<StscEntry> {
    let mut p = b.off + 12;
    if p + 4 > data.len() {
        return Vec::new();
    }
    let entry_count = u32_be(data, p) as usize;
    p += 4;
    let mut out = Vec::new();
    let mut i = 0;
    while i < entry_count && p + i * 12 + 12 <= data.len() {
        out.push(StscEntry {
            first_chunk: u32_be(data, p + i * 12) as usize,
            samples_per_chunk: u32_be(data, p + i * 12 + 4) as usize,
        });
        i += 1;
    }
    out
}

#[derive(Clone, Copy)]
struct SampleRange {
    off: usize,
    size: usize,
}

fn sample_offsets(
    stsc_entries: &[StscEntry],
    chunk_offsets: &[usize],
    sample_sizes: &[usize],
) -> Vec<SampleRange> {
    let mut offsets = Vec::new();
    let mut sample_index = 0usize;
    let mut stsc_index = 0usize;
    for (chunk_index, &chunk_off) in chunk_offsets.iter().enumerate() {
        let one_based_chunk = chunk_index + 1;
        while stsc_index + 1 < stsc_entries.len()
            && stsc_entries[stsc_index + 1].first_chunk <= one_based_chunk
        {
            stsc_index += 1;
        }
        if stsc_index >= stsc_entries.len() {
            break;
        }
        let mut off = chunk_off;
        for _ in 0..stsc_entries[stsc_index].samples_per_chunk {
            if sample_index >= sample_sizes.len() {
                return offsets;
            }
            let size = sample_sizes[sample_index];
            offsets.push(SampleRange { off, size });
            off += size;
            sample_index += 1;
        }
    }
    offsets
}

fn track_iv_size(data: &[u8], boxes: &HashMap<[u8; 4], Vec<Mp4Box>>) -> usize {
    if let Some(list) = boxes.get(b"tenc") {
        for b in list {
            if b.size >= 32 && b.off + 16 <= data.len() {
                return data[b.off + 15] as usize;
            }
        }
    }
    0
}

struct SubsampleRange {
    clear: usize,
    encrypted: usize,
}

struct SencEntry {
    iv: Vec<u8>,
    subsamples: Vec<SubsampleRange>,
}

fn parse_senc(data: &[u8], b: Mp4Box, iv_size: usize) -> Vec<SencEntry> {
    if b.off + 16 > data.len() {
        return Vec::new();
    }
    let flags =
        (data[b.off + 9] as i32) << 16 | (data[b.off + 10] as i32) << 8 | data[b.off + 11] as i32;
    let sample_count = u32_be(data, b.off + 12) as usize;
    let mut p = b.off + 16;
    let mut end = b.off + b.size;
    if end > data.len() {
        end = data.len();
    }
    let mut entries = Vec::new();
    for _ in 0..sample_count {
        if p + iv_size > end {
            break;
        }
        let iv = data[p..p + iv_size].to_vec();
        p += iv_size;
        let mut subsamples = Vec::new();
        if flags & 0x02 != 0 {
            if p + 2 > end {
                break;
            }
            let subsample_count = u16_be(data, p) as usize;
            p += 2;
            for _ in 0..subsample_count {
                if p + 6 > end {
                    break;
                }
                subsamples.push(SubsampleRange {
                    clear: u16_be(data, p) as usize,
                    encrypted: u32_be(data, p + 2) as usize,
                });
                p += 6;
            }
        }
        entries.push(SencEntry { iv, subsamples });
    }
    entries
}

fn aes_encrypt_block(key: &[u8], block: &[u8; 16]) -> Result<[u8; 16], String> {
    use aes::cipher::generic_array::GenericArray;
    use aes::cipher::{BlockEncrypt, KeyInit};
    let mut b = GenericArray::clone_from_slice(block);
    match key.len() {
        16 => {
            let cipher =
                aes::Aes128::new_from_slice(key).map_err(|_| "invalid AES key".to_string())?;
            cipher.encrypt_block(&mut b);
        }
        24 => {
            let cipher =
                aes::Aes192::new_from_slice(key).map_err(|_| "invalid AES key".to_string())?;
            cipher.encrypt_block(&mut b);
        }
        32 => {
            let cipher =
                aes::Aes256::new_from_slice(key).map_err(|_| "invalid AES key".to_string())?;
            cipher.encrypt_block(&mut b);
        }
        n => return Err(format!("invalid AES key length {n}")),
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&b);
    Ok(out)
}

pub fn register(s: &mut Server) {
    s.add_route("video", handle_video);
    s.add_route("video_detail", handle_video_detail);
    s.add_route("pseries", handle_pseries);
}

#[cfg(test)]
mod cenc_sample_fixture;
#[cfg(test)]
mod spade_vectors;
#[cfg(test)]
mod unsigned_get_cap;
#[cfg(test)]
mod variant_url_shapes;
