//! TEMPORARY desktop probe #4: quality-variant switch diagnosis.
//! Mirrors the app's shortplay chain on desktop (no device needed):
//!   /api/search -> /api/directory(tab=短剧) -> /api/content (default)
//!   -> /api/content?quality=<variant> for each variant.
//! Reports per-step timing, served url kind (/src/ vs upstream), quality
//! echo, variants, and validates the decrypted cache file header (ftyp).
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
        format!("probe4_{name}"),
        "GET".to_string(),
        path.to_string(),
        query.to_string(),
        Vec::new(),
        timeout_ms,
    )
    .await?;
    let elapsed = t0.elapsed().as_secs_f64();
    write_out(out, name, &resp.body);
    let v: Value = serde_json::from_slice(&resp.body).unwrap_or(Value::Null);
    println!(
        "{name}: http={} bytes={} elapsed={:.1}s code={:?} msg={:?}",
        resp.status,
        resp.body.len(),
        elapsed,
        v.get("code"),
        v.get("message").and_then(|m| m.as_str()),
    );
    Ok(v)
}

/// First string value of `field` found anywhere in `v` (depth-first).
fn first_string_field(v: &Value, field: &str) -> Option<String> {
    match v {
        Value::Object(m) => {
            if let Some(s) = m.get(field).and_then(|x| x.as_str()) {
                return Some(s.to_string());
            }
            for child in m.values() {
                if let Some(s) = first_string_field(child, field) {
                    return Some(s);
                }
            }
            None
        }
        Value::Array(a) => {
            for child in a {
                if let Some(s) = first_string_field(child, field) {
                    return Some(s);
                }
            }
            None
        }
        _ => None,
    }
}

/// The 短剧 tab of a search payload (falls back to the first tab).
fn shortplay_tab<'a>(data: &'a Value) -> Option<&'a Value> {
    let tabs = data.get("search_tabs")?.as_array()?;
    let mut first: Option<&Value> = None;
    for t in tabs {
        let title = t.get("title").and_then(|v| v.as_str()).unwrap_or("");
        if title.contains("短剧") || title.contains("影视") {
            return Some(t);
        }
        if first.is_none() {
            first = Some(t);
        }
    }
    first
}

/// Depth-limited episode-list lookup (same keys as core `find_episode_list`).
fn find_episode_list(value: &Value, depth: usize) -> Vec<Value> {
    if depth > 5 {
        return Vec::new();
    }
    if let Some(m) = value.as_object() {
        for key in ["episodes", "item_data_list", "lists", "item_list"] {
            if let Some(Value::Array(list)) = m.get(key) {
                if !list.is_empty() {
                    return list.clone();
                }
            }
        }
        for nested in m.values() {
            let found = find_episode_list(nested, depth + 1);
            if !found.is_empty() {
                return found;
            }
        }
    }
    if let Some(list) = value.as_array() {
        for item in list {
            if item.as_object().is_some() {
                return list.clone();
            }
        }
    }
    Vec::new()
}

fn url_kind(url: &str) -> &'static str {
    if url.starts_with("/src/") {
        "LOCAL(/src/)"
    } else if url.starts_with("http") {
        "UPSTREAM(http)"
    } else if url.is_empty() {
        "EMPTY"
    } else {
        "OTHER"
    }
}

/// Reports one /api/content result: quality echo, url kind, variants.
fn report_content(tag: &str, v: &Value) -> (String, Vec<String>) {
    let data = v.get("data").cloned().unwrap_or(Value::Null);
    let url = data
        .get("video_url")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let quality = data
        .get("quality")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let variants = data
        .get("variants")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default();
    let names: Vec<String> = variants
        .iter()
        .map(|row| {
            format!(
                "{}(h={},key={})",
                row.get("name").and_then(|x| x.as_str()).unwrap_or("?"),
                row.get("height").and_then(|x| x.as_i64()).unwrap_or(0),
                !row
                    .get("key_hex")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .is_empty()
            )
        })
        .collect();
    println!(
        "{tag}: quality={:?} url_kind={} url_head={}",
        quality,
        url_kind(&url),
        url.chars().take(72).collect::<String>()
    );
    println!("{tag}: variants={:?}", names);
    (url, names)
}

/// Reads the cached file behind a /src/ url and validates its MP4 header.
fn check_src_file(base: &PathBuf, url: &str) {
    let name = url.trim_start_matches("/src/");
    let fp = base.join("runtime").join("src").join(name);
    match std::fs::metadata(&fp) {
        Ok(info) => {
            let mut head = [0u8; 12];
            let valid = std::fs::File::open(&fp)
                .and_then(|mut f| {
                    use std::io::Read;
                    f.read_exact(&mut head)
                })
                .map(|_| &head[4..8] == b"ftyp")
                .unwrap_or(false);
            println!(
                "  cache file {}: {} bytes, header={:?} ftyp_ok={}",
                name,
                info.len(),
                head,
                valid
            );
        }
        Err(e) => println!("  cache file {name}: MISSING ({e})"),
    }
}

