//! TEMPORARY probe: verify v1 search tab_type=2 (听书) as an alternative
//! source for audio category words that return nothing via legacy /api/search.
//! Results: out/cat5_t2_{i}.json + out/cat5_manifest.tsv

use fqapi_core::api;
use std::path::PathBuf;

fn enc(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        if b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_' || *b == b'.' {
            out.push(*b as char);
        } else {
            out.push_str(format!("%{:02X}", b).as_str());
        }
    }
    out
}

#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(
        std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".to_string()),
    );
    let runtime = base.join("backend");
    let config = runtime.join("config").join("config.json");
    let filter = runtime.join("config").join("filter.json");
    let pool = base.join("pool.json");
    let out = base.join("out");
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;

    let started = api::init(
        config.to_string_lossy().into_owned(),
        pool.to_string_lossy().into_owned(),
        filter.to_string_lossy().into_owned(),
        runtime.to_string_lossy().into_owned(),
        0,
        String::new(),
    )
    .await?;
    println!("init: {}", started);

    let words: Vec<&str> = vec![
        "玄幻", "悬疑", "历史", "官场", "文学", "军事", "古言", "现言", "甜宠", "萌宝",
        "都市", "相声", "仙侠", "评书", "儿童",
    ];

    let mut manifest = String::new();
    for (i, w) in words.iter().enumerate() {
        let name = format!("cat5_t2_{:02}", i);
        let resp = api::request(
            format!("probe_{}", name),
            "GET".to_string(),
            "/api/v1/search".to_string(),
            format!("query={}&tab_type=2&offset=0&count=10", enc(w)),
            Vec::new(),
            60_000,
        )
        .await?;
        let file = out.join(format!("{}.json", name));
        std::fs::write(&file, &resp.body).map_err(|e| e.to_string())?;
        manifest.push_str(&format!("{}\t{}\n", name, w));
        println!("{} [{}] status={} bytes={}", name, w, resp.status, resp.body.len());
    }
    std::fs::write(out.join("cat5_manifest.tsv"), manifest).map_err(|e| e.to_string())?;
    api::shutdown().await?;
    println!("done");
    Ok(())
}
