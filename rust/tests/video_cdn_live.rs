//! 临时 live 诊断（不进 CI）：复现设备端「video ... download failed: HTTP 403」。
//! 修复（非流式统一 shortplay 主解析）后作为线上回归：rust.log 中 403 过的
//! 视频批量走非流式整集下载，应全部成功。
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test video_cdn_live -- --ignored --nocapture
//! ```

mod common;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;
use std::sync::Mutex;

/// 设备端修复后仍 403 的漫剧分集（2026-11-12 20:56，v13-reading-video 域）。
const VIDEO_IDS: &[&str] = &[
    "7705852498908548120", // 11-12 修复后仍 403（v13 域，漫剧）
    "7705852496144501784", // 同系列另一集（修复前 403，PC 上修复后成功）
];

const UA_WINDOWS_BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
const UA_CHROME_FULL: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
const UA_FANQIE_APP: &str = "com.dragon.read/72432 (Linux; U; Android 16; zh_CN; \
     25053RT47C; Build/KRWX; Cronet/TTNet)";

static LOG_RECORDS: Mutex<Vec<String>> = Mutex::new(Vec::new());

struct PrintLogger;
impl log::Log for PrintLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }
    fn log(&self, record: &log::Record) {
        let line = record.args().to_string();
        println!("[{}] {}", record.level(), line);
        if let Ok(mut records) = LOG_RECORDS.lock() {
            records.push(line);
        }
    }
    fn flush(&self) {}
}

static PRINT_LOGGER: PrintLogger = PrintLogger;

fn host_of(url: &str) -> String {
    url.split("//")
        .nth(1)
        .and_then(|rest| rest.split('/').next())
        .unwrap_or("?")
        .to_string()
}

/// GET 一个 URL，打印状态；错误响应体读前 256 字节。
async fn probe(label: &str, url: &str, ua: &str) {
    let client = reqwest::Client::builder().build().expect("probe client");
    match client.get(url).header("user-agent", ua).send().await {
        Ok(resp) => {
            let status = resp.status();
            let len = resp
                .headers()
                .get("content-length")
                .map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned())
                .unwrap_or_else(|| "?".to_string());
            let mut note = String::new();
            if !status.is_success() {
                if let Ok(bytes) = resp.bytes().await {
                    let body = &bytes[..bytes.len().min(256)];
                    note = format!(" body={}", String::from_utf8_lossy(body));
                }
            }
            println!("[probe] {label}: {status} len={len}{note}");
        }
        Err(e) => println!("[probe] {label}: SEND-ERR {e}"),
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn live_reproduce_and_probe_cdn_403() {
    let _ = log::set_logger(&PRINT_LOGGER);
    log::set_max_level(log::LevelFilter::Warn);

    // 空设备池：DevicePool 在构建时经 log.snssdk.com 现注册真实设备（App 首启同路）。
    let dir = TempDir::new("video-cdn-live");
    let srv = build_server(&dir, None, &[], &[], &pool_json(0)).await;

    let video = srv.handler("video").expect("route");

    for video_id in VIDEO_IDS {
        println!("================ video {video_id} ================");

        // 1) 与 App 完全相同的形态（无 mode → 后端代下载路径）。
        let params = Params::from_pairs(vec![("video_id".to_string(), video_id.to_string())]);
        match video(&srv.ctx, &params).await {
            Ok(value) => {
                let local = value["video_url"].as_str().unwrap_or("?");
                println!("[non-stream] OK local={local}");
            }
            Err(e) => println!("[non-stream] ERR: {}", e.message()),
        }

        // 2) stream 形态：列出全部档位与 host，对主 URL 与各档做多 UA 探测，
        //    定位 v13 域 403 的触发条件（UA / 档位 / 域名族）。
        let params = Params::from_pairs(vec![
            ("video_id".to_string(), video_id.to_string()),
            ("mode".to_string(), "stream".to_string()),
        ]);
        let value = match video(&srv.ctx, &params).await {
            Ok(value) => value,
            Err(e) => {
                println!("[stream] ERR: {}", e.message());
                continue;
            }
        };
        let main_url = value["video_url"].as_str().unwrap_or_default().to_string();
        if !main_url.is_empty() {
            println!("[stream] main host={}", host_of(&main_url));
            probe("main + UA_WINDOWS(现行为)", &main_url, UA_WINDOWS_BROWSER).await;
            probe("main + Chrome全量", &main_url, UA_CHROME_FULL).await;
            probe("main + 番茄App UA", &main_url, UA_FANQIE_APP).await;
        }
        if let Some(variants) = value["variants"].as_array() {
            for (i, variant) in variants.iter().enumerate().take(6) {
                let name = variant["name"].as_str().unwrap_or("?");
                let url = variant["url"].as_str().unwrap_or_default();
                if url.is_empty() {
                    continue;
                }
                probe(
                    &format!("variant[{i}] {name} ({}) + UA_WINDOWS", host_of(url)),
                    url,
                    UA_WINDOWS_BROWSER,
                )
                .await;
            }
        }
    }
}
