//! TEMPORARY desktop probe for the home-category strip word verification.
//! Not part of the shipping app; delete after use.
//!
//! Round 4 (cat4): verify every category word of the 6 channel groups against
//! each channel's real search form (mirroring HomePage loadPagedStage/loadCursorStage):
//! - book / audio: legacy `/api/search?source=番茄&query={word}&page=1`
//! - video: v1 `/api/v1/search?query={word}&tab_type=11&offset=0&count=10`
//! - manju: v1 t11, query `{word}漫剧`
//! - manga: v1 `/api/v1/search?query={word}&tab_type=8&offset=0&count=10`
//!
//! Results land in out/cat4_*.json + out/cat4_manifest.tsv (name/form/word).

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
        false,
        String::new(),
    )
    .await?;
    println!("init: {}", started);

    // 小说（全部 ∪ 男频 ∪ 女频，去重）
    let book_words: Vec<&str> = vec![
        "都市", "玄幻", "仙侠", "奇幻", "武侠", "历史", "科幻", "悬疑", "轻小说", "古言",
        "现言", "军事", "游戏", "灵异", "脑洞", "幻言", "甜宠", "萌宝", "宫斗", "宅斗", "虐恋", "短篇",
    ];
    // 听书（全部 ∪ 男频 ∪ 女频 ∪ 出版，去重）
    let audio_words: Vec<&str> = vec![
        "都市", "玄幻", "仙侠", "悬疑", "历史", "官场", "相声", "评书", "文学", "儿童",
        "军事", "古言", "现言", "甜宠", "萌宝",
    ];
    // 短剧（全部 ∪ 男频 ∪ 女频，去重）
    let video_words: Vec<&str> = vec![
        "甜宠", "逆袭", "战神", "豪门", "萌宝", "复仇", "穿越", "重生", "神豪", "打脸",
        "赘婿", "都市", "玄幻", "虐恋", "总裁", "古言",
    ];
    // 漫剧（全部 ∪ 男频 ∪ 女频，去重）
    let manju_words: Vec<&str> = vec![
        "古风", "恋爱", "玄幻", "都市", "搞笑", "热血", "悬疑", "奇幻", "治愈", "冒险", "甜宠", "萌宝",
    ];
    // 漫画（全部 ∪ 男频 ∪ 女频，去重）
    let manga_words: Vec<&str> = vec![
        "恋爱", "搞笑", "热血", "玄幻", "都市", "古风", "科幻", "冒险", "悬疑", "治愈", "甜宠", "萌宝",
    ];

    // (name, form, word, path, query)
    let mut probes: Vec<(String, String, String, String, String)> = Vec::new();
    for (i, w) in book_words.iter().enumerate() {
        probes.push((
            format!("cat4_book_{:02}", i), "book".to_string(), w.to_string(),
            "/api/search".to_string(),
            format!("source={}&query={}&page=1", enc("番茄"), enc(w)),
        ));
    }
    for (i, w) in audio_words.iter().enumerate() {
        probes.push((
            format!("cat4_audio_{:02}", i), "audio".to_string(), w.to_string(),
            "/api/search".to_string(),
            format!("source={}&query={}&page=1", enc("番茄"), enc(w)),
        ));
    }
    for (i, w) in video_words.iter().enumerate() {
        probes.push((
            format!("cat4_video_{:02}", i), "video".to_string(), w.to_string(),
            "/api/v1/search".to_string(),
            format!("query={}&tab_type=11&offset=0&count=10", enc(w)),
        ));
    }
    for (i, w) in manju_words.iter().enumerate() {
        probes.push((
            format!("cat4_manju_{:02}", i), "manju".to_string(), w.to_string(),
            "/api/v1/search".to_string(),
            format!("query={}&tab_type=11&offset=0&count=10", enc(&format!("{}漫剧", w))),
        ));
    }
    for (i, w) in manga_words.iter().enumerate() {
        probes.push((
            format!("cat4_manga_{:02}", i), "manga".to_string(), w.to_string(),
            "/api/v1/search".to_string(),
            format!("query={}&tab_type=8&offset=0&count=10", enc(w)),
        ));
    }

    let mut manifest = String::new();
    for (name, form, word, path, query) in &probes {
        let resp = api::request(
            format!("probe_{}", name),
            "GET".to_string(),
            path.clone(),
            query.clone(),
            Vec::new(),
            60_000,
        )
        .await?;
        let file = out.join(format!("{}.json", name));
        std::fs::write(&file, &resp.body).map_err(|e| e.to_string())?;
        manifest.push_str(&format!("{}\t{}\t{}\n", name, form, word));
        println!("{} [{}] status={} bytes={}", name, word, resp.status, resp.body.len());
    }
    std::fs::write(out.join("cat4_manifest.tsv"), manifest).map_err(|e| e.to_string())?;
    api::shutdown().await?;
    println!("done: {} probes", probes.len());
    Ok(())
}
