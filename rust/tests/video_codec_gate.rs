//! Exercise codec handling through the real dispatcher, including the raw
//! response and download fallbacks that extractor-only tests cannot cover.
//! bytevc2/VVC tiers are fully allowed here: the OHOS player (mpv / FFmpeg
//! 8.0) soft-decodes VVC, so no tier is filtered for codec reasons.

#![allow(clippy::await_holding_lock)]

mod common;

use common::{build_server, pool_json, query_map, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use fqapi_core::upstream::reset_playback_route_state_for_tests;
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

const ALLOWED_URL: &str = "https://example.invalid/h264.mp4";
const VVC_URL: &str = "https://example.invalid/bytevc2.mp4";
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";
const KEY_HEX: &str = "4990a92de837e29e18031a370ab744e6";

static ROUTES: Mutex<()> = Mutex::new(());

fn exclusive() -> MutexGuard<'static, ()> {
    let guard = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
    reset_playback_route_state_for_tests();
    guard
}

fn response_shapes(variants: Vec<Value>) -> Vec<(&'static str, Value)> {
    let video_map: serde_json::Map<String, Value> = variants
        .iter()
        .enumerate()
        .map(|(i, v)| (format!("video_{i}"), v.clone()))
        .collect();
    let shortplay = json!({"key_seed": "AAAA", "video_list": video_map});
    let array_model = json!({"key_seed": "AAAA", "video_list": variants});
    let decoy = json!({"key_seed": "AAAA", "video_list": {
        "video_0": {"main_url": ALLOWED_URL, "codec_type": "h264"}
    }});
    vec![
        (
            "shortplay object",
            json!({"data": {"video_model": shortplay}}),
        ),
        (
            "shortplay string",
            json!({"data": {"video_model": shortplay.to_string()}}),
        ),
        (
            "v5 grouped episode",
            json!({"data": {"1004": {
                "episode": {"video_model": shortplay},
                "other": {"video_model": decoy}
            }}}),
        ),
        (
            "array object",
            json!({"data": {"video_model": array_model}}),
        ),
        (
            "nested array string",
            json!({"data": {"episode": {"video_model": array_model.to_string()}}}),
        ),
        (
            "phoenix play info",
            json!({"data": {"video_info_list_map": {"episode": [
                {"play_info_list": variants}
            ]}}}),
        ),
    ]
}

async fn request_video(server: &Server, query: &str) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: query.to_string(),
            ..Default::default()
        },
    )
    .await;
    let status = response.status;
    let body = response.into_bytes().await.expect("response body");
    (
        status,
        serde_json::from_slice(&body).expect("JSON response"),
    )
}

#[tokio::test]
async fn bytevc2_only_resolves_across_response_shapes() {
    // VVC 软解放行后，bytevc2-only 列表照常选流，不再整片 500。
    // 无质量元数据的行（编码只落在 codec_type / gear_des_key）进不了
    // 清晰度面板（no_meta），stream 直出 VVC 直链。
    let _guard = exclusive();
    for codec in [
        json!({"codec_type": "ByTeVc2"}),
        json!({"gear_des_key": "bytevc2_1080p"}),
    ] {
        let mut variant = codec;
        variant["main_url"] = json!(VVC_URL);
        for (name, payload) in response_shapes(vec![variant]) {
            let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
            let dir = TempDir::new("video-codec-allow");
            let server =
                build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
            let (status, body) = request_video(&server, "mode=stream").await;
            assert_eq!(status, 200, "{name}: {body}");
            assert_eq!(body["video_url"], VVC_URL, "{name}: {body}");
        }
    }
}

