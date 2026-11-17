use fqapi_core::api;
use serde_json::Value;
use std::path::PathBuf;
#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".into()));
    let runtime = base.join("backend");
    api::init(base.join("backend/config/config.json").to_string_lossy().into_owned(),
        base.join("pool.json").to_string_lossy().into_owned(),
        base.join("backend/config/filter.json").to_string_lossy().into_owned(),
        runtime.to_string_lossy().into_owned(), 0, false, String::new()).await?;
    let query = std::env::var("FQPROBE_QUERY").unwrap_or_default();
    let q = format!("source=%E7%95%AA%E8%8C%84&query={}&page=1", query);
    let resp = api::request("probe_title".into(), "GET".into(), "/api/search".into(), q, Vec::new(), 60_000).await?;
    let v: Value = serde_json::from_slice(&resp.body).unwrap_or(Value::Null);
    std::fs::write(base.join("out/title_search.json"), &resp.body).map_err(|e| e.to_string())?;
    if let Some(tabs) = v["data"]["search_tabs"].as_array() {
        for t in tabs {
            let title = t["title"].as_str().unwrap_or("");
            if let Some(rows) = t["data"].as_array() {
                println!("== tab {} rows={} ==", title, rows.len());
                for row in rows.iter().take(6) {
                    println!("  book_id={:?} series={:?} name={:?}", row["book_id"].as_str(), row["series_id"].as_str(),
                        row["book_name"].as_str().or(row["title"].as_str()).or(row["name"].as_str()));
                }
            }
        }
    } else {
        println!("no search_tabs; code={:?} msg={:?}", v["code"], v["message"]);
        println!("{}", String::from_utf8_lossy(&resp.body).chars().take(300).collect::<String>());
    }
    api::shutdown().await?;
    Ok(())
}
