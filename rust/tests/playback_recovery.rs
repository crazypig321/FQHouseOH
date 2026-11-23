//! Playback door fallback contract.
//!
//! Ported from `N3urda/hongguoTV`'s `streamLadderWithCompatibility`: when the v5
//! player door answers `HTTP 200` with no bytes, the playback model is requested
//! from the signed `video_tab` doors under the same identity, doors that returned
//! an empty body stay parked, and only a foreground request may rotate identity.
//! Nothing here may leak a URL, a body or a signature into the error surface.
//!
//! The door-health state is process-wide, so these scenarios take turns on a
//! plain mutex. Holding it across `await` is the point: the guard is released
//! only when the scenario that owns the state is finished.
#![allow(clippy::await_holding_lock)]

mod common;

use common::{build_server, pool_json, query_map, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use fqapi_core::upstream::reset_playback_route_state_for_tests;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::{Mutex, MutexGuard};

const V5_PATH: &str = "/novel/player/multi_video_model/player/v1";
const MODEL_PATH: &str = "/novel/player/video_model/v1/";
const TAB_PATH: &str = "/reading/bookapi/video_tab/multi_video_model/v1/";
const VIDEO_ID: &str = "7312345678901234567";

/// Process-wide route state means these scenarios must not interleave.
static ROUTES: Mutex<()> = Mutex::new(());

fn exclusive() -> MutexGuard<'static, ()> {
    let guard = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
    reset_playback_route_state_for_tests();
    guard
}

fn model() -> Value {
    json!({
        "key_seed": "AAAA",
        "video_list": {
            "video_0": {
                "main_url": "https://example.invalid/h264-1080.mp4",
                "codec_type": "h264",
                "video_meta": {"definition": "1080p", "vwidth": 1080, "vheight": 1920},
                "encrypt_info": {"encrypt": false}
            }
        }
    })
}

/// A v5 player response: `data.1004.<video id>.video_model`.
fn v5_body() -> Value {
    let entry = json!({ "video_model": model() });
    let mut group = serde_json::Map::new();
    group.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"1004": Value::Object(group)}})
}

/// A `video_tab` response: `data.video_model_data.<video id>.video_model`.
fn tab_body() -> Value {
    let entry = json!({ "video_model": model() });
    let mut rows = serde_json::Map::new();
    rows.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"video_model_data": Value::Object(rows)}})
}

fn is_v5(request: &common::Recorded) -> bool {
    request.path == V5_PATH
}

fn is_model(request: &common::Recorded) -> bool {
    request.path == MODEL_PATH
}

fn is_tab(request: &common::Recorded) -> bool {
    request.path == TAB_PATH
}

/// A codec-only model in the v5 grouped shape.
fn v5_codec_body(codec: &str) -> Value {
    let entry = json!({ "video_model": {
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": format!("https://example.invalid/{codec}-1080.mp4"),
            "codec_type": codec,
            "vwidth": 1080,
            "vheight": 1920,
        }}
    }});
    let mut group = serde_json::Map::new();
    group.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"1004": Value::Object(group)}})
}

/// A codec-only model in the official single-episode shape (`data.video_model`).
fn model_codec_body(codec: &str) -> Value {
    json!({"code": 0, "data": {"video_model": {
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": format!("https://example.invalid/{codec}-1080.mp4"),
            "codec_type": codec,
            "vwidth": 1080,
            "vheight": 1920,
        }}
    }}})
}

/// A non-empty v5 body whose variant misses the dimensions the panel gate
/// requires: unusable, so the ladder moves on without spending the reprobe.
/// This fork plays bytevc2 tiers through the download fallback, so a rejected
/// codec cannot drive the ladder any more and metadata is the stand-in.
fn v5_unusable_body() -> Value {
    let entry = json!({ "video_model": {
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": "https://example.invalid/no-height.mp4",
            "codec_type": "h264",
            "vwidth": 1080,
        }}
    }});
    let mut group = serde_json::Map::new();
    group.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"1004": Value::Object(group)}})
}

fn device_of(request: &common::Recorded) -> String {
    query_map(&request.query)
        .get("device_id")
        .cloned()
        .unwrap_or_default()
}

