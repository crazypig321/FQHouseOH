//! TEMPORARY desktop probe for the home-channel pagination diagnosis.
//! Not part of the shipping app; delete after use.
//!
//! Boots the real core against the deployed backend runtime (config/filters)
//! and captures raw responses for the endpoints the home channels page
//! through: legacy `/api/search` (短剧/听书 paged fallback) and the homepage
//! recommend stream (tab_type 8 / 5).

use fqapi_core::api;
use std::path::PathBuf;

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

    let probes: Vec<(&str, &str, &str)> = vec![
        (
            "search_duanju_p1",
            "/api/search",
            "source=%E7%95%AA%E8%8C%84&query=%E7%9F%AD%E5%89%A7&page=1",
        ),
        (
            "search_duanju_p2",
            "/api/search",
            "source=%E7%95%AA%E8%8C%84&query=%E7%9F%AD%E5%89%A7&page=2",
        ),
        (
            "search_tingshu_p1",
            "/api/search",
            "source=%E7%95%AA%E8%8C%84&query=%E5%90%AC%E4%B9%A6&page=1",
        ),
        (
            "search_tingshu_p2",
            "/api/search",
            "source=%E7%95%AA%E8%8C%84&query=%E5%90%AC%E4%B9%A6&page=2",
        ),
        (
            "homepage_t8_p1",
            "/api/v1/recommend/homepage",
            "tab_type=8&offset=0",
        ),
        (
            "homepage_t5_p1",
            "/api/v1/recommend/homepage",
            "tab_type=5&offset=0",
        ),
    ];
    for (name, path, query) in probes {
        let resp = api::request(
            format!("probe_{}", name),
            "GET".to_string(),
            path.to_string(),
            query.to_string(),
            Vec::new(),
            60_000,
        )
        .await?;
        let file = out.join(format!("{}.json", name));
        std::fs::write(&file, &resp.body).map_err(|e| e.to_string())?;
        println!(
            "{}: status={} bytes={} -> {}",
            name,
            resp.status,
            resp.body.len(),
            file.display()
        );
    }
    api::shutdown().await?;
    println!("done");
    Ok(())
}
