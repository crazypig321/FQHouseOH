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

fn is_tab(request: &common::Recorded) -> bool {
    request.path == TAB_PATH
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
async fn an_empty_v5_body_falls_back_to_the_signed_video_tab_door_on_the_same_identity() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if is_v5(request) {
            MockReply::status(200)
        } else {
            MockReply::json(tab_body())
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
        3,
        "v5, its single re-probe, then one video_tab door"
    );
    assert!(is_v5(&requests[0]) && requests[0].method == "POST");
    assert!(
        is_v5(&requests[1]) && requests[1].method == "POST",
        "the re-probe stays on the v5 door"
    );
    assert!(is_tab(&requests[2]) && requests[2].method == "GET");
    assert_eq!(
        device_of(&requests[0]),
        device_of(&requests[1]),
        "the re-probe must reuse the identity that just answered"
    );
    assert_eq!(
        device_of(&requests[0]),
        device_of(&requests[2]),
        "the fallback door must be asked under the same identity"
    );
    for header in ["x-medusa", "x-helios", "x-khronos"] {
        assert!(
            requests[2].header(header).is_some(),
            "the fallback door must carry the player signature header {header}"
        );
    }
    assert!(
        requests[2].header("x-ss-stub").is_none(),
        "a body-less GET must not claim a body digest"
    );

    let query = query_map(&requests[2].query);
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
async fn a_rejected_video_tab_model_is_not_treated_as_a_playable_answer() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|request| {
        if is_v5(request) {
            MockReply::status(200)
        } else {
            MockReply::json(json!({"code": 100103, "data": {}}))
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
            .all(|request| is_v5(request) || is_tab(request)),
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
        second, 1,
        "every door is parked, so one probe is the whole request; a second \
         rotation would add another round"
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
    assert_eq!(first, 3, "v5 empty, its re-probe, then the video_tab door");

    // Second request: the parked v5 door must not be retried before its cooldown.
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let second: Vec<_> = upstream.requests().into_iter().skip(first).collect();
    assert!(!second.is_empty());
    assert!(
        second.iter().all(is_tab),
        "a parked empty door must be skipped, not retried"
    );
    upstream.shutdown();
}