#[tokio::test]
async fn bytevc2_in_video_meta_goes_through_the_download_fallback() {
    // video_meta 携带编码时同时触发质量元数据门：行必须带尺寸才参选。
    // 带上尺寸后行进清晰度面板，行级编码识别命中 bytevc2，stream 落入
    // VVC 下载回退（/src/ loopback）；phoenix 形状不走 model 面板，直链出流。
    let _guard = exclusive();
    let mut variant = json!({"video_meta": {
        "codec_type": "BYTEVC2", "vwidth": 1080, "vheight": 1920
    }});
    variant["main_url"] = json!(VVC_URL);
    for (name, payload) in response_shapes(vec![variant]) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-meta");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        if name == "phoenix play info" {
            assert_eq!(body["video_url"], VVC_URL, "{name}: {body}");
        } else {
            assert!(
                body["video_url"]
                    .as_str()
                    .is_some_and(|url| url.starts_with("/src/")),
                "{name}: {body}"
            );
            assert_eq!(body["quality"], "1080P", "{name}: {body}");
        }
    }
}

#[tokio::test]
async fn invalid_seed_still_serves_the_plain_url() {
    // key_seed 解不出时密文档无法解密，但明文直链照常出流：取流链不再
    // 原样透传上游响应，而是返回规范化 body（明文 URL 直出、variants 为
    // 空）。编码门已放行（VVC 可软解），该场景不再是 500「该视频暂不支持播放」。
    let _guard = exclusive();
    for seed in [Value::Null, json!(""), json!("invalid!")] {
        let payload = json!({"data": {"video_model": {
            "key_seed": seed,
            "video_list": {"video_1": {
                "codec_type": "bytevc2", "main_url": VVC_URL
            }}
        }}});
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-seed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["video_url"], VVC_URL, "{body}");
        assert_eq!(body["variants"], json!([]), "{body}");
    }
}

#[tokio::test]
async fn mixed_variants_rank_by_resolution_first() {
    // 分辨率优先：bytevc2 1080 压过 h264/h265 720（VVC 照常参选）；
    // 同分辨率才轮到 h264 tie-break。模型形状下面板行编码命中 bytevc2，
    // stream 走 VVC 下载回退；phoenix 形状无面板，直链出流。
    let _guard = exclusive();
    let variants = vec![
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720, "vheight": 1280}),
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720, "vheight": 1280}),
        json!({"main_url": VVC_URL, "codec_type": "bytevc2", "vwidth": 1080, "vheight": 1920}),
    ];
    for (name, payload) in response_shapes(variants) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-mixed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        if name == "phoenix play info" {
            assert_eq!(body["video_url"], VVC_URL, "{name}: {body}");
        } else {
            assert!(
                body["video_url"]
                    .as_str()
                    .is_some_and(|url| url.starts_with("/src/")),
                "{name}: {body}"
            );
            assert_eq!(body["quality"], "1080P", "{name}: {body}");
        }
    }
}

#[tokio::test]
async fn h264_wins_the_tie_against_h265_at_equal_quality() {
    // 同分辨率平手时 h264 靠 +1 bonus 胜出。行必须带尺寸：只有 vwidth
    // 会触发质量元数据门被整行丢弃（视频取流失败）。
    let _guard = exclusive();
    let variants = vec![
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720, "vheight": 1280}),
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720, "vheight": 1280}),
    ];
    for (name, payload) in response_shapes(variants) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-tie");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], ALLOWED_URL, "{name}: {body}");
    }
}

#[tokio::test]
async fn unrecognized_payload_keeps_legacy_raw_response_compatibility() {
    let _guard = exclusive();
    let payload = json!({"code": 0, "data": {"legacy": {"main_url": ALLOWED_URL}}});
    let expected = payload.clone();
    let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
    let dir = TempDir::new("video-codec-legacy");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 200);
        assert_eq!(body, expected);
    }

    let payload = json!({"code": 0, "data": {"1004": {
        "other": {"main_url": "https://example.invalid/other.mp4"}
    }}});
    let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
    let dir = TempDir::new("video-v5-target-missing");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 500, "{mode}: {body}");
        assert_eq!(body["error"], "视频取流失败，请稍后重试", "{mode}: {body}");
        assert!(!body.to_string().contains("other.mp4"), "{mode}: {body}");
    }
}

