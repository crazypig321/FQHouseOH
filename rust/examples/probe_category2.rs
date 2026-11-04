//! TEMPORARY probe: try /api/v1/category with query_gender/genre_type hints
//! from rule.categoy_tab_dic to see if tiles actually switch per channel.
//! Variants:
//!   v1: tab=2 + query_gender=0
//!   v2: tab=2 + query_gender=0 + genre_type=0
//!   v3: tab=3 + query_gender=2 + genre_type=1
//!   v4: tab=4 + query_gender=2 + genre_type=160
//!   v5: tab=1 + query_gender=1 (control)
//! Results: out/catg_{v}.json

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
        false,
        String::new(),
    )
    .await?;
    println!("init: {}", started);

    let variants: Vec<(&str, String)> = vec![
        ("v1", "category_tab=2&query_gender=0".to_string()),
        ("v2", "category_tab=2&query_gender=0&genre_type=0".to_string()),
        ("v3", "category_tab=3&query_gender=2&genre_type=1".to_string()),
        ("v4", "category_tab=4&query_gender=2&genre_type=160".to_string()),
        ("v5", "category_tab=1&query_gender=1".to_string()),
    ];
    for (name, query) in variants {
        let label = query.clone();
        let resp = api::request(
            format!("probe_catg_{}", name),
            "GET".to_string(),
            "/api/v1/category".to_string(),
            query,
            Vec::new(),
            60_000,
        )
        .await?;
        let file = out.join(format!("catg_{}.json", name));
        std::fs::write(&file, &resp.body).map_err(|e| e.to_string())?;
        println!("{} [{}] status={} bytes={}", name, label, resp.status, resp.body.len());
    }
    api::shutdown().await?;
    println!("done");
    Ok(())
}