/// The video id is the path segment: the router overrides any `video_id` query
/// parameter with it. `mode=stream` keeps the assertion on the model fetch and
/// stops the endpoint from also downloading media through the same mock.
async fn episode(server: &Server, extra: &str) -> (u16, Value) {
    let query = if extra.is_empty() {
        "mode=stream".to_string()
    } else {
        format!("mode=stream&{extra}")
    };
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: format!("/api/v1/videos/{VIDEO_ID}"),
            query,
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

async fn server_with(upstream: &MockUpstream, tag: &str) -> (TempDir, Arc<Server>) {
    let dir = TempDir::new(tag);
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    (dir, server)
}

#[tokio::test]
async fn empty_player_doors_fall_back_to_the_signed_video_tab_door_on_the_same_identity() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if is_tab(request) {
            MockReply::json(tab_body())
        } else {
            MockReply::status(200)
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "fallback-video-tab").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        body["video_url"]
            .as_str()
            .is_some_and(|url| url.starts_with("https://")),
        "the fallback model must produce a playable primary url: {body}"
    );

    let requests = upstream.requests();
    assert_eq!(
        requests.len(),
        5,
        "v5, its single re-probe, model-a, model-c, then one video_tab door"
    );
    assert!(is_v5(&requests[0]) && requests[0].method == "POST");
    assert!(
        is_v5(&requests[1]) && requests[1].method == "POST",
        "the re-probe stays on the v5 door"
    );
    assert!(
        is_model(&requests[2]) && requests[2].method == "POST",
        "the single-episode door is the second chance"
    );
    assert!(is_model(&requests[3]) && requests[3].method == "POST");
    assert!(is_tab(&requests[4]) && requests[4].method == "GET");
    for request in requests.iter().skip(1) {
        assert_eq!(
            device_of(&requests[0]),
            device_of(request),
            "every later door must be asked under the same identity"
        );
    }
    for header in ["x-medusa", "x-helios", "x-khronos"] {
        assert!(
            requests[4].header(header).is_some(),
            "the fallback door must carry the player signature header {header}"
        );
    }
    assert!(
        requests[4].header("x-ss-stub").is_none(),
        "a body-less GET must not claim a body digest"
    );

    let query = query_map(&requests[4].query);
    for (key, expected) in [
        ("video_id", VIDEO_ID),
        ("video_id_type", "0"),
        ("device_level", "1"),
        ("need_all_video_definition", "1"),
        ("need_mp4_align", "0"),
        ("use_os_player", "0"),
        ("video_platform", "1024"),
        ("source", "0"),
        ("from_video_id", ""),
    ] {
        assert_eq!(
            query.get(key).map(String::as_str),
            Some(expected),
            "video_tab parameter {key}"
        );
    }
    upstream.shutdown();
}

