//! 红果免费短剧（aid=8662）弹幕（comment）请求签名。参考实现为同协议的
//! 公开移植（guoapp_ohos 的 provider_hongguo_comment_sign.go，GPL-3.0），
//! 本项目同为 GPL-3.0。
//!
//! 与番茄侧签名（[`crate::sign`]）同族但不同版：
//! - `x-gorgon`：红果 comment 口是 0x84 前缀 + RC4 变种种子；番茄侧已弃用
//!   gorgon，逻辑完全不同。
//! - `x-argus`：同样走「protobuf bean -> PKCS7 -> 分组加密 -> 框架字节 ->
//!   AES-CBC」，但分组加密是 72 轮 Feistel（SM3 派生轮密钥），不是番茄侧
//!   的 Simon；前缀/魔数/AES key 派生也不同。
//! - `x-ladon`：34 轮 ARX 与番茄侧 [`crate::sign::ladon`] 逐字节同构，
//!   直接复用其 `ladon_encrypt_raw`，只有数据串拼法不同。
//!
//! 弹幕（comment）请求不需要注册设备：随机 19 位数字 device_id/iid 即可，
//! 这是红果弹幕链路能独立于设备池存在的原因。
//!
//! 搜索/详情等 player 请求已切到新签名套件（[`super::vsign`]，固定硬编码
//! 设备，免注册），旧 player 签名套件已退役删除。

use base64::Engine as _;
use md5::{Digest, Md5};

use crate::crypto::{aes_cbc_encrypt, pkcs7_pad};
use crate::sign::protobuf::ProtoBuf;
use crate::sign::sm3::sm3_hash;

/// comment/player argus 共用的 SDK 签名种子（guoapp 固定值）。
pub(crate) const ARGUS_KEY_HEX: &str =
    "ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c";

fn argus_sign_key() -> &'static [u8] {
    static K: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    K.get_or_init(|| hex::decode(ARGUS_KEY_HEX).expect("hongguo argus key"))
}

