//! TEMPORARY probe: fetch /api/v1/category for category_tab 1..6 (官方分类页
//! NewCategoryTabType：1=男频 2=女频 3=有声书 4=出版 5=漫画 6=短剧)，
//! inspect the real schema (tab_list / dims / tiles).
//! Results: out/catfront_{tab}.json

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

    for tab in 1..=6 {
        let resp = api::request(
            format!("probe_catfront_{}", tab),
            "GET".to_string(),
            "/api/v1/category".to_string(),
            format!("category_tab={}", tab),
            Vec::new(),
            60_000,
        )
        .await?;
        let file = out.join(format!("catfront_{}.json", tab));
        std::fs::write(&file, &resp.body).map_err(|e| e.to_string())?;
        println!(
            "tab={} status={} bytes={}",
            tab,
            resp.status,
            resp.body.len()
        );
    }
    api::shutdown().await?;
    println!("done");
    Ok(())
}