#[tokio::test]
async fn an_empty_v5_body_is_reprobed_once_on_the_same_identity_before_switching_door() {
    let _guard = exclusive();
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |request| {
        if is_v5(request) && counter.fetch_add(1, Ordering::SeqCst) == 0 {
            MockReply::status(200)
        } else {
            MockReply::json(v5_body())
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "same-door-reprobe").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    assert_eq!(requests.len(), 2, "one re-probe, no door switch: {body}");
    assert!(
        requests.iter().all(is_v5),
        "the re-probe stays on the v5 door"
    );
    assert_eq!(
        device_of(&requests[0]),
        device_of(&requests[1]),
        "the re-probe must reuse the identity that just answered"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_prefetch_empty_body_is_not_reprobed() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|_| MockReply::status(200)).await;
    let (_dir, server) = server_with(&upstream, "prefetch-empty").await;

    let (status, body) = episode(&server, "_playback_purpose=prefetch").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(
        upstream.requests().len(),
        1,
        "a prefetch must not spend a re-probe on the foreground's budget"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_non_empty_v5_body_never_reaches_a_fallback_door() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|_| MockReply::json(v5_body())).await;
    let (_dir, server) = server_with(&upstream, "v5-first").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    assert_eq!(requests.len(), 1, "a usable v5 model needs no fallback");
    assert!(is_v5(&requests[0]));
    upstream.shutdown();
}

#[tokio::test]
async fn every_video_tab_payload_shape_reaches_the_shared_parser() {
    let flat = {
        let entry = json!({ "video_model": model() });
        let mut rows = serde_json::Map::new();
        rows.insert(VIDEO_ID.to_string(), entry);
        json!({ "code": 0, "data": Value::Object(rows) })
    };
    let embedded = {
        let entry = json!({ "video_model": model().to_string() });
        let mut rows = serde_json::Map::new();
        rows.insert(VIDEO_ID.to_string(), entry);
        json!({ "code": 0, "data": { "video_model_data": Value::Object(rows) } })
    };
    for (name, payload) in [("flat", flat), ("string model", embedded)] {
        let _guard = exclusive();
        let reply = payload.clone();
        let upstream = MockUpstream::start(move |_| MockReply::json(reply.clone())).await;
        let (_dir, server) = server_with(&upstream, "tab-shape").await;
        let (status, body) = episode(&server, "").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert!(
            body["video_url"].as_str().is_some(),
            "{name}: the shared parser must find a playable url: {body}"
        );
        upstream.shutdown();
    }
}

#[tokio::test]
async fn a_rejected_video_tab_body_is_not_treated_as_a_playable_answer() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if is_tab(request) {
            // A business rejection: the door answered, but not with a model.
            MockReply::json(json!({"code": 100103, "data": {}}))
        } else {
            MockReply::status(200)
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "tab-rejected").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false, "{body}");
    assert!(
        !body.to_string().contains("fqnovel") && !body.to_string().contains("https://"),
        "no upstream address may leak: {body}"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn every_door_empty_rotates_the_identity_once_and_stays_bounded() {
    let _guard = exclusive();
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        MockReply::status(200)
    })
    .await;
    let (_dir, server) = server_with(&upstream, "all-empty-rotate").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false, "{body}");

    let requests = upstream.requests();
    assert!(
        requests.len() <= 8,
        "attempts must stay bounded, saw {}",
        requests.len()
    );
    let mut devices: Vec<String> = requests.iter().map(device_of).collect();
    devices.sort();
    devices.dedup();
    assert!(
        devices.len() >= 2,
        "an all-empty round must rotate identity, saw {devices:?}"
    );
    assert!(
        requests
            .iter()
            .all(|request| is_v5(request) || is_model(request) || is_tab(request)),
        "no other upstream path may be touched"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_prefetch_never_probes_parked_doors_or_rotates() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|_| MockReply::status(200)).await;
    let (_dir, server) = server_with(&upstream, "prefetch-parked").await;

    // Foreground first: every door is empty and therefore parked.
    let (status, _) = episode(&server, "").await;
    assert_eq!(status, 500);
    let after_foreground = upstream.requests().len();
    assert!(after_foreground > 1);

    // A prefetch must not spend the foreground's failure budget or rotate.
    let (status, body) = episode(&server, "_playback_purpose=prefetch").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(
        upstream.requests().len(),
        after_foreground,
        "a prefetch over parked doors must not touch the upstream"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_second_all_empty_request_cannot_rotate_again_inside_the_cooldown() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|_| MockReply::status(200)).await;
    let (_dir, server) = server_with(&upstream, "rotate-cooldown").await;

    let (status, _) = episode(&server, "").await;
    assert_eq!(status, 500);
    let after_first = upstream.requests().len();
    assert!(
        after_first >= 2,
        "the first round must have tried several doors"
    );

    let (status, _) = episode(&server, "").await;
    assert_eq!(status, 500);
    let second = upstream.requests().len() - after_first;
    assert_eq!(
        second, 4,
        "every door is parked, so one probe per door is the whole request; a \
         second rotation would add another round"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_parked_empty_door_is_skipped_by_the_next_foreground_request() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if is_v5(request) {
            // The v5 door refuses silently, so it gets parked for 30 s.
            MockReply::status(200)
        } else {
            MockReply::json(tab_body())
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "parked-door").await;

    // First request: v5 empty, then the video_tab door answers.
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let first = upstream.requests().len();
    assert_eq!(first, 3, "v5 empty, its re-probe, then the model door");

    // Second request: the parked v5 door must not be retried before its cooldown.
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let second: Vec<_> = upstream.requests().into_iter().skip(first).collect();
    assert!(!second.is_empty());
    assert!(
        second.iter().all(|request| !is_v5(request)),
        "a parked empty door must be skipped, not retried"
    );
    upstream.shutdown();
}

#[tokio::test]
// 本项目放行 bytevc2：v5 首门的纯 VVC 档直接经下载回退可播，不换门、
// 不换身份，后备门的 H.265 档轮不到。
async fn a_bytevc2_only_answer_is_served_by_the_vvc_download_fallback() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if is_model(request) && device_of(request) != "0000000000000000" {
            MockReply::json(model_codec_body("h265"))
        } else if is_model(request) {
            MockReply::json(model_codec_body("bytevc2"))
        } else {
            MockReply::json(v5_codec_body("bytevc2"))
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "codec-retry-door").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        body["video_url"]
            .as_str()
            .is_some_and(|url| url.starts_with("/src/")),
        "the VVC tier must be served through the download fallback: {body}"
    );
    assert_eq!(body["variants"][0]["codec"], "bytevc2", "{body}");
    assert_eq!(body["quality"], "1080P", "{body}");

    let requests = upstream.requests();
    assert_eq!(
        requests.len(),
        2,
        "one player door plus its media fetch, no door or identity rotation: {body}"
    );
    assert!(is_v5(&requests[0]) && requests[0].method == "POST");
    assert!(
        requests[1].path.ends_with(".mp4"),
        "the second request is the VVC media fetch: {body}"
    );
    assert!(
        !requests.iter().any(is_model) && !requests.iter().any(is_tab),
        "the h265 replacement doors stay untouched: {body}"
    );
    upstream.shutdown();
}