#[tokio::test]
async fn fallback_list_resolves_when_the_original_model_is_encrypted() {
    // 原始模型整档加密、解不出明文流：必须改走 `fallback_api` 列表重选，
    // 列表里的 bytevc2 档照常可选（VVC 软解放行），原始密文 URL 绝不外泄。
    let _guard = exclusive();
    let model = json!({
        "fallback_api": "https://example.invalid/fallback",
        "video_list": [{
            "main_url": "https://example.invalid/original.mp4",
            "encrypt_info": {"encrypt": true}
        }]
    });
    for data in [
        json!({"video_model": model}),
        json!({"episode": {"video_model": model.to_string()}}),
    ] {
        let upstream = MockUpstream::start(move |req| {
            if req.path == "/fallback" {
                return MockReply::json(json!({"video_info": {"data": {
                    "key_seed": "AAAA", "video_list": {"video_1": {
                        "main_url": VVC_URL, "codec_type": "bytevc2"
                    }}
                }}}));
            }
            MockReply::json(json!({"data": data}))
        })
        .await;
        let dir = TempDir::new("video-codec-fallback");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["video_url"], VVC_URL, "{body}");
        assert!(!body.to_string().contains("original.mp4"), "{body}");
        let (status, body) = request_video(&server, "").await;
        assert_eq!(status, 200, "{body}");
        assert!(!body.to_string().contains("original.mp4"), "{body}");
        let requests = upstream.requests();
        assert!(requests.iter().any(|r| r.path == "/fallback"));
        assert!(requests.iter().any(|r| r.path == "/bytevc2.mp4"));
    }
}

/// 加密模型 + fallback 拉取失败（503）：编码结论未知，绝不能回退到原始
/// 密文 URL——必须显式报取流失败，让客户端出重试卡。
#[tokio::test]
async fn fallback_unknown_is_reported_as_a_stream_failure() {
    let model = json!({
        "fallback_api": "https://example.invalid/fallback",
        "video_list": [{
            "main_url": "https://example.invalid/original.mp4",
            "encrypt_info": {"encrypt": true}
        }]
    });
    let upstream = MockUpstream::start(move |req| {
        if req.path == "/fallback" {
            return MockReply::status(503);
        }
        MockReply::json(json!({"data": {"video_model": model}}))
    })
    .await;
    let dir = TempDir::new("video-codec-fallback-unknown");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 500, "{mode}: {body}");
        assert_eq!(body["error"], "视频取流失败，请稍后重试", "{mode}: {body}");
        assert!(!body.to_string().contains("original.mp4"), "{mode}: {body}");
    }
}

#[tokio::test]
async fn download_failure_returns_an_error_instead_of_the_encrypted_url() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|req| {
        if req.path.ends_with(".mp4") {
            return MockReply::status(500);
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA", "video_list": {
                "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A},
                "video_2": {"main_url": VVC_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-download");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    // 密文流客户端打不开：报错出重试，绝不回退 URL/key_hex。
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false, "{body}");
    assert_eq!(body["error"], "视频下载失败，请稍后重试", "{body}");
    assert!(!body.to_string().contains(ALLOWED_URL), "{body}");
    assert!(!body.to_string().contains(KEY_HEX), "{body}");
    assert!(!body.to_string().contains(VVC_URL), "{body}");
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/h264.mp4"));
    assert!(requests.iter().all(|r| r.path != "/bytevc2.mp4"));
}

#[tokio::test]
async fn successful_download_keeps_the_local_source_contract() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|req| {
        if req.path == "/h264.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"video fixture".to_vec(),
            };
        }
        MockReply::json(json!({"data": {"episode": {"video_model": {
            "video_list": [{"main_url": ALLOWED_URL, "codec_type": "h264"}]
        }}}}))
    })
    .await;
    let dir = TempDir::new("video-codec-local");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], "/src/episode.mp4");
    // 老形状（上游不带档位）：保持主解析选流，quality 回显空串。
    assert_eq!(body["quality"], "");
    assert_eq!(
        body["video_info"]["data"]["video_list"]["video_1"]["main_url"],
        "/src/episode.mp4"
    );
    assert_eq!(
        std::fs::read(dir.join("src/episode.mp4")).unwrap(),
        b"video fixture"
    );
}

