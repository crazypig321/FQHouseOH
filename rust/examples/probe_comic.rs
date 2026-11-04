//! TEMPORARY desktop probe: comic chapter loading diagnosis.
//! Mirrors the app's manga chain on desktop:
//!   /api/directory (tab=漫画) -> /api/content?cmd=1 (chapter images).
//! Reports per-step http status, code/message, and image count so a
//! chapter that fails to load shows its exact upstream answer.
//! Not part of the shipping app; delete after use.

use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;
use std::time::Instant;

fn write_out(out: &PathBuf, name: &str, body: &[u8]) {
    let file = out.join(format!("{}.json", name));
    std::fs::write(&file, body).unwrap_or_else(|e| panic!("write {name}: {e}"));
}

fn enc(pairs: &[(&str, &str)]) -> String {
    let mut ser = url::form_urlencoded::Serializer::new(String::new());
    for (k, v) in pairs {
        ser.append_pair(k, v);
    }
    ser.finish()
}

async fn call(
    name: &str,
    out: &PathBuf,
    path: &str,
    query: &str,
    timeout_ms: i64,
) -> Result<Value, String> {
    let t0 = Instant::now();
    let resp = api::request(
        format!("comic_{name}"),
        "GET".to_string(),
        path.to_string(),
        query.to_string(),
        Vec::new(),
        timeout_ms,
    )
    .await?;
    let elapsed = t0.elapsed().as_secs_f64();
    write_out(out, name, &resp.body);
    let head = String::from_utf8_lossy(&resp.body[..resp.body.len().min(400)]).into_owned();
    let v: Value = serde_json::from_slice(&resp.body).unwrap_or(Value::Null);
    println!(
        "{name}: http={} bytes={} elapsed={:.1}s code={:?} msg={:?}",
        resp.status,
        resp.body.len(),
        elapsed,
        v.get("code"),
        v.get("message").and_then(|m| m.as_str()),
    );
    println!("{name}: body_head={}", head.replace('\n', " "));
    Ok(v)
}

#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(
        std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".to_string()),
    );
    let runtime = base.join("backend");
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
        String::new(),
    )
    .await?;
    println!("init: {started}");

    let book_id = std::env::var("FQPROBE_BOOK_ID")
        .unwrap_or_else(|_| "7631537718241020990".to_string());

    // 1. Directory (tab=漫画), exactly like the app's ComicPage load.
    let dir = call(
        "dir",
        &out,
        "/api/directory",
        &enc(&[
            ("source", "番茄"),
            ("book_id", &book_id),
            ("tab", "漫画"),
        ]),
        60_000,
    )
    .await?;
    let data = dir.get("data").cloned().unwrap_or(Value::Null);
    let mut item_ids: Vec<String> = Vec::new();
    if let Some(list) = data.get("item_data_list").and_then(|x| x.as_array()) {
        for row in list {
            if let Some(id) = row.get("item_id").and_then(|x| x.as_str()) {
                item_ids.push(id.to_string());
            }
        }
    }
    println!("directory: item_count={}", item_ids.len());

    // 2. Chapter images for the first few chapters (the app's
    //    /api/content?tab=漫画&cmd=1 call).
    let probe_items = std::env::var("FQPROBE_ITEMS").ok();
    let items: Vec<String> = match probe_items {
        Some(raw) => raw.split(',').map(|s| s.trim().to_string()).collect(),
        None => item_ids.iter().take(3).cloned().collect(),
    };
    if items.is_empty() {
        println!("no item ids to probe; abort");
        api::shutdown().await?;
        return Ok(());
    }
    for (i, item_id) in items.iter().enumerate() {
        let v = call(
            &format!("content_{i}"),
            &out,
            "/api/content",
            &enc(&[
                ("source", "番茄"),
                ("item_id", item_id),
                ("tab", "漫画"),
                ("cmd", "1"),
            ]),
            120_000,
        )
        .await?;
        let d = v.get("data").cloned().unwrap_or(Value::Null);
        let images = d.get("images").and_then(|x| x.as_array()).map(|a| a.len());
        let content = d.get("content").and_then(|x| x.as_str()).map(|s| {
            format!("{} bytes, head={:?}", s.len(), s.chars().take(60).collect::<String>())
        });
        println!(
            "chapter[{i}] item_id={item_id}: images={:?} content={:?}",
            images, content
        );
    }

    api::shutdown().await?;
    println!("done");
    Ok(())
}
