//! 番茄 → 红果的标题匹配：搜索结果解析、标题归一化与 rank 评级。
//!
//! rank 语义移植 guoapp `hongguoTitleSearchRank`（GPL-3.0，本项目同
//! license）：exact=0 / prefix=1 / contains=2 / 全词命中=3 / 其余=4，
//! [`RANK_ACCEPT`] 以内才接受映射。
//!
//! 归一化 guoapp 用 NFKC + golang.org/x/text；本项目不引入新依赖
//! （Cargo.toml 无 unicode-normalization），手写等价子集：
//! 全角 ASCII 变体（FF01..=FF5E）转半角、U+3000 转空格、小写化、
//! 去空白与标点。对中文剧名（字母数字+汉字为主）与 NFKC 结果一致。

use serde_json::Value;

/// 接受映射的最高 rank（全词命中）。
pub(crate) const RANK_ACCEPT: u8 = 3;

pub(crate) struct SearchCandidate {
    pub series_id: String,
    pub title: String,
}

/// guoapp `hongguoSearchText` 的免依赖版本。
pub(crate) fn normalize_search_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let c = match c {
            '\u{3000}' => ' ',
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
            other => other,
        };
        let c = c.to_lowercase().next().unwrap_or(c);
        if c.is_whitespace() || !c.is_alphanumeric() {
            continue;
        }
        out.push(c);
    }
    if out.is_empty() {
        return text.trim().to_lowercase();
    }
    out
}

/// guoapp `hongguoTitleSearchRank`。
pub(crate) fn title_search_rank(title: &str, query: &str) -> u8 {
    let query_norm = normalize_search_text(query);
    let title_norm = normalize_search_text(title);
    if title_norm == query_norm {
        return 0;
    }
    if title_norm.starts_with(&query_norm) {
        return 1;
    }
    if title_norm.contains(&query_norm) {
        return 2;
    }
    let words = split_words(query);
    let mut matches = 0usize;
    for word in &words {
        if title_norm.contains(word.as_str()) {
            matches += 1;
        }
    }
    if !words.is_empty() && matches == words.len() {
        return 3;
    }
    4
}

/// guoapp `strings.FieldsFunc(NFKC(query), space-or-punct)`：按空白/标点切词，
/// 每个词再走一遍完整归一化。
fn split_words(query: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut cur = String::new();
    for c in query.chars() {
        let halfwidth = match c {
            '\u{3000}' => ' ',
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
            other => other,
        };
        if halfwidth.is_whitespace() || !halfwidth.is_alphanumeric() {
            if !cur.is_empty() {
                words.push(normalize_search_text(&cur));
                cur.clear();
            }
        } else {
            cur.push(halfwidth);
        }
    }
    if !cur.is_empty() {
        words.push(normalize_search_text(&cur));
    }
    words.retain(|w| !w.is_empty());
    words
}

/// 解析 kotlin-tv `ContentRepository.searchAll` 官网搜索响应：
/// `searchList[].video_data`。弹幕映射只做标题 rank 匹配，
/// 不过滤 genre（203/205/空都可能是对端剧），series_id 必须纯数字，
/// 按 series_id 去重。
pub(crate) fn parse_website_search_candidates(result: &Value) -> Vec<SearchCandidate> {
    let mut out: Vec<SearchCandidate> = Vec::new();
    let Some(rows) = result.get("searchList").and_then(|v| v.as_array()) else {
        return out;
    };
    for row in rows {
        let Some(video) = row.get("video_data").and_then(|v| v.as_object()) else {
            continue;
        };
        let series_id = crate::json::first_map_string(video, &["series_id_str", "series_id"]);
        if !crate::endpoints::hongguo::client::is_numeric_id(&series_id) {
            continue;
        }
        let mut title = crate::json::first_map_string(video, &["series_name", "series_title"]);
        if title.is_empty() {
            title = row
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
        }
        let title = if title.is_empty() { series_id.clone() } else { title };
        if out.iter().any(|x| x.series_id == series_id) {
            continue;
        }
        out.push(SearchCandidate { series_id, title });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_fullwidth_and_punctuation() {
        // 全角逗号/冒号 → 半角标点后剥掉；全角字母数字 → 半角。
        assert_eq!(
            normalize_search_text("宴律，你的白月光回国了"),
            "宴律你的白月光回国了"
        );
        assert_eq!(normalize_search_text("ＡＢＣ１２３"), "abc123");
        assert_eq!(normalize_search_text("  逆袭 人生!  "), "逆袭人生");
    }

    #[test]
    fn rank_exact_prefix_contains_words() {
        assert_eq!(title_search_rank("宴律，你的白月光回国了", "宴律，你的白月光回国了"), 0);
        assert_eq!(title_search_rank("宴律你的白月光回国了第二季", "宴律，你的白月光回国了"), 1);
        assert_eq!(title_search_rank("新·宴律，你的白月光回国了", "宴律，你的白月光回国了"), 2);
        assert_eq!(title_search_rank("宴律与白月光", "宴律 白月光"), 3);
        assert_eq!(title_search_rank("完全不相干", "宴律，你的白月光回国了"), 4);
    }

    #[test]
    fn rank_ignores_case_and_width() {
        assert_eq!(title_search_rank("ＡＢＣ ＤＥＦ", "abc def"), 0);
    }

    #[test]
    fn parses_website_search_candidates_across_genres() {
        let result = serde_json::json!({
            "searchList": [
                { "video_data": { "series_id": "7381000000000000001", "series_name": "宴律，你的白月光回国了" } },
                { "video_data": { "series_id": "7381000000000000002", "series_name": "漫画剧", "genre": "205" } },
                { "video_data": { "series_id": "7381000000000000003", "series_title": "短剧二", "genre": "203" } },
                { "video_data": { "series_id": "bad", "series_name": "坏id" } },
                { "name": "无video_data" }
            ]
        });
        let c = parse_website_search_candidates(&result);
        // 不过滤 genre（203/205/空都收），只挡非数字 series_id。
        assert_eq!(c.len(), 3);
        assert_eq!(c[0].series_id, "7381000000000000001");
        assert_eq!(c[0].title, "宴律，你的白月光回国了");
        assert_eq!(c[1].series_id, "7381000000000000002");
        assert_eq!(c[2].series_id, "7381000000000000003");
        assert_eq!(c[2].title, "短剧二");
    }

    #[test]
    fn website_search_rejects_non_numeric_ids_and_dedupes() {
        let result = serde_json::json!({
            "searchList": [
                { "video_data": { "series_id": "abc", "series_name": "x" } },
                { "video_data": { "series_id": "7381000000000000001", "series_name": "a" } },
                { "video_data": { "series_id_str": "7381000000000000001", "series_name": "a" } },
                { "video_data": { "series_id": "7381000000000000004" } }
            ]
        });
        let c = parse_website_search_candidates(&result);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].series_id, "7381000000000000001");
        assert_eq!(c[1].series_id, "7381000000000000004");
        // 无标题回退 series_id。
        assert_eq!(c[1].title, "7381000000000000004");
    }
}
