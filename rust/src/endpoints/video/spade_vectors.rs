//! Key and URL golden vectors. They are expectations produced by an
//! independent reference implementation, not by this crate.

use super::*;
use serde_json::json;

fn expect_source(resolution: VideoSourceResolution) -> (String, Vec<u8>) {
    match resolution {
        VideoSourceResolution::Found(url, key) => (url, key),
        other => panic!("expected a playable source, got {other:?}"),
    }
}

#[test]
fn derives_the_short_drama_content_key() {
    let key = derive_spade_content_key("kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==");
    assert_eq!(hex::encode(key), "4990a92de837e29e18031a370ab744e6");
}

#[test]
fn reads_the_episode_vertical_flag() {
    // 官方 `VideoInfo.vertical` 挂在 `data.video_info_list_map` 的每集
    // 条目上（`com.bytedance.rpc.model.VideoInfo`）。
    let vertical = |body: Value| episode_vertical(&serde_json::to_vec(&body).unwrap());
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": {
                "1004": [{ "vertical": true, "video_model": "{}" }]
            } }
        })),
        Some(true)
    );
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": {
                "1004": [{ "vertical": false }]
            } }
        })),
        Some(false)
    );
    // 缺字段 = None：客户端保持旧行为，不是「默认不竖屏」的猜测。
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": {
                "1004": [{ "video_model": "{}" }]
            } }
        })),
        None
    );
    assert_eq!(vertical(json!({ "data": {} })), None);
    // 上游可能给 0/1 或字符串。
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": { "1004": [{ "vertical": 1 }] } }
        })),
        Some(true)
    );
    // shortplay 形状：VideoInfo 在 `data.<vid>` 上，与 video_model 并列。
    assert_eq!(
        vertical(json!({
            "data": { "vid1": { "video_model": "{}", "vertical": true } }
        })),
        Some(true)
    );
    let target = |body: Value, id: &str| episode_vertical_value(&body, Some(id));
    assert_eq!(
        target(
            json!({
                "data": { "1004": { "other": { "vertical": true } } }
            }),
            "episode",
        ),
        None
    );
    assert_eq!(
        target(
            json!({
                "data": { "video_info_list_map": {
                    "other": [{ "vertical": true }]
                } }
            }),
            "episode",
        ),
        None
    );
    assert_eq!(
        target(
            json!({
                "data": {
                    "episode": { "video_model": "{}", "vertical": false },
                    "other": { "video_model": "{}", "vertical": true }
                }
            }),
            "episode",
        ),
        Some(false)
    );
}

#[test]
fn reads_the_embedded_video_model_string() {
    let raw = serde_json::to_vec(&json!({
        "data": { "vid1": { "video_model":
            r#"{"video_list":[{"main_url":"https://example.test/low.mp4"},{"main_url":"https://example.test/high.mp4"}]}"#
        } }
    }))
    .unwrap();
    assert_eq!(
        expect_source(extract_video_url(&raw)).0,
        "https://example.test/high.mp4"
    );
}

#[test]
fn reads_the_shortplay_shape_and_its_key() {
    let model = json!({
        "key_seed": "e/sKbv4roNA/4Xm/6oFbFjBm6AIBteh9Z0EddXTl7yI=",
        "video_list": {
            "video_1": {
                "definition": "360p",
                "main_url": base64::engine::general_purpose::STANDARD
                    .encode("https://v26-reading-video.fqnovelvod.com/example.mp4"),
                "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
            }
        }
    });
    let map = model.as_object().unwrap();
    let (url, key) = expect_source(extract_shortplay_video_model_source(map));
    assert_eq!(url, "https://v26-reading-video.fqnovelvod.com/example.mp4");
    assert_eq!(key.len(), 16);
}

#[test]
fn fallback_source_prefers_the_highest_quality_and_keeps_its_key() {
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {
                    "main_url": "https://example.test/low.mp4",
                    "vwidth": 720, "vheight": 1280
                },
                "video_5": {
                    "main_url": "https://example.test/high.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "spade_a": "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg=="
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, key) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/high.mp4");
    assert_eq!(hex::encode(key), "4990a92de837e29e18031a370ab744e6");
}