#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(
        std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".to_string()),
    );
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
        String::new(),
    )
    .await?;
    println!("init: {started}");

    // 1. Search the series the user was watching.
    let query = std::env::var("FQPROBE_QUERY").unwrap_or_else(|_| "偷听我心声".to_string());
    let search = call(
        "search",
        &out,
        "/api/search",
        &enc(&[("source", "番茄"), ("query", &query), ("page", "1")]),
        60_000,
    )
    .await?;
    let data = search.get("data").cloned().unwrap_or(Value::Null);
    // Real series entries carry a `book_data` object; divider/aggregate cells
    // (book_id like "106") must be skipped.
    let book_id = shortplay_tab(&data)
        .and_then(|t| t.get("data"))
        .and_then(|d| d.as_array())
        .and_then(|rows| {
            rows.iter().find_map(|row| {
                let id = row.get("book_id")?.as_str()?;
                if id.len() >= 15 {
                    Some(id.to_string())
                } else {
                    None
                }
            })
        })
        .or_else(|| first_string_field(&data, "book_id"))
        .unwrap_or_default();
    let book_title = shortplay_tab(&data)
        .and_then(|t| t.get("data"))
        .and_then(|d| d.as_array())
        .and_then(|rows| {
            rows.iter().find_map(|row| {
                row.get("book_data")
                    .and_then(|b| b.get("book_name"))
                    .and_then(|x| x.as_str())
                    .map(String::from)
            })
        })
        .unwrap_or_default();
    if book_id.is_empty() {
        println!("no book_id found for query {query:?}; abort");
        api::shutdown().await?;
        return Ok(());
    }
    println!("series: book_id={book_id} title={}", escape(&book_title));

    // 2. Episode list (tab=短剧, same call the app makes).
    let dir = call(
        "directory",
        &out,
        "/api/directory",
        &enc(&[("source", "番茄"), ("book_id", &book_id), ("tab", "短剧")]),
        60_000,
    )
    .await?;
    let dir_data = dir.get("data").cloned().unwrap_or(Value::Null);
    let episodes = find_episode_list(&dir_data, 0);
    println!("episodes: {}", episodes.len());
    if episodes.is_empty() {
        println!("no episodes; abort");
        api::shutdown().await?;
        return Ok(());
    }
    let ep = &episodes[0];
    let ep_id = ["item_id", "video_id", "chapter_id", "id"]
        .iter()
        .find_map(|k| ep.get(*k).and_then(|x| x.as_str()).map(String::from))
        .unwrap_or_default();
    let ep_title = ["title", "chapter_title", "name"]
        .iter()
        .find_map(|k| ep.get(*k).and_then(|x| x.as_str()).map(String::from))
        .unwrap_or_default();
    if ep_id.is_empty() {
        println!("episode has no id; keys={:?}", ep.as_object().map(|m| m.keys().collect::<Vec<_>>()));
        api::shutdown().await?;
        return Ok(());
    }
    println!("episode: id={ep_id} title={}", escape(&ep_title));

    // 3. Default load (no quality), exactly like the app's initial load.
    let v0 = call(
        "content_default",
        &out,
        "/api/content",
        &enc(&[("source", "番茄"), ("item_id", &ep_id), ("tab", "短剧")]),
        600_000,
    )
    .await?;
    let (url0, names) = report_content("default", &v0);
    if url0.starts_with("/src/") {
        check_src_file(&base, &url0);
    }

    // 4. Per-variant loads (the quality-switch path under test).
    for name in names.iter().take(3) {
        let q = name.split('(').next().unwrap_or("").to_string();
        if q.is_empty() {
            continue;
        }
        let tag = format!("quality[{q}]");
        let vq = call(
            &format!("content_{q}"),
            &out,
            "/api/content",
            &enc(&[
                ("source", "番茄"),
                ("item_id", &ep_id),
                ("tab", "短剧"),
                ("quality", &q),
            ]),
            600_000,
        )
        .await?;
        let (urlq, _) = report_content(&tag, &vq);
        if urlq.starts_with("/src/") {
            check_src_file(&base, &urlq);
        }
    }

    api::shutdown().await?;
    println!("done");
    Ok(())
}

fn escape(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_graphic() || c == ' ' { c } else { '?' }).collect()
}
