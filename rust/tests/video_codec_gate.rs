//! Exercise codec handling through the real dispatcher, including the raw
//! response and download fallbacks that extractor-only tests cannot cover.
//! bytevc2/VVC tiers are fully allowed here: the OHOS player (mpv / FFmpeg
//! 8.0) soft-decodes VVC, so no tier is filtered for codec reasons.

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

const ALLOWED_URL: &str = "https://example.invalid/h264.mp4";
const VVC_URL: &str = "https://example.invalid/bytevc2.mp4";
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";
const KEY_HEX: &str = "4990a92de837e29e18031a370ab744e6";

fn response_shapes(variants: Vec<Value>) -> Vec<(&'static str, Value)> {
    let video_map: serde_json::Map<String, Value> = variants
        .iter()
        .enumerate()
        .map(|(i, v)| (format!("video_{i}"), v.clone()))
        .collect();
    let shortplay = json!({"key_seed": "AAAA", "video_list": video_map});
    let array_model = json!({"video_list": variants});
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
            "nested shortplay",
            json!({"data": {"episode": {"video_model": shortplay}}}),
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
    for codec in [
        json!({"codec_type": "ByTeVc2"}),
        json!({"video_meta": {"codec_type": "BYTEVC2"}}),
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
async fn invalid_seed_falls_back_to_the_raw_response() {
    // key_seed 解不出时 shortplay 档无法解密：NotFound 原样透传上游响应。
    // 编码门已放行（VVC 可软解），该场景不再是 500「该视频暂不支持播放」。
    for seed in [Value::Null, json!(""), json!("invalid!")] {
        let payload = json!({"data": {"video_model": {
            "key_seed": seed,
            "video_list": {"video_1": {
                "codec_type": "bytevc2", "main_url": VVC_URL
            }}
        }}});
        let expected = payload.clone();
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-seed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body, expected, "{body}");
    }
}

#[tokio::test]
async fn mixed_variants_rank_by_resolution_first() {
    // 分辨率优先：bytevc2 1080 压过 h264/h265 720（VVC 照常参选）；
    // 同分辨率才轮到 h264 tie-break。
    let variants = vec![
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720}),
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720}),
        json!({"main_url": VVC_URL, "codec_type": "bytevc2", "vwidth": 1080}),
    ];
    for (name, payload) in response_shapes(variants) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-mixed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], VVC_URL, "{name}: {body}");
    }
}

#[tokio::test]
async fn h264_wins_the_tie_against_h265_at_equal_quality() {
    let variants = vec![
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720}),
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720}),
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
}

#[tokio::test]
async fn fallback_list_resolves_when_the_original_model_is_encrypted() {
    // 原始模型整档加密、解不出明文流：必须改走 `fallback_api` 列表重选，
    // 列表里的 bytevc2 档照常可选（VVC 软解放行），原始密文 URL 绝不外泄。
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

#[tokio::test]
async fn download_failure_returns_an_error_instead_of_the_encrypted_url() {
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
    let upstream = MockUpstream::start(|req| {
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
    assert!(upstream.requests().iter().any(|r| r.path == "/fallback"));
}

/// The fallback list's low tiers are often bytevc2; they must reach the panel
/// now that VVC is soft-decodable on the player.
#[tokio::test]
async fn stream_variants_merge_bytevc2_tiers() {
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