#[test]
fn fallback_source_keeps_the_bytevc2_tier_that_scores_highest() {
    // 上游 fqapp 面向 Flutter 播放器，bytevc2/VVC 无解码器，选流门跳过
    // （CRIT-004）；本项目播放内核是 mpv（FFmpeg 8.0 原生 VVC 软解），
    // bytevc2 档照常参选——高分 VVC 档必须赢，不得回退到低分 H.264。
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_5": {
                    "main_url": "https://example.test/vvc.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "codec_type": "bytevc2"
                },
                "video_1": {
                    "main_url": "https://example.test/h264.mp4",
                    "vwidth": 720, "vheight": 1280,
                    "codec_type": "h264"
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, _) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/vvc.mp4");
}

#[test]
fn fallback_source_serves_a_bytevc2_only_list() {
    // 同上：本项目不设 bytevc2 门，纯 VVC 列表照常给出可播地址，
    // 不得像上游那样整列表 CodecRejected。
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_5": {
                    "main_url": "https://example.test/vvc.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "gear_des_key": "bytevc2_1080p"
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, _) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/vvc.mp4");
}

#[test]
fn variant_display_name_follows_the_short_edge_mapping() {
    assert_eq!(variant_display_name(360), "360P");
    assert_eq!(variant_display_name(480), "480P");
    assert_eq!(variant_display_name(540), "540P");
    assert_eq!(variant_display_name(720), "720P");
    assert_eq!(variant_display_name(1080), "1080P");
    assert_eq!(variant_display_name(1440), "2K");
    assert_eq!(variant_display_name(2160), "4K");
    assert_eq!(variant_display_name(0), "");
}

#[test]
fn variant_rows_skip_bytevc2_and_sort_by_the_short_edge() {
    // 竖屏漫剧（series 7686494169098898456 实测形状）：video_list 是
    // object，vheight 是长边——档位名必须取短边，bytevc2 档被排除。
    let video_list = json!({
        "video_4": {
            "main_url": "https://example.test/a.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "bytevc2"
        },
        "video_3": {
            "main_url": "https://example.test/720.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "h264",
            "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
        },
        "video_2": {
            "main_url": "https://example.test/540.mp4",
            "vwidth": 540, "vheight": 960, "codec_type": "h264",
            "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
        },
        "video_1": {
            "main_url": "https://example.test/360.mp4",
            "vwidth": 360, "vheight": 640, "codec_type": "h264",
            "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
        }
    });
    let rows = merge_variant_rows(variant_rows_scored(
        video_list.as_object(),
        Some(b"AAAA".to_vec()),
    ));
    let names: Vec<&str> = rows.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["720P", "540P", "360P"]);
    for row in &rows {
        assert!(row["url"].as_str().unwrap().starts_with("https://"));
        assert_eq!(row["key_hex"].as_str().unwrap().len(), 32);
    }
}

#[test]
fn fallback_source_prefers_h264_on_equal_quality() {
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {
                    "main_url": "https://example.test/h265.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "bitrate": 2000000,
                    "codec_type": "h265"
                },
                "video_2": {
                    "main_url": "https://example.test/h264.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "bitrate": 2000000,
                    "codec_type": "h264"
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, _) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/h264.mp4");
}

/// Counting-only face of the variant pipeline: the same gates the async path
/// runs, over an already-decoded `video_list`, with no network and no `Ctx`.
fn variant_counts_of(video_list: &Value, key_seed: Option<&[u8]>) -> VariantCounts {
    let batch =
        variant_rows_scored_with_counts(video_list.as_object(), key_seed.map(|s| s.to_vec()));
    let (rows, counts) = tally_variants(batch.rows, std::slice::from_ref(&batch.counts));
    assert_eq!(
        rows.len(),
        counts.kept,
        "kept must be the panel's quality_count"
    );
    assert_eq!(
        counts.kept + counts.dropped.total(),
        counts.raw_entries,
        "every entry is either kept or explained: {counts:?}"
    );
    counts
}