/// The shortplay list stops at 720P; the model's `fallback_api` list carries
/// the top tier. The stream response must merge both, or the quality panel
/// silently loses a row (measured 2026-10-12 on the live upstream).
#[tokio::test]
async fn stream_variants_merge_the_fallback_list_so_the_top_tier_survives() {
    let _guard = exclusive();
    let v5_calls = Arc::new(AtomicUsize::new(0));
    let v5_calls_for_mock = Arc::clone(&v5_calls);
    let upstream = MockUpstream::start(move |req| {
        if req.path == "/novel/player/multi_video_model/player/v1"
            && v5_calls_for_mock.fetch_add(1, Ordering::SeqCst) == 0
        {
            return MockReply::status(503);
        }
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/360.mp4",
                        "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": "https://example.invalid/720.mp4",
                        "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_3": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": "https://example.invalid/360.mp4",
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                "video_2": {"main_url": "https://example.invalid/720.mp4",
                    "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-variant-merge");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let names: Vec<&str> = body["variants"]
        .as_array()
        .expect("variants array")
        .iter()
        .map(|v| v["name"].as_str().expect("variant name"))
        .collect();
    assert_eq!(names, ["1080P", "720P", "360P"], "{body}");
    assert_eq!(
        body["variants"][0]["url"],
        "https://example.invalid/1080.mp4"
    );
    assert_eq!(
        body["variants"][0]["key_hex"].as_str().expect("key").len(),
        32,
        "{body}"
    );
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/fallback"));
    let v5_requests: Vec<_> = requests
        .iter()
        .filter(|r| r.path == "/novel/player/multi_video_model/player/v1")
        .collect();
    assert_eq!(v5_requests.len(), 2);
    assert_ne!(v5_requests[0].query, v5_requests[1].query);
    let v5 = v5_requests[1];
    assert_eq!(v5.method, "POST");
    assert_eq!(
        query_map(&v5.query).get("aid").map(String::as_str),
        Some("8662")
    );
    assert_eq!(v5.header("content-encoding"), Some("gzip"));
    assert_eq!(
        v5.header("content-type"),
        Some("application/json; charset=utf-8")
    );
    assert!(v5.header("x-medusa").is_some());
    assert!(v5.header("x-argus").is_none());
    let expected_stub = hex::encode_upper(Md5::digest(&v5.body));
    assert_eq!(v5.header("x-ss-stub"), Some(expected_stub.as_str()));
    let plain = fqapi_core::crypto::gunzip(&v5.body).expect("gzip V5 body");
    let wire: Value = serde_json::from_slice(&plain).expect("V5 JSON body");
    assert_eq!(wire["mixed_video_id_map"]["1004"], json!(["episode"]));
    assert_eq!(wire["dr_scene"], "player");
}

/// The fallback list's low tiers are often bytevc2; they must reach the panel
/// now that VVC is soft-decodable on the player.
#[tokio::test]
async fn stream_variants_merge_bytevc2_tiers() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|req| {
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": VVC_URL,
                        "vwidth": 720, "vheight": 1280, "codec_type": "bytevc2", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": ALLOWED_URL,
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-variant-merge-vvc");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let names: Vec<&str> = body["variants"]
        .as_array()
        .expect("variants array")
        .iter()
        .map(|v| v["name"].as_str().expect("variant name"))
        .collect();
    assert_eq!(names, ["1080P", "720P", "360P"], "{body}");
    assert!(body.to_string().contains(VVC_URL), "{body}");
}

/// 默认档升级：quality 未请求时自动选合并列表最高可用档（此处 1080P 只在
/// fallback 列表里），回显实际档名、按档分缓存——此前默认档只走主解析
/// 选流（最高 720P）、quality 恒空、缓存文件为裸 {video_id}。
#[tokio::test]
async fn default_quality_upgrades_to_the_top_merged_tier() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/1080.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"top tier fixture".to_vec(),
            };
        }
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": "https://example.invalid/360.mp4",
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                "video_2": {"main_url": "https://example.invalid/720.mp4",
                    "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-default-top");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["quality"], "1080P", "{body}");
    assert_eq!(body["video_url"], "/src/episode_1080P.mp4", "{body}");
    assert_eq!(
        std::fs::read(dir.join("src/episode_1080P.mp4")).unwrap(),
        b"top tier fixture"
    );
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/1080.mp4"));
    assert!(requests.iter().all(|r| r.path != "/720.mp4"));
}

