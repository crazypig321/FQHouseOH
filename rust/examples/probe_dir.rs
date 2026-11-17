use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;
#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".into()));
    api::init(base.join("backend/config/config.json").to_string_lossy().into_owned(),
        base.join("pool.json").to_string_lossy().into_owned(),
        base.join("backend/config/filter.json").to_string_lossy().into_owned(),
        base.join("runtime").to_string_lossy().into_owned(), 0, false, String::new()).await?;
    let id = std::env::var("FQPROBE_BOOK").unwrap_or_default();
    let q = format!("source=%E7%95%AA%E8%8C%84&book_id={}&tab=%E7%9F%AD%E5%89%A7", id);
    let resp = api::request("probe_dir".into(), "GET".into(), "/api/directory".into(), q, Vec::new(), 60_000).await?;
    std::fs::write(base.join("out/dir.json"), &resp.body).map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_slice(&resp.body).unwrap_or(Value::Null);
    // find first item list anywhere
    fn find_list(v: &Value) -> Option<Value> {
        match v {
            Value::Object(m) => {
                for (k, val) in m {
                    if k == "item_data_list" || k == "episodes" || k == "chapter_list_with_part" {
                        if val.as_array().is_some_and(|a| !a.is_empty()) { return Some(val.clone()); }
                    }
                    if let Some(found) = find_list(val) { return Some(found); }
                }
                None
            }
            Value::Array(a) => { for c in a { if let Some(f) = find_list(c) { return Some(f); } } None }
            _ => None,
        }
    }
    println!("http={} bytes={}", resp.status, resp.body.len());
    if let Some(list) = find_list(&v) {
        if let Some(arr) = list.as_array() {
            println!("episodes={}", arr.len());
            for row in arr.iter().take(5) {
                println!("  item_id={:?} title={:?}", row["item_id"].as_str().or(row["chapter_id"].as_str()).or(row["video_id"].as_str()), row["title"].as_str());
            }
        }
    } else {
        println!("code={:?} msg={:?} head={}", v["code"], v["message"],
            String::from_utf8_lossy(&resp.body).chars().take(200).collect::<String>());
    }
    api::shutdown().await?;
    Ok(())
}