#[tokio::test]
// 全门 bytevc2 在本项目同样是可播档：首门答案直接经下载回退出片，
// 整个请求只花一个门加一次媒体拉取。
async fn an_all_bytevc2_ladder_stays_playable_and_bounded() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|_| MockReply::json(v5_codec_body("bytevc2"))).await;
    let (_dir, server) = server_with(&upstream, "codec-terminal").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        body["video_url"]
            .as_str()
            .is_some_and(|url| url.starts_with("/src/")),
        "a bytevc2-only answer is playable through the download fallback: {body}"
    );
    assert_eq!(body["variants"][0]["codec"], "bytevc2", "{body}");
    let requests = upstream.requests();
    assert_eq!(
        requests.len(),
        2,
        "the first door answers and its media is fetched once, nothing else: {body}"
    );
    assert!(is_v5(&requests[0]) && requests[0].method == "POST");
    assert!(
        requests[1].path.ends_with(".mp4"),
        "the media fetch is the only follow-up request: {body}"
    );
    upstream.shutdown();
}

#[tokio::test]
// bytevc2-only 是可播答案：不落门健康惩罚，下一集照常回到同一扇门。
async fn a_bytevc2_only_answer_does_not_cool_its_route() {
    let _guard = exclusive();
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let model_calls = Arc::new(AtomicUsize::new(0));
    let model_counter = model_calls.clone();
    let upstream = MockUpstream::start(move |request| {
        if is_model(request) {
            if model_counter.fetch_add(1, Ordering::SeqCst) == 0 {
                MockReply::json(model_codec_body("h265"))
            } else {
                MockReply::status(200)
            }
        } else if counter.fetch_add(1, Ordering::SeqCst) == 0 {
            MockReply::json(v5_codec_body("bytevc2"))
        } else {
            MockReply::json(v5_body())
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "codec-no-health-penalty").await;
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        body["video_url"]
            .as_str()
            .is_some_and(|url| url.starts_with("/src/")),
        "the bytevc2 tier is served through the download fallback: {body}"
    );
    let requests = upstream.requests();
    assert_eq!(requests.len(), 2, "{body}");
    assert!(is_v5(&requests[0]));
    assert!(
        requests[1].path.ends_with(".mp4"),
        "the second request is the VVC media fetch: {body}"
    );
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        upstream.requests()[2..].iter().any(is_v5),
        "a bytevc2 answer served by the download fallback does not cool a route"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn any_player_door_can_use_the_requests_single_reprobe() {
    let _guard = exclusive();
    for (selected, preceding_models) in [(MODEL_PATH, 0), (MODEL_PATH, 1), (TAB_PATH, 0)] {
        reset_playback_route_state_for_tests();
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let upstream = MockUpstream::start(move |request| {
            if request.path == selected {
                let selected_call = counter.fetch_add(1, Ordering::SeqCst);
                if selected_call < preceding_models {
                    MockReply::json(v5_unusable_body())
                } else if selected_call == preceding_models {
                    MockReply::status(200)
                } else {
                    MockReply::json(v5_body())
                }
            } else {
                MockReply::json(v5_unusable_body())
            }
        })
        .await;
        let (_dir, server) = server_with(&upstream, "any-door-reprobe").await;
        let (status, body) = episode(&server, "").await;
        assert_eq!(status, 200, "{selected}: {body}");
        let requests = upstream.requests();
        let probes: Vec<_> = requests
            .iter()
            .filter(|request| request.path == selected)
            .skip(preceding_models)
            .collect();
        assert_eq!(probes.len(), 2, "{selected}");
        assert_eq!(device_of(probes[0]), device_of(probes[1]));
        assert!(requests
            .iter()
            .all(|request| device_of(request) == device_of(&requests[0])));
        upstream.shutdown();
    }
}

#[tokio::test]
// prefetch 只花一个门、不注册设备；bytevc2 可播时同样经下载回退出片。
async fn a_prefetch_stays_on_one_door_and_never_registers() {
    let _guard = exclusive();
    for auth_failure in [false, true] {
        reset_playback_route_state_for_tests();
        let upstream = MockUpstream::start(move |_| {
            if auth_failure {
                MockReply::status(401)
            } else {
                MockReply::json(v5_codec_body("bytevc2"))
            }
        })
        .await;
        let dir = TempDir::new("prefetch-no-registration");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(2)).await;
        let (status, body) = episode(&server, "_playback_purpose=prefetch").await;
        let requests: Vec<_> = upstream
            .requests()
            .into_iter()
            .filter(|request| is_v5(request) || is_model(request) || is_tab(request))
            .collect();
        assert_eq!(
            requests.len(),
            1,
            "prefetch uses one door without registration: {body}"
        );
        assert!(is_v5(&requests[0]));
        if auth_failure {
            assert_eq!(status, 500, "{body}");
        } else {
            assert_eq!(status, 200, "{body}");
            assert!(
                body["video_url"]
                    .as_str()
                    .is_some_and(|url| url.starts_with("/src/")),
                "a playable bytevc2 answer is served through the download fallback: {body}"
            );
        }
        upstream.shutdown();
    }
}

#[tokio::test]
async fn missing_dimensions_or_addresses_continue_to_the_next_door() {
    let _guard = exclusive();
    for variant in [
        json!({"codec_type": "h264", "main_url": "https://example.invalid/missing-height.mp4", "vwidth": 1080}),
        json!({"codec_type": "h264", "vwidth": 1080, "vheight": 1920}),
    ] {
        reset_playback_route_state_for_tests();
        let bad = json!({"data": {"video_model": {"video_list": {"video_0": variant}}}});
        let upstream = MockUpstream::start(move |request| {
            if is_model(request) {
                MockReply::json(model_codec_body("h265"))
            } else {
                MockReply::json(bad.clone())
            }
        })
        .await;
        let (_dir, server) = server_with(&upstream, "missing-video-fields").await;
        let (status, body) = episode(&server, "").await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["video_url"], "https://example.invalid/h265-1080.mp4");
        let requests = upstream.requests();
        assert_eq!(requests.len(), 2);
        assert_eq!(device_of(&requests[0]), device_of(&requests[1]));
        upstream.shutdown();
    }
}

