//! mode=download 听书供流链路：playinfo → 整章下载解密 → loopback
//! `/src/` 明文改写。ohos 的 mpv 解不了 CENC 密文（真机日志：起播
//! 13ms 即停），靠该模式拿明文；Android 不传 mode，契约保持
//! CDN + key_hex（`without_mode_the_cdn_source_contract_is_unchanged`）。
//! 上游与媒体文件全部由本地 mock 提供，不触网、不碰真实设备池。

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

const BOOK_ID: &str = "7181453438667096588";
const SPADE_A: &str = "nbwTwF23F/5phBHDb4Qjz3KBC/lBtzrJcLI4y2qGEc9dhRWhoQ==";
const KEY_HEX: &str = "0f7a32fda0f04388ba27cf1d0a95b024";
const CDN_URL: &str = "https://example.invalid/chapter.m4a";

fn playinfo_body() -> Value {
    let model = json!({
        "status": 10,
        "media_type": "audio",
        "video_duration": 229.96,
        "video_list": [{
            "main_url": CDN_URL,
            "backup_url": "https://example.invalid/chapter.m4b",
            "encrypt_info": {
                "encrypt": true,
                "spade_a": SPADE_A,
                "encryption_method": "cenc-aes-ctr"
            }
        }]
    });
    json!({
        "data": [{
            "item_id": BOOK_ID,
            "main_url": CDN_URL,
            "video_model": model.to_string()
        }]
    })
}

async fn request_chapter(server: &Server, query: &str) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: format!("/api/v1/audio/books/{BOOK_ID}/chapters/{BOOK_ID}"),
            query: query.to_string(),
            body: Vec::new(),
            headers: Vec::new(),
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

fn model_of(body: &Value) -> Value {
    serde_json::from_str(body["data"][0]["video_model"].as_str().expect("model"))
        .expect("model json")
}

#[tokio::test]
async fn download_mode_rewrites_the_encrypted_stream_to_a_local_plain_source() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/chapter.m4a" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"audio fixture".to_vec(),
            };
        }
        MockReply::json(playinfo_body())
    })
    .await;
    let dir = TempDir::new("audio-download-mode");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_chapter(&server, "mode=download&tone_id=0").await;
    assert_eq!(status, 200, "{body}");

    // 缓存文件名带章节与音色，扩展名沿用 CDN URL 的 .m4a。
    let row = &body["data"][0];
    assert_eq!(row["main_url"], format!("/src/{BOOK_ID}_0.m4a"));
    let model = model_of(&body);
    let stream = &model["video_list"][0];
    assert_eq!(stream["main_url"], format!("/src/{BOOK_ID}_0.m4a"));
    assert!(
        stream.get("encrypt_info").is_none(),
        "明文流必须剥掉 encrypt_info，Dart 才回空 keyHex"
    );
    assert_eq!(
        std::fs::read(dir.join("src").join(format!("{BOOK_ID}_0.m4a"))).unwrap(),
        b"audio fixture"
    );

    // 第二次请求命中缓存：不重复下载。
    let (status, body) = request_chapter(&server, "mode=download&tone_id=0").await;
    assert_eq!(status, 200, "{body}");
    let media_fetches = upstream
        .requests()
        .iter()
        .filter(|r| r.path == "/chapter.m4a")
        .count();
    assert_eq!(media_fetches, 1, "重复请求必须命中 src/ 缓存");
}

#[tokio::test]
async fn without_mode_the_cdn_source_contract_is_unchanged() {
    let upstream = MockUpstream::start(|req| {
        if req.path.ends_with(".m4a") {
            return MockReply::status(500);
        }
        MockReply::json(playinfo_body())
    })
    .await;
    let dir = TempDir::new("audio-cdn-contract");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_chapter(&server, "tone_id=0").await;
    assert_eq!(status, 200, "{body}");
    // Android 契约：外层地址保持 CDN，key_hex 已由 patch_playinfo_keys 注入，
    // 且不发起媒体下载。
    let row = &body["data"][0];
    assert_eq!(row["main_url"], CDN_URL);
    let model = model_of(&body);
    assert_eq!(model["video_list"][0]["main_url"], CDN_URL);
    assert_eq!(
        model["video_list"][0]["encrypt_info"]["key_hex"], KEY_HEX,
        "Android 原生播放器靠 key_hex 解 CENC，不能丢"
    );
    assert!(
        upstream
            .requests()
            .iter()
            .all(|r| !r.path.ends_with(".m4a")),
        "无 mode 时不得下载媒体文件"
    );
}

#[tokio::test]
async fn download_failure_keeps_the_cdn_key_hex_fallback() {
    let upstream = MockUpstream::start(|req| {
        if req.path.ends_with(".m4a") {
            return MockReply::status(500);
        }
        MockReply::json(playinfo_body())
    })
    .await;
    let dir = TempDir::new("audio-download-fallback");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_chapter(&server, "mode=download&tone_id=0").await;
    assert_eq!(status, 200, "{body}");
    // 下载失败只退回 CDN+key_hex，不报错：行为与未加 download 分支前一致。
    let row = &body["data"][0];
    assert_eq!(row["main_url"], CDN_URL);
    let model = model_of(&body);
    assert_eq!(model["video_list"][0]["main_url"], CDN_URL);
    assert_eq!(model["video_list"][0]["encrypt_info"]["key_hex"], KEY_HEX);
}
