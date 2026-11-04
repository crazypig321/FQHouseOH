//! TEMPORARY desktop probe #3 for the home-channel pagination diagnosis.
//! Not part of the shipping app; delete after use.
//!
//! t5 (听书) pagination variants:
//! A. homepage p2 offset=12 without session.
//! B. homepage p2 offset=12 with tab session (known 101116 from probe #2).
//! C. series-feed tab_type=5 + t5 cell_id (cell/change, change_type=2).
//! D. series-feed t5 p2 via data.next_offset (change_type=1).

use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;

fn write_out(out: &PathBuf, name: &str, body: &[u8]) {
    let file = out.join(format!("{}.json", name));
    std::fs::write(&file, body).unwrap_or_else(|e| panic!("write {}: {}", name, e));
}

async fn get(base: &PathBuf, out: &PathBuf, name: &str, path: &str, query: &str) -> Value {
    let resp = api::request(
        format!("probe3_{}", name),
        "GET".to_string(),
        path.to_string(),
        query.to_string(),
        Vec::new(),
        60_000,
    )
    .await
    .unwrap_or_else(|e| panic!("{} failed: {}", name, e));
    write_out(out, name, &resp.body);
    let v: Value = serde_json::from_slice(&resp.body)
        .unwrap_or(Value::Null);
    println!(
        "{}: http={} bytes={} code={:?} msg={:?}",
        name,
        resp.status,
        resp.body.len(),
        v.get("code"),
        v.get("message").and_then(|m| m.as_str()),
    );
    let _ = base;
    v
}

fn find_tab<'a>(data: &'a Value, tab_type: i64) -> Option<&'a Value> {
    let ti = data.get("tab_item")?;
    let mut found: Option<&Value> = None;
    if let Some(arr) = ti.as_array() {
        for t in arr {
            if t.get("tab_type").and_then(|v| v.as_i64()) == Some(tab_type) {
                found = Some(t);
            }
        }
    } else if let Some(map) = ti.as_object() {
        for (_k, t) in map {
            if t.get("tab_type").and_then(|v| v.as_i64()) == Some(tab_type) {
                found = Some(t);
            }
        }
    }
    found
}

fn first_string_field(v: &Value, field: &str) -> Option<String> {
    match v {
        Value::Object(m) => {
            if let Some(s) = m.get(field).and_then(|x| x.as_str()) {
                return Some(s.to_string());
            }
            for (_k, child) in m {
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

fn count_array(v: &Value, field: &str) -> usize {
    let mut total = 0usize;
    match v {
        Value::Object(m) => {
            for (k, child) in m {
                if k == field {
                    if let Some(a) = child.as_array() {
                        total += a.len();
                    }
                }
                total += count_array(child, field);
            }
        }
        Value::Array(a) => {
            for child in a {
                total += count_array(child, field);
            }
        }
        _ => {}
    }
    total
}

#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(
        std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".to_string()),
    );
    let runtime = base.join("backend");
    let out = base.join("out");
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;

    let started = api::init(
        runtime.join("config").join("config.json").to_string_lossy().into_owned(),
        base.join("pool.json").to_string_lossy().into_owned(),
        runtime.join("config").join("filter.json").to_string_lossy().into_owned(),
        runtime.to_string_lossy().into_owned(),
        0,
        false,
        String::new(),
    )
    .await?;
    println!("init: {}", started);

    // Baseline: t5 homepage p1.
    let t5p1 = get(&base, &out, "t5_p1d", "/api/v1/recommend/homepage", "tab_type=5&offset=0").await;
    let t5_data = t5p1.get("data").cloned().unwrap_or(Value::Null);
    let (tab_next, tab_session, cell_id) = match find_tab(&t5_data, 5) {
        Some(tab) => (
            tab.get("next_offset").and_then(|v| v.as_i64()),
            tab.get("session_id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            first_string_field(tab, "cell_id_str").unwrap_or_default(),
        ),
        None => {
            println!("t5 tab NOT FOUND, abort");
            return Ok(());
        }
    };
    println!(
        "t5 p1: tab next_offset={:?} session={} cell_id={} books={}",
        tab_next,
        &tab_session,
        &cell_id,
        count_array(&t5_data, "book_data"),
    );

    // A. homepage p2 without session.
    if let Some(next) = tab_next {
        get(&base, &out, "t5_p2_nosession", "/api/v1/recommend/homepage",
            &format!("tab_type=5&offset={}", next)).await;
    }

    // B. homepage p2 with tab session.
    if let Some(next) = tab_next {
        get(&base, &out, "t5_p2_session", "/api/v1/recommend/homepage",
            &format!("tab_type=5&offset={}&session_id={}", next, tab_session)).await;
    }

    // C. series-feed with tab_type=5 + t5 cell.
    if !cell_id.is_empty() {
        let mut q = format!(
            "cell_id={}&tab_type=5&client_template=2&client_req_type=2&offset=0&unlimited_selector_change_type=2",
            cell_id);
        if !tab_session.is_empty() {
            q = format!("{}&session_id={}", q, tab_session);
        }
        let sf1 = get(&base, &out, "t5_sf1", "/api/v1/recommend/series-feed", &q).await;
        let sf1_data = sf1.get("data").cloned().unwrap_or(Value::Null);
        let sf1_next = sf1_data.get("next_offset").and_then(|v| v.as_i64());
        let sf1_session = sf1_data.get("session_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        println!(
            "t5_sf1: next_offset={:?} session={} books={} videos={} has_more={:?}",
            sf1_next,
            &sf1_session,
            count_array(&sf1_data, "book_data"),
            count_array(&sf1_data, "video_data"),
            sf1_data.get("has_more"),
        );

        // D. series-feed t5 p2.
        if let Some(next) = sf1_next {
            if next > 0 {
                let mut q2 = format!(
                    "cell_id={}&tab_type=5&client_template=2&client_req_type=2&offset={}&unlimited_selector_change_type=1&session_id={}",
                    cell_id, next, sf1_session);
                if sf1_session.is_empty() {
                    q2 = format!(
                        "cell_id={}&tab_type=5&client_template=2&client_req_type=2&offset={}&unlimited_selector_change_type=1",
                        cell_id, next);
                }
                let sf2 = get(&base, &out, "t5_sf2", "/api/v1/recommend/series-feed", &q2).await;
                let sf2_data = sf2.get("data").cloned().unwrap_or(Value::Null);
                println!(
                    "t5_sf2: next_offset={:?} session={} books={} has_more={:?}",
                    sf2_data.get("next_offset"),
                    sf2_data.get("session_id").and_then(|v| v.as_str()).unwrap_or(""),
                    count_array(&sf2_data, "book_data"),
                    sf2_data.get("has_more"),
                );
            }
        }
    }

    api::shutdown().await?;
    println!("done");
    Ok(())
}