#[tokio::test]
// 首身份全空门照常轮换；新身份的 v5 给出 bytevc2 档时，本项目经
// 下载回退直接可播，轮换链路和 VVC 回退同时得到覆盖。
async fn an_empty_identity_rotation_lands_on_the_vvc_download_fallback() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if request.path.ends_with(".mp4") {
            MockReply::json(v5_codec_body("bytevc2"))
        } else if device_of(request) == "0000000000000000" {
            MockReply::status(200)
        } else if is_v5(request) {
            MockReply::json(v5_codec_body("bytevc2"))
        } else {
            MockReply::status(200)
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "empty-codec-replacement").await;
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        body["video_url"]
            .as_str()
            .is_some_and(|url| url.starts_with("/src/")),
        "the replacement identity's bytevc2 answer is served through the download fallback: {body}"
    );
    let requests = upstream.requests();
    let doors: Vec<_> = requests
        .iter()
        .filter(|request| is_v5(request) || is_model(request) || is_tab(request))
        .collect();
    assert_eq!(
        doors.len(),
        6,
        "the empty identity spends its four doors plus the v5 reprobe, then the \
         replacement's v5 answers: {body}"
    );
    assert!(
        doors[..5]
            .iter()
            .all(|request| device_of(request) == device_of(&doors[0])),
        "the empty identity keeps one identity across its doors"
    );
    assert_ne!(
        device_of(&doors[0]),
        device_of(&doors[5]),
        "an all-empty ladder must rotate the identity once"
    );
    assert!(is_v5(&doors[5]));
    assert!(
        requests
            .iter()
            .any(|request| request.path.ends_with(".mp4")),
        "the bytevc2 tier is fetched through the download fallback: {body}"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn all_cooling_doors_are_probed_until_the_last_one_recovers() {
    let _guard = exclusive();
    let recover = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let ready = recover.clone();
    let model_calls = Arc::new(AtomicUsize::new(0));
    let model_counter = model_calls.clone();
    let upstream = MockUpstream::start(move |request| {
        if ready.load(Ordering::SeqCst)
            && is_model(request)
            && model_counter.fetch_add(1, Ordering::SeqCst) == 1
        {
            MockReply::json(model_codec_body("h265"))
        } else {
            MockReply::status(200)
        }
    })
    .await;
    let (_dir, server) = server_with(&upstream, "cooling-last-door").await;
    assert_eq!(episode(&server, "").await.0, 500);
    let before = upstream.requests().len();
    recover.store(true, Ordering::SeqCst);
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    assert_eq!(
        requests.len() - before,
        4,
        "every cooling door must be probed"
    );
    assert!(is_model(requests.last().expect("answering door")));
    upstream.shutdown();
}
