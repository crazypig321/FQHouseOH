//! TEMPORARY desktop probe: does the rust hongguo player-sign chain still
//! reach the hongguo App API (search endpoint) from PC?
//!   GET /api/v1/hongguo/map?series_id=123&title=<title>
//! Usage: cargo run --example probe_hgmap -- [title]
//! Env: FQPROBE_DIR. Not part of the shipping app; delete after use.

use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;
use std::time::Instant;

#[tokio::main]
async fn main() -> Result<(), String> {
    let title = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "我在八零年代当后妈".to_string());

    let base = PathBuf::from(std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".to_string()));
    let runtime = base.join("runtime");
    std::fs::create_dir_all(&runtime).map_err(|e| e.to_string())?;
    let out = base.join("out");
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;

    let started = api::init(
        base.join("backend")
            .join("config")
            .join("config.json")
            .to_string_lossy()
            .into_owned(),
        base.join("pool.json").to_string_lossy().into_owned(),
        base.join("backend")
            .join("config")
            .join("filter.json")
            .to_string_lossy()
            .into_owned(),
        runtime.to_string_lossy().into_owned(),
        0,
        false,
        String::new(),
    )
    .await?;
    println!("init: {started}");

    let query = format!(
        "series_id=123&title={}",
        percent_encoding::utf8_percent_encode(&title, percent_encoding::NON_ALPHANUMERIC)
    );
    let t0 = Instant::now();
    let resp = api::request(
        "probe_hgmap".to_string(),
        "GET".to_string(),
        "/api/v1/hongguo/map".to_string(),
        query,
        Vec::new(),
        60_000,
    )
    .await?;
    let elapsed = t0.elapsed().as_secs_f64();
    let file = out.join("hgmap.json");
    std::fs::write(&file, &resp.body).unwrap_or_else(|e| panic!("write: {e}"));
    let v: Value = serde_json::from_slice(&resp.body).unwrap_or(Value::Null);
    println!(
        "http={} bytes={} elapsed={:.1}s file={}",
        resp.status,
        resp.body.len(),
        elapsed,
        file.display()
    );
    println!(
        "matched={:?} hongguo_series_id={:?} title={:?} episode_count={:?}",
        v.get("matched"),
        v.get("hongguo_series_id"),
        v.get("title"),
        v.get("episode_count"),
    );
    if resp.status != 200 {
        println!(
            "{}",
            String::from_utf8_lossy(&resp.body)
                .chars()
                .take(400)
                .collect::<String>()
        );
    }
    api::shutdown().await?;
    Ok(())
}
