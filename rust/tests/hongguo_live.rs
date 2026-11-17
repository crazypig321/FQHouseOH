//! 红果真实上游冒烟测试（map → danmaku → media 全链路）。
//!
//! 默认不跑（`#[ignore]`），只在联调时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test hongguo_live -- --ignored --nocapture
//! ```
//!
//! 黄金向量只能证明「签名实现与参考一致」；这条链路验证另一半：
//! 设备池、官网搜索、网页详情、comment 签名弹幕、V5 取流
//! （`sign::v5` + `multi_video_model/player/v1`）是否被服务端逐段接受。
//! 剧名用阶段 2 验证实测过的《宴律，你的白月光回国了》。

mod common;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;

/// 番茄侧 series_id 只作缓存键，不参与上游请求；占位数字即可。
const FANQIE_SERIES_ID: &str = "7123456789012345678";
const TITLE: &str = "宴律，你的白月光回国了";

#[tokio::test]
#[ignore = "hits the live hongguo upstream"]
async fn live_map_matches_series_and_lists_vids() {
    let dir = TempDir::new("hongguo-live");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    let map = srv.handler("hongguo_map").expect("route");
    let params = Params::from_pairs(vec![
        ("series_id".to_string(), FANQIE_SERIES_ID.to_string()),
        ("title".to_string(), TITLE.to_string()),
    ]);
    let value = map(&srv.ctx, &params).await.expect("live map must succeed");
    assert_eq!(value["matched"], true, "map result: {value}");
    let vids = value["vids"].as_array().expect("vids");
    println!(
        "map: hongguo_series_id={} title={} episode_count={}",
        value["hongguo_series_id"], value["title"], value["episode_count"]
    );
    assert!(!vids.is_empty(), "vids must not be empty");
    assert!(
        vids.len() as i64 == value["episode_count"].as_i64().unwrap_or(-1),
        "episode_count must match vids"
    );
}

