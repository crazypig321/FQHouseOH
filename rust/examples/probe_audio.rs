//! TEMPORARY desktop probe #6: online TTS listening "电流音" diagnosis.
//! Mirrors the app's audiobook chain on desktop (no device needed):
//!   /api/search (小说) -> /api/directory (tab=小说)
//!   -> /api/v1/books/{id}/tones (first tts tone, fallback 0)
//!   -> /api/v1/audio/books/{id}/chapters/{ch}?tone_id&mode=download
//! Reports the URL the app would receive (/src/ 明文 vs CDN 密文),
//! per-stream encrypt_info (encrypt/method/spade_a), and validates the
//! decrypted cache file header. Not part of the shipping app; delete after use.

use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;
use std::time::Instant;

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
        format!("probe6_{name}"),
        "GET".to_string(),
        path.to_string(),
        query.to_string(),
        Vec::new(),
        timeout_ms,
    )
    .await?;
    let elapsed = t0.elapsed().as_secs_f64();
    let file = out.join(format!("{}.json", name));
    std::fs::write(&file, &resp.body).unwrap_or_else(|e| panic!("write {name}: {e}"));
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
                    return Some(s.to_string());
                }
            }
            None
        }
        Value::Array(a) => {
            for child in a {
                if let Some(s) = first_string_field(child, field) {
                    return Some(s.to_string());
                }
            }
            None
        }
        _ => None,
    }
}

/// The 小说 tab of a search payload (falls back to the first tab).
fn novel_tab<'a>(data: &'a Value) -> Option<&'a Value> {
    let tabs = data.get("search_tabs")?.as_array()?;
    let mut first: Option<&Value> = None;
    for t in tabs {
        let title = t.get("title").and_then(|v| v.as_str()).unwrap_or("");
        if title.contains("小说") || title.contains("书籍") {
            return Some(t);
        }
        if first.is_none() {
            first = Some(t);
        }
    }
    first
}