#[test]
fn variant_counts_separate_a_one_entry_list_from_a_five_entry_list() {
    // 这是 `quality_count` 缺的分母:五条里两条是同档不同地址(1080P 重复),
    // `quality_count=3` 既可能是「上游只给了三条」,也可能是「上游给了
    // 五条、合并折叠两条」——计数器把两者分开。本项目不设 bytevc2 门
    // (mpv 软解 VVC),VVC 档照常计入 kept,`bytevc2` 桶恒为 0。
    let video_list = json!({
        "video_5": { "main_url": "https://example.test/1080-vvc.mp4",
            "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc2" },
        "video_4": { "main_url": "https://example.test/720-vvc.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "bytevc2" },
        "video_3": { "main_url": "https://example.test/540-vvc.mp4",
            "vwidth": 540, "vheight": 960, "codec_type": "bytevc2" },
        "video_2": { "main_url": "https://example.test/1080-h264.mp4",
            "vwidth": 1080, "vheight": 1920, "codec_type": "h264" },
        "video_1": { "main_url": "https://example.test/1080-vvc1-alt.mp4",
            "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1" }
    });
    let counts = variant_counts_of(&video_list, Some(b"AAAA"));
    assert_eq!(counts.raw_entries, 5);
    assert_eq!(counts.kept, 3);
    assert_eq!(
        counts.dropped,
        VariantDropCounts {
            bytevc2: 0,
            no_url: 0,
            no_meta: 0,
            duplicate: 2,
        }
    );
    assert_eq!(
        counts.dropped.summary(),
        "bytevc2:0,no_url:0,no_meta:0,dup:2"
    );
}

#[test]
fn variant_counts_keep_every_tier_of_a_healthy_five_tier_model() {
    let video_list = json!({
        "video_5": { "main_url": "https://example.test/1080.mp4",
            "vwidth": 1080, "vheight": 1920, "codec_type": "h264" },
        "video_4": { "main_url": "https://example.test/720.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "h264" },
        "video_3": { "main_url": "https://example.test/540.mp4",
            "vwidth": 540, "vheight": 960, "codec_type": "h264" },
        "video_2": { "main_url": "https://example.test/480.mp4",
            "vwidth": 480, "vheight": 854, "codec_type": "h264" },
        "video_1": { "main_url": "https://example.test/360.mp4",
            "vwidth": 360, "vheight": 640, "codec_type": "h264" }
    });
    let counts = variant_counts_of(&video_list, Some(b"AAAA"));
    assert_eq!(counts.raw_entries, 5);
    assert_eq!(counts.kept, 5);
    assert_eq!(counts.dropped.total(), 0);
    assert_eq!(
        counts.dropped.summary(),
        "bytevc2:0,no_url:0,no_meta:0,dup:0"
    );
}

#[test]
fn variant_counts_give_undecodable_urls_and_missing_metadata_their_own_buckets() {
    let video_list = json!({
        "video_3": { "main_url": "https://example.test/720.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "h264" },
        // 解不出可播地址(`decrypt_variant_entry` 返回 None),不是 bytevc2。
        "video_2": { "main_url": "not-a-playable-url",
            "vwidth": 540, "vheight": 960, "codec_type": "h264" },
        // 地址没问题,但缺宽高 => 拼不出画质名,面板那一档没法显示。
        "video_1": { "main_url": "https://example.test/360.mp4",
            "codec_type": "h264" }
    });
    // 无 key_seed 时,非 URL 文本没有任何解密路径可走,必然落进 `no_url`。
    let counts = variant_counts_of(&video_list, None);
    assert_eq!(counts.raw_entries, 3);
    assert_eq!(counts.kept, 1);
    assert_eq!(counts.dropped.no_url, 1);
    assert_eq!(counts.dropped.no_meta, 1);
    assert_eq!(counts.dropped.bytevc2, 0);
    assert_eq!(counts.dropped.duplicate, 0);
}

#[test]
fn variant_counts_have_no_no_key_bucket_because_the_key_is_not_a_gate_here() {
    // 档位列表这条路径从不因派生不出内容密钥而丢档:缺 `spade_a` 时
    // `derive_spade_content_key` 给一个空密钥,行照样进面板(与选流门不同,
    // `extract_shortplay_video_model_source` 才有 `encrypted_without_seed` 前置)。
    // 所以计数器里没有 `no_key`——一个永远为 0 的桶只会误导下一个人。
    let video_list = json!({
        "video_1": { "main_url": "https://example.test/720.mp4",
            "vwidth": 720, "vheight": 1280 }
    });
    let counts = variant_counts_of(&video_list, Some(b"AAAA"));
    assert_eq!(counts.raw_entries, 1);
    assert_eq!(counts.kept, 1);
    assert_eq!(counts.dropped.total(), 0);
}