#[tokio::test]
#[ignore = "hits the live hongguo upstream"]
async fn live_danmaku_for_mapped_series() {
    let dir = TempDir::new("hongguo-live-danmaku");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    // 映射拿红果 series_id + 第 1 集 vid（进程内缓存，命中上面的注册设备）。
    let map = srv.handler("hongguo_map").expect("route");
    let params = Params::from_pairs(vec![
        ("series_id".to_string(), FANQIE_SERIES_ID.to_string()),
        ("title".to_string(), TITLE.to_string()),
    ]);
    let value = map(&srv.ctx, &params).await.expect("live map must succeed");
    let hongguo_series_id = value["hongguo_series_id"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let vid = value["vids"][0].as_str().unwrap_or_default().to_string();
    assert!(!hongguo_series_id.is_empty() && !vid.is_empty(), "map: {value}");

    // 短剧单集约 1-3 分钟：取 2 分钟窗口、30 秒进度，命中中段弹幕密度。
    let danmaku = srv.handler("hongguo_danmaku").expect("route");
    let params = Params::from_pairs(vec![
        ("series_id".to_string(), hongguo_series_id.clone()),
        ("vid".to_string(), vid.clone()),
        ("start_offset_time".to_string(), "30000".to_string()),
        ("playlet_item_duration".to_string(), "120".to_string()),
    ]);
    let value = danmaku(&srv.ctx, &params)
        .await
        .expect("live danmaku must succeed");
    // 响应结构与番茄弹幕同构（fqParseDanmaku 直接解析）：
    // data.data_list[].comment.common.content.text + comment.expand.offset_time。
    let comments = value["data"]["data_list"]
        .as_array()
        .map(|a| a.len())
        .unwrap_or(0);
    println!(
        "danmaku: series={} vid={} comments={}",
        hongguo_series_id, vid, comments
    );
    assert!(comments > 0, "danmaku data_list must not be empty: {value}");
}

#[tokio::test]
#[ignore = "hits the live hongguo upstream"]
async fn live_media_resolves_cdn_url_via_v5() {
    let dir = TempDir::new("hongguo-live-media");
    // V5 取流要真注册设备：夹具设备的 id 不在服务端注册表里，服务端
    // 会以 200 + 空 body 静默拒绝，所以现场注册一台再组池。
    let registrar = fqapi_core::device::register::Registrar::new().expect("registrar");
    let dev = registrar.register().await.expect("register a real device");
    println!(
        "registered: device_id={} install_id={}",
        dev.device_id, dev.install_id
    );
    let pool = serde_json::json!({
        "android": [dev],
        "last_update": "2026-01-01 00:00:00",
    })
    .to_string();
    let srv = build_server(&dir, None, &[], &[], &pool).await;

    // 映射拿第 1 集 vid，再走 V5 取流（kotlin-tv MobilePlayback.ladder，
    // 设备池匿名身份 + sign::v5）验证服务端接受整条播放链路。
    let map = srv.handler("hongguo_map").expect("route");
    let params = Params::from_pairs(vec![
        ("series_id".to_string(), FANQIE_SERIES_ID.to_string()),
        ("title".to_string(), TITLE.to_string()),
    ]);
    let value = map(&srv.ctx, &params).await.expect("live map must succeed");
    let hongguo_series_id = value["hongguo_series_id"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let vid = value["vids"][0].as_str().unwrap_or_default().to_string();
    assert!(!hongguo_series_id.is_empty() && !vid.is_empty(), "map: {value}");

    let media = srv.handler("hongguo_native_media").expect("route");
    let chapter = serde_json::json!({
        "id": format!("hongguo:{hongguo_series_id}:{vid}"),
        "title": "第1集",
        "videoUrl": format!("hongguo-cenc://{vid}"),
    });
    let params = Params::from_pairs(vec![
        (
            "drama_id".to_string(),
            format!("hongguo:{hongguo_series_id}:{vid}"),
        ),
        ("chapter".to_string(), chapter.to_string()),
        ("quality".to_string(), "0".to_string()),
    ]);
    let value = media(&srv.ctx, &params)
        .await
        .expect("live media must succeed");
    let url = value["url"].as_str().unwrap_or_default();
    let qualities = value["qualities"].as_array().map(|a| a.len()).unwrap_or(0);
    println!(
        "media: quality={} qualities={} key_len={} url_head={}",
        value["quality"],
        qualities,
        value["decryptionKey"].as_str().unwrap_or_default().len() / 2,
        url.chars().take(90).collect::<String>()
    );
    assert!(
        url.starts_with("https://") || url.starts_with("http://"),
        "media url must be a CDN address: {value}"
    );
    assert!(qualities > 0, "media qualities must not be empty: {value}");
}

#[tokio::test]
#[ignore = "hits the live hongguo upstream"]
async fn live_catalog_lists_short_play_and_comic() {
    let dir = TempDir::new("hongguo-live-catalog");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    // 官网改版后两条目录路径：短剧 /category（loaderData 带 recommendList 的
    // 页对象）与漫剧 App 搜索 → rank 回退（loaderData["rank_*/page"].content）。
    let catalog = srv.handler("hongguo_native_catalog").expect("route");
    for category in ["short_play", "comic_series"] {
        let params = Params::from_pairs(vec![
            ("source".to_string(), "hongguo".to_string()),
            ("category".to_string(), category.to_string()),
            ("page".to_string(), "1".to_string()),
        ]);
        let value = catalog(&srv.ctx, &params)
            .await
            .unwrap_or_else(|e| panic!("live {category} catalog must succeed: {e}"));
        let items = value["items"].as_array().map(|a| a.len()).unwrap_or(0);
        println!(
            "catalog {category}: items={} hasMore={}",
            items, value["hasMore"]
        );
        assert!(items > 0, "live {category} catalog must list items: {value}");
    }
}
