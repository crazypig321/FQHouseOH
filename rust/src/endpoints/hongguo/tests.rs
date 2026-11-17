//! 黄金向量测试：Rust 弹幕（comment）签名移植与独立 Python 参考实现
//! （`hg_verify.py`，已对真实红果 API 实测 HTTP 200 / code=0）逐字节对齐。
//!
//! 固定输入：`QUERY` / 11 字节 nonce（`10..1a`）/ `STAMP=1731300000`。
//!
//! player 签名黄金向量已随旧 player 套件退役删除（搜索/详情已切
//! `vsign` 新签名套件，其黄金向量见 `vsign.rs` 内联测试）。

use crate::endpoints::hongguo::sign::{sign_comment_request, ARGUS_KEY_HEX};

const QUERY: &str = "aid=8662&count=20&offset=0&query=%E5%AE%B4%E5%BE%8B&tab_type=29";
const AID: &str = "8662";
const STAMP: i64 = 1_731_300_000;

fn fixed_nonce() -> [u8; 11] {
    [
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a,
    ]
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> &'a str {
    headers
        .iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.as_str())
        .unwrap_or_default()
}

#[test]
fn sm3_matches_standard_vectors() {
    assert_eq!(
        hex::encode(crate::sign::sm3::sm3_hash(b"abc")),
        "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
    );
    assert_eq!(
        hex::encode(crate::sign::sm3::sm3_hash(b"")),
        "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b"
    );
}

#[test]
fn comment_headers_match_python_reference() {
    let headers = sign_comment_request(QUERY, AID, &fixed_nonce(), STAMP);
    assert_eq!(header(&headers, "X-Gorgon"), "840460e10000c0c2a5ff14924f64050e90482071e8479f45d2a5");
    assert_eq!(header(&headers, "X-Khronos"), "1731300000");
    assert_eq!(header(&headers, "X-SS-Req-Ticket"), "1731300000000");
    assert_eq!(header(&headers, "X-SS-STUB"), "");
    assert_eq!(
        header(&headers, "X-Argus"),
        "PMxhgUKIXtho/6stSub0VASKJDoVY13IeJ5USEZ0fLHWQcbPohtqH0QbrcfQ+zB7df/moP7xxxRnij2mEOR9JF5RuDlveOTlfW1A59izpTod4FULv6II4Gt4RJslzWmiEIj2pwiEhUg61SKTbRRzXNYmNwZXWXgD25DWLCS1wgsR2UyZAO/QlCFtH44My3gfXJxyrypHxYRS/Iy2Tv43PsziHD2Qi9wXmr8idZAH8kEcQg=="
    );
    assert_eq!(
        header(&headers, "X-Ladon"),
        "EhMUFZ0OfTHTr1+eoFQYm+vprk69Qy8Qy/4anwOSFa/PNrNH"
    );
}

#[test]
fn argus_key_is_the_reference_constant() {
    assert_eq!(ARGUS_KEY_HEX.len(), 64);
    assert!(ARGUS_KEY_HEX.chars().all(|c| c.is_ascii_hexdigit()));
}