/// 默认档封顶 1080P：2K/4K 档只保留给手动选择（4K VVC 软解耗电卡顿），
/// 自动档跳过它们取次高可用档。
#[tokio::test]
async fn default_quality_skips_2k_and_4k_tiers() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/1080.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"capped fixture".to_vec(),
            };
        }
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/2160.mp4",
                        "vwidth": 2160, "vheight": 3840, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": "https://example.invalid/720.mp4",
                    "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-default-cap");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["quality"], "1080P", "{body}");
    assert_eq!(body["video_url"], "/src/episode_1080P.mp4", "{body}");
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/1080.mp4"));
    assert!(requests.iter().all(|r| r.path != "/2160.mp4"));
}

/// The official single-episode door (`/novel/player/video_model/v1/`) answers
/// `data.video_model` in both the object and the string form; both must reach
/// the shared parser, and the request must carry that door's own HAR params.
#[tokio::test]
async fn the_single_episode_model_door_parses_both_video_model_shapes() {
    let _guard = exclusive();
    let model = json!({
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": ALLOWED_URL, "codec_type": "h264",
            "vwidth": 1080, "vheight": 1920
        }}
    });
    let object = json!({"code": 0, "data": {"video_model": model.clone()}});
    let string = json!({"code": 0, "data": {"video_model": model.to_string()}});
    for (name, payload) in [("object", object), ("string", string)] {
        reset_playback_route_state_for_tests();
        let reply = payload.clone();
        let upstream = MockUpstream::start(move |req| {
            if req.path == "/novel/player/multi_video_model/player/v1" {
                MockReply::status(200)
            } else {
                MockReply::json(reply.clone())
            }
        })
        .await;
        let dir = TempDir::new("video-model-door");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], ALLOWED_URL, "{name}: {body}");

        let requests = upstream.requests();
        let model_request = requests
            .iter()
            .find(|request| request.path == "/novel/player/video_model/v1/")
            .unwrap_or_else(|| panic!("{name}: the single-episode door must be asked"));
        assert_eq!(model_request.method, "POST", "{name}");
        assert_eq!(
            model_request.header("content-encoding"),
            Some("gzip"),
            "{name}"
        );
        let expected_stub = hex::encode_upper(Md5::digest(&model_request.body));
        assert_eq!(
            model_request.header("x-ss-stub"),
            Some(expected_stub.as_str()),
            "{name}"
        );
        let plain = fqapi_core::crypto::gunzip(&model_request.body).expect("gzip model body");
        let wire: Value = serde_json::from_slice(&plain).expect("model JSON body");
        assert_eq!(wire["content_type"], json!(1004), "{name}");
        assert_eq!(wire["video_id"], json!("episode"), "{name}");
        assert_eq!(
            wire["biz_param"],
            json!({
                "detail_page_version": 0,
                "device_level": 3,
                "disable_digg_stat": false,
                "from_video_id": "",
                "need_all_video_definition": true,
                "need_mp4_align": false,
                "source": 9,
                "use_os_player": false,
                "use_server_dns": false,
                "video_platform": 3,
            }),
            "{name}"
        );
        let first = requests.first().expect("initial door");
        assert_eq!(
            query_map(&first.query).get("device_id"),
            query_map(&model_request.query).get("device_id"),
            "the single-episode door must reuse the initial identity"
        );
        for header in ["x-medusa", "x-helios", "x-khronos"] {
            assert!(model_request.header(header).is_some(), "{header}");
        }
        upstream.shutdown();
    }
}
