//! TEMPORARY desktop probe: does the fq video_model chain (shortplay aid=1967
//! primary + phoenix multi_video_model aid=8662 auxiliary) resolve a hongguo
//! vid from PC, with the exact call the app makes?
//!   GET /api/content?source=番茄&item_id=<vid>&tab=短剧&mode=stream
//! Usage: cargo run --example probe_hgvideo -- [vid] [quality]
//! Env: FQPROBE_DIR (work dir). Not part of the shipping app; delete after use.

use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;
use std::time::Instant;

#[tokio::main]
async fn main() -> Result<(), String> {
    let vid = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "7704898887718292504".to_string());
    let quality = std::env::args().nth(2).unwrap_or_default();

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

    let mut query = format!(
        "source={}&item_id={}&tab={}&mode=stream",
        percent_encoding::utf8_percent_encode("番茄", percent_encoding::NON_ALPHANUMERIC),
        vid,
        percent_encoding::utf8_percent_encode("短剧", percent_encoding::NON_ALPHANUMERIC),
    );
    if !quality.is_empty() {
        query.push_str(&format!("&quality={quality}"));
    }

    let t0 = Instant::now();
    let resp = api::request(
        "probe_hgvideo".to_string(),
        "GET".to_string(),
        "/api/content".to_string(),
        query,
        Vec::new(),
        60_000,
    )
    .await?;
    let elapsed = t0.elapsed().as_secs_f64();
    let file = out.join(format!("hgvideo_{vid}.json"));
    std::fs::write(&file, &resp.body).unwrap_or_else(|e| panic!("write: {e}"));
    let v: Value = serde_json::from_slice(&resp.body).unwrap_or(Value::Null);
    println!(
        "http={} bytes={} elapsed={:.1}s file={}",
        resp.status,
        resp.body.len(),
        elapsed,
        file.display()
    );
    println!("code={:?} message={:?}", v.get("code"), v.get("message"));
    let data = v.get("data").cloned().unwrap_or(Value::Null);
    let url = data.get("video_url").and_then(|x| x.as_str()).unwrap_or("");
    println!("video_url_head={}", &url.chars().take(110).collect::<String>());
    println!(
        "quality={:?} key_len={:?} variants={:?} vertical={:?}",
        data.get("quality").and_then(|x| x.as_str()),
        data
            .get("key_hex")
            .and_then(|x| x.as_str())
            .map(|s| s.len() / 2),
        data.get("variants").and_then(|x| x.as_array()).map(|a| a.len()),
        data.get("vertical"),
    );
    if let Some(Value::Array(variants)) = data.get("variants") {
        for row in variants {
            println!(
                "  variant name={:?} url_head={}",
                row.get("name").and_then(|x| x.as_str()),
                row.get("url")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .chars()
                    .take(80)
                    .collect::<String>()
            );
        }
    }
    if url.is_empty() {
        println!("--- body head ---");
        println!(
            "{}",
            String::from_utf8_lossy(&resp.body)
                .chars()
                .take(600)
                .collect::<String>()
        );
    }
    api::shutdown().await?;
    Ok(())
}