fn md5_hex(data: &[u8]) -> String {
    let mut h = Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

fn sm3_prefix6(msg: &[u8]) -> [u8; 6] {
    let h = sm3_hash(msg);
    let mut out = [0u8; 6];
    out.copy_from_slice(&h[..6]);
    out
}

/// 11 字节随机 nonce，comment 与 player 口共用长度。
pub(crate) fn new_nonce() -> [u8; 11] {
    use rand::RngCore;
    let mut n = [0u8; 11];
    rand::thread_rng().fill_bytes(&mut n);
    n
}

/// 随机 19 位数字设备号（guoapp newHongguoDeviceID）。
pub(crate) fn random_device_id() -> String {
    use rand::RngCore;
    let mut b = [0u8; 8];
    rand::thread_rng().fill_bytes(&mut b);
    let v = u64::from_be_bytes(b) % 8_000_000_000_000_000_000;
    format!("{}", 1_000_000_000_000_000_000i64 + v as i64)
}

fn rev8(x: u8) -> u8 {
    x.reverse_bits()
}

/// comment 口 `X-Gorgon`：RC4 变种 KSA（无交换）+ PRGA + 位变换。
fn comment_gorgon(query: &str, nonce: &[u8; 11], stamp: i64) -> String {
    let head2 = ((nonce[0] % 7 + 1) << 5) as u8;
    let head3 = 0xE0 | (nonce[1] & 15);
    let mut seed = [0u8; 20];
    let h = Md5::new().chain_update(query.as_bytes()).finalize();
    seed[..4].copy_from_slice(&h[..4]);
    seed[12..16].copy_from_slice(&[0, 1, 7, 4]);
    seed[16..20].copy_from_slice(&(stamp as u32).to_be_bytes());
    let key = [0x4Au8, 0, 0x16, head3, 0x47, 0x6C, 0, head2];

    let mut box_ = [0u8; 256];
    for (i, slot) in box_.iter_mut().enumerate() {
        *slot = i as u8;
    }
    let mut j = 0u8;
    for i in 0..256 {
        j = j
            .wrapping_add(box_[i])
            .wrapping_add(key[i & 7]);
        box_[i] = box_[j as usize];
    }
    let mut j = 0u8;
    for offset in 0..20 {
        let i = (offset + 1) as u8;
        j = j.wrapping_add(box_[i as usize]);
        box_[i as usize] = box_[j as usize];
        seed[offset] ^= box_[(box_[i as usize]).wrapping_add(box_[j as usize]) as usize];
    }
    for i in 0..20 {
        let mixed = (seed[i].rotate_left(4)) ^ seed[(i + 1) % 20];
        seed[i] = rev8(mixed) ^ 0xEB;
    }

    let mut out = vec![0x84u8, 4, head2, head3, 0, 0];
    out.extend_from_slice(&seed);
    hex::encode(out)
}

/// comment 口 `X-Ladon`：md5(prefix||aid) 建 34 轮表（复用番茄侧
/// `ladon_encrypt_raw`），数据串固定 `{ts}-1611921764-3019`。
fn comment_ladon(aid: &str, stamp: i64, prefix: &[u8]) -> String {
    let mut keygen = prefix.to_vec();
    keygen.extend_from_slice(aid.as_bytes());
    let md5_hex = md5_hex(&keygen);
    let data = format!("{stamp}-1611921764-3019");
    let enc = crate::sign::ladon::ladon_encrypt_raw(&md5_hex, data.as_bytes());
    let mut out = prefix.to_vec();
    out.extend_from_slice(&enc);
    base64::engine::general_purpose::STANDARD.encode(out)
}

/// comment/player argus 的 72 轮 Feistel 分组加密（非 Simon）。
fn argus_feistel(data: &mut [u8]) {
    let key = argus_sign_key();
    let mut seed = key.to_vec();
    seed.extend_from_slice(&[0x3C, 0xCC, 0x56, 0x7B]);
    seed.extend_from_slice(key);
    let derived = sm3_hash(&seed);

    let mut rounds = [0u64; 72];
    for i in 0..4 {
        rounds[i] = u64::from_le_bytes(derived[i * 8..i * 8 + 8].try_into().unwrap());
    }
    for i in 4..72 {
        let mixed = rounds[i - 1].rotate_right(3) ^ rounds[i - 3];
        let mixed = mixed ^ mixed.rotate_right(1);
        rounds[i] = (!rounds[i - 4])
            ^ mixed
            ^ ((0x3DC94C3A046D678Bu64 >> ((i - 4) % 62)) & 1)
            ^ 3;
    }

    for block in data.chunks_exact_mut(16) {
        let mut l = u64::from_le_bytes(block[..8].try_into().unwrap());
        let mut r = u64::from_le_bytes(block[8..].try_into().unwrap());
        for round in rounds {
            let new_r = l ^ ((r.rotate_left(1) & r.rotate_left(8)) ^ r.rotate_left(2) ^ round);
            l = r;
            r = new_r;
        }
        block[..8].copy_from_slice(&l.to_le_bytes());
        block[8..].copy_from_slice(&r.to_le_bytes());
    }
}

/// Feistel 之后的框架与 AES-CBC 封装（comment 与 player argus 共用尾部）。
fn argus_frame(message: &[u8]) -> String {
    let key = argus_sign_key();
    let mut data = pkcs7_pad(message, 16);
    argus_feistel(&mut data);

    let xor = [0xD0u8, 0x4F, 0xFD, 0xFF, 0xD0, 0x4F, 0xFD, 0xFF];
    for (i, b) in data.iter_mut().enumerate() {
        *b ^= xor[i % 8];
    }
    let mut buf = xor.to_vec();
    buf.extend_from_slice(&data);
    buf.reverse();

    let mut container = vec![0xA6u8, 0xE7, 0x83, 0xEE, 0x70, 0x01, 0x10, 0x09, 0x18];
    container.extend_from_slice(&buf);
    container.extend_from_slice(&[0x56, 0x7B]);
    let container = pkcs7_pad(&container, 16);

    let aes_key = Md5::new().chain_update(&key[..16]).finalize();
    let aes_iv = Md5::new().chain_update(&key[16..]).finalize();
    let enc = aes_cbc_encrypt(&container, &aes_key, &aes_iv);

    let mut raw = vec![0x3Cu8, 0xCC];
    raw.extend_from_slice(&enc);
    base64::engine::general_purpose::STANDARD.encode(raw)
}

/// comment 口 `X-Argus`。`query` 是完整 RawQuery 串。
fn comment_argus(query: &str, stamp: i64, nonce: &[u8; 11]) -> String {
    let mut bean = ProtoBuf::new();
    bean.put_varint(1, 0x20200929i64 * 2);
    bean.put_varint(2, 2);
    bean.put_varint(3, u32::from_le_bytes(nonce[6..10].try_into().unwrap()) as i64);
    bean.put_utf8(4, "3019");
    bean.put_utf8(6, "1611921764");
    bean.put_utf8(7, "6.8.1.32");
    bean.put_utf8(8, "v04.07.01-ml-android");
    bean.put_varint(9, 135_135_744);
    bean.put_bytes(10, &[0u8; 8]);
    bean.put_varint(12, stamp * 2);
    bean.put_bytes(13, &sm3_prefix6(&[0u8; 16]));
    bean.put_bytes(14, &sm3_prefix6(query.as_bytes()));

    let mut nested = ProtoBuf::new();
    nested.put_varint(1, 2 + (nonce[10] % 49) as i64 * 2);
    nested.put_varint(2, 1_388_734);
    nested.put_varint(3, 1_388_734);
    nested.put_varint(4, 1_388_734);
    bean.put_protobuf(15, &nested);

    bean.put_utf8(20, "none");
    bean.put_varint(21, 738);

    argus_frame(&bean.to_buf())
}

/// 弹幕（comment）请求签名头集合。`query` 为完整 RawQuery。
pub(crate) fn sign_comment_request(query: &str, aid: &str, nonce: &[u8; 11], stamp: i64) -> Vec<(String, String)> {
    vec![
        ("X-Gorgon".into(), comment_gorgon(query, nonce, stamp)),
        ("X-Khronos".into(), stamp.to_string()),
        ("X-SS-Req-Ticket".into(), format!("{}", stamp * 1000)),
        ("X-SS-STUB".into(), String::new()),
        ("X-Argus".into(), comment_argus(query, stamp, nonce)),
        (
            "X-Ladon".into(),
            comment_ladon(aid, stamp, &nonce[2..6]),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    // 黄金向量由独立 Python 参考实现（guoapp Go 的 1:1 移植）生成，
    // 见 tests.rs 的说明；这里只验证结构性质，向量比对在 tests.rs。

    #[test]
    fn random_device_ids_are_19_digit_numeric() {
        for _ in 0..100 {
            let id = random_device_id();
            assert_eq!(id.len(), 19, "{id}");
            assert!(id.chars().all(|c| c.is_ascii_digit()), "{id}");
            let first = id.chars().next().unwrap();
            assert!(('1'..='9').contains(&first), "{id}");
        }
    }

    #[test]
    fn comment_gorgon_has_0x84_prefix_and_hex_shape() {
        let nonce = [1u8; 11];
        let g = comment_gorgon("aid=8662&device_id=123", &nonce, 1_700_000_000);
        assert!(g.starts_with("84"), "{g}");
        assert_eq!(g.len(), 52, "6 header bytes + 20 seed bytes hex");
    }

    #[test]
    fn argus_outputs_are_base64_with_3ccc_prefix() {
        use base64::Engine as _;
        let engine = &base64::engine::general_purpose::STANDARD;
        let nonce = [2u8; 11];
        let a = comment_argus("aid=8662", 1_700_000_000, &nonce);
        let decoded = engine.decode(a.as_bytes()).expect("valid base64");
        assert_eq!(&decoded[..2], &[0x3c, 0xcc], "{a}");
    }
}