/// Depth-limited chapter-list lookup (same keys as probe_quality).
fn find_episode_list(value: &Value, depth: usize) -> Vec<Value> {
    if depth > 5 {
        return Vec::new();
    }
    if let Some(m) = value.as_object() {
        for key in [
            "episodes",
            "item_data_list",
            "lists",
            "item_list",
            "chapter_list_with_part",
            "catalog",
        ] {
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

/// First non-empty id under any `tts_tones` array (fallback: "0").
fn first_tts_tone(v: &Value) -> String {
    fn walk(v: &Value, out: &mut Option<String>) {
        if out.is_some() {
            return;
        }
        match v {
            Value::Object(m) => {
                if let Some(Value::Array(tones)) = m.get("tts_tones") {
                    for tone in tones {
                        let id = match tone.get("id") {
                            Some(Value::Number(n)) => n.to_string(),
                            Some(Value::String(s)) => s.clone(),
                            _ => String::new(),
                        };
                        if !id.is_empty() {
                            *out = Some(id);
                            return;
                        }
                    }
                }
                for child in m.values() {
                    walk(child, out);
                }
            }
            Value::Array(a) => {
                for child in a {
                    walk(child, out);
                }
            }
            _ => {}
        }
    }
    let mut found: Option<String> = None;
    walk(v, &mut found);
    found.unwrap_or_else(|| "0".to_string())
}

/// Reports one /audio playinfo row: model fields + per-stream encryption.
/// Returns the URL the app would pick (fqModelAudioUrl semantics).
fn report_row(tag: &str, row: &Value) -> Option<String> {
    let item_id = row.get("item_id").and_then(|v| v.as_str()).unwrap_or("");
    println!("{tag}: row item_id={item_id}");
    let raw_model = row
        .get("video_model")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if raw_model.is_empty() {
        println!(
            "{tag}:   no video_model; row keys={:?}",
            row.as_object().map(|m| m.keys().collect::<Vec<_>>())
        );
        return None;
    }
    let model: Value = match serde_json::from_str(raw_model) {
        Ok(v) => v,
        Err(e) => {
            println!("{tag}:   video_model JSON decode failed: {e}");
            return None;
        }
    };
    let media_type = model
        .get("media_type")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let duration = model
        .get("video_duration")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    println!("{tag}:   media_type={media_type:?} duration={duration:.1}s");
    let mut candidates: Vec<String> = Vec::new();
    if let Some(Value::Array(list)) = model.get("video_list") {
        for (i, stream) in list.iter().enumerate() {
            let main = stream
                .get("main_url")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let enc = stream.get("encrypt_info");
            let (encrypt, method, spade_len, has_key_hex) = match enc {
                Some(Value::Object(e)) => (
                    e.get("encrypt").and_then(|v| v.as_bool()).unwrap_or(false),
                    e.get("encryption_method")
                        .and_then(|v| v.as_str())
                        .unwrap_or(""),
                    e.get("spade_a")
                        .and_then(|v| v.as_str())
                        .map(|s| s.len())
                        .unwrap_or(0),
                    e.get("key_hex")
                        .and_then(|v| v.as_str())
                        .map(|s| !s.is_empty())
                        .unwrap_or(false),
                ),
                _ => (false, "", 0, false),
            };
            println!(
                "{tag}:   video_list[{i}]: url_kind={} encrypt={} method={:?} spade_a_len={} key_hex={} url_head={}",
                url_kind(main),
                encrypt,
                method,
                spade_len,
                has_key_hex,
                main.chars().take(72).collect::<String>()
            );
            if !main.is_empty() {
                candidates.push(main.to_string());
            }
        }
    }
    if candidates.is_empty() {
        println!("{tag}:   no stream urls in model");
        return None;
    }
    // fqModelAudioUrl: prefer the row's own main_url when it matches a candidate.
    let row_url = row.get("main_url").and_then(|v| v.as_str()).unwrap_or("");
    if !row_url.is_empty() {
        for c in &candidates {
            if c == row_url {
                return Some(c.clone());
            }
        }
    }
    Some(candidates[0].clone())
}

/// Reads the cache file behind a /src/ url: size, header bytes, ftyp check.
fn check_src_file(base: &PathBuf, url: &str) {
    let name = url.trim_start_matches("/src/");
    let fp = base.join("runtime").join("src").join(name);
    match std::fs::metadata(&fp) {
        Ok(info) => {
            let mut head = [0u8; 16];
            let read = std::fs::File::open(&fp)
                .and_then(|mut f| {
                    use std::io::Read;
                    f.read_exact(&mut head)
                })
                .is_ok();
            let ftyp_ok = read && &head[4..8] == b"ftyp";
            println!(
                "  cache file {}: {} bytes, header={:02x?} ascii={:?} ftyp_ok={}",
                name,
                info.len(),
                head,
                String::from_utf8_lossy(&head[..8.min(head.len())]),
                ftyp_ok
            );
            if ftyp_ok {
                // 采样一致性粗检：打印 mdat 前后 16 字节，供人工比对熵。
                if let Ok(data) = std::fs::read(&fp) {
                    if let Some(pos) = find_mdat(&data) {
                        let s = pos.min(data.len().saturating_sub(16));
                        println!("  mdat@{} head16={:02x?}", pos, &data[s..s + 16]);
                    }
                }
            }
        }
        Err(e) => println!("  cache file {name}: MISSING ({e})"),
    }
}

fn find_mdat(data: &[u8]) -> Option<usize> {
    data.windows(4).position(|w| w == b"mdat")
}

#[tokio::main]
async fn main() -> Result<(), String> {
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

    // 1. Search the novel the user listens to.
    let query = std::env::var("FQPROBE_QUERY").unwrap_or_else(|_| "大奉打更人".to_string());
    let search = call(
        "audio_search",
        &out,
        "/api/search",
        &enc(&[("source", "番茄"), ("query", &query), ("page", "1")]),
        60_000,
    )
    .await?;
    let data = search.get("data").cloned().unwrap_or(Value::Null);
    let book_id = novel_tab(&data)
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
    if book_id.is_empty() {
        println!("no book_id found for query {query:?}; abort");
        api::shutdown().await?;
        return Ok(());
    }
    println!("novel: book_id={book_id}");

    // 2. Chapter list (tab=小说, same call the app makes).
    let dir = call(
        "audio_directory",
        &out,
        "/api/directory",
        &enc(&[("source", "番茄"), ("book_id", &book_id), ("tab", "小说")]),
        60_000,
    )
    .await?;
    let dir_data = dir.get("data").cloned().unwrap_or(Value::Null);
    let chapters = find_episode_list(&dir_data, 0);
    println!("chapters: {}", chapters.len());
    if chapters.is_empty() {
        println!("no chapters; abort");
        api::shutdown().await?;
        return Ok(());
    }
    let ch = &chapters[0];
    let item_id = ["item_id", "chapter_id", "video_id", "id"]
        .iter()
        .find_map(|k| ch.get(*k).and_then(|x| x.as_str()).map(String::from))
        .unwrap_or_default();
    if item_id.is_empty() {
        println!(
            "chapter has no id; keys={:?}",
            ch.as_object().map(|m| m.keys().collect::<Vec<_>>())
        );
        api::shutdown().await?;
        return Ok(());
    }
    println!("chapter: item_id={item_id}");

    // 3. Tones: first tts tone (fallback 0).
    let tones = call(
        "audio_tones",
        &out,
        &format!("/api/v1/books/{book_id}/tones"),
        "",
        60_000,
    )
    .await?;
    let tone = first_tts_tone(&tones);
    println!("tone: {tone}");

    // 4. The exact call the app makes (mode=download -> 后端整章下载解密).
    let play = call(
        "audio_play",
        &out,
        &format!("/api/v1/audio/books/{book_id}/chapters/{item_id}"),
        &enc(&[("tone_id", &tone), ("mode", "download")]),
        600_000,
    )
    .await?;

    // 5. Report what the app would receive and play.
    let mut final_url: Option<String> = None;
    if let Some(Value::Array(rows)) = play.get("data") {
        for (i, row) in rows.iter().enumerate() {
            let tag = format!("row[{i}]");
            match report_row(&tag, row) {
                Some(url) => {
                    if final_url.is_none() {
                        final_url = Some(url);
                    }
                }
                None => {}
            }
        }
    } else {
        println!(
            "play payload has no data[] array; top keys={:?}",
            play.as_object().map(|m| m.keys().collect::<Vec<_>>())
        );
    }
    match final_url {
        Some(url) => {
            println!(
                "APP URL: kind={} {}",
                url_kind(&url),
                url.chars().take(96).collect::<String>()
            );
            if url.starts_with("/src/") {
                println!("decrypt path OK (loopback 明文)");
                check_src_file(&base, &url);
                // 6. Fetch the file THROUGH the serve path (exactly what
                // avPlayer receives over http) and validate the bytes.
                let resp = api::request(
                    "probe6_serve".to_string(),
                    "GET".to_string(),
                    url.clone(),
                    String::new(),
                    Vec::new(),
                    600_000,
                )
                .await?;
                println!(
                    "serve: http={} content_type={} bytes={}",
                    resp.status,
                    resp.content_type,
                    resp.body.len()
                );
                let served = out.join("served_decrypted.m4a");
                std::fs::write(&served, &resp.body).map_err(|e| e.to_string())?;
                println!("served bytes saved to {}", served.display());
            } else if url.starts_with("http") {
                println!("!! CDN URL served with mode=download — decrypt not applied; app would play encrypted stream");
            }
        }
        None => println!("APP URL: none parsed — check out/audio_play.json"),
    }

    api::shutdown().await?;
    println!("done");
    Ok(())
}
