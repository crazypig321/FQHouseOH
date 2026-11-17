//! TEMPORARY probe: category_tab 1..6 with follow-tab last_chose_tab defaults
//! (官方切 tab 时「上次选择」同步上报的假设验证)。
//! Results: out/cat3_{tab}.json + word fingerprints on stdout.

use fqapi_core::api;
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<(), String> {
    let base = PathBuf::from(std::env::var("FQPROBE_DIR").unwrap_or_else(|_| ".".to_string()));
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

    // (label, query)：新默认（last_chose_tab/last_choose_tab_v2 跟随 tab）
    let cases: Vec<(String, String)> = vec![
        ("tab1".into(), "category_tab=1".into()),
        ("tab2".into(), "category_tab=2".into()),
        ("tab3".into(), "category_tab=3".into()),
        ("tab4".into(), "category_tab=4".into()),
        ("tab5".into(), "category_tab=5".into()),
        ("tab6".into(), "category_tab=6".into()),
        // 备选通道：rule.categoy_tab_dic 的 per-tab 过滤参数（tab=2 女生）
        (
            "tab2_dic".into(),
            "category_tab=2&query_gender=0&genre_type=0".into(),
        ),
    ];

    for (label, query) in &cases {
        let resp = api::request(
            format!("probe_cat3_{}", label),
            "GET".to_string(),
            "/api/v1/category".to_string(),
            query.clone(),
            Vec::new(),
            60_000,
        )
        .await?;
        let file = out.join(format!("cat3_{}.json", label));
        std::fs::write(&file, &resp.body).map_err(|e| e.to_string())?;
        println!("{} status={} bytes={}", label, resp.status, resp.body.len());
    }
    api::shutdown().await?;
    println!("done");
    Ok(())
}
