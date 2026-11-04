//! TEMPORARY desktop probe: rank board payloads (漫剧榜 algo 550 / 短剧榜 502 / 推荐榜 101).
//! Not part of the shipping app; delete after use.

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

    let rank_id = "7098235271900037133";
    let probes: Vec<(&str, String, String)> = vec![
        (
            "rank_manju_550_g5",
            format!("/api/v1/rank/{}", rank_id),
            "algo_type=550&rank_sub_info_id=0&genre_tab=5".to_string(),
        ),
        (
            "rank_duanju_502_g4",
            format!("/api/v1/rank/{}", rank_id),
            "algo_type=502&rank_sub_info_id=0&genre_tab=4".to_string(),
        ),
        (
            "rank_duanju_502_g4_p2",
            format!("/api/v1/rank/{}", rank_id),
            "algo_type=502&rank_sub_info_id=0&genre_tab=4&offset=12".to_string(),
        ),
    ];
    for (name, path, query) in probes {
        let resp = api::request(
            format!("probe_{}", name),
            "GET".to_string(),
            path,
            query,
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
