//! V5 digest 外层与签名头原语（纯算法）。
//!
//! 移植自 hongguo-drama 参考实现（对拍蓝本，行号指向
//! `vendor/phone_account/phone_account_medusa_digest.py`、
//! `vendor/phone_account/phone_playback_digest_v5.py`、
//! `vendor/phone_account/phone_playback_signing_v5.py`、
//! `vendor/phone_account/phone_sdk_bootstrap_v5.py`、
//! `vendor/phone_account/vendor/XGorgon.py`）。
//! 16B digest 核心由调用方注入（ohos 上为 Unicorn 仿真的 sdk_digest，host 测试为 mock）。

use md5::{Digest, Md5};

use crate::error::{ApiError, ApiResult};
use crate::sign::sm3::sm3_hash;

/// digest core 注入点：payload[52] + mode + seconds → 16B 前缀。
/// 真实实现为 `sdk_digest.rs` 的 Unicorn 仿真（返回 20B，取前 16B）。
pub type DigestCore<'a> = &'a dyn Fn(&[u8; 52], u8, u32) -> ApiResult<[u8; 16]>;

/// selector（python: `phone_account_medusa_digest.py:22`，初值 0x20230928，
/// 每段独立奇偶索引变换）。
pub fn selector(query_digest: &[u8; 32], body_hash: &[u8; 16], seconds: u32) -> u32 {
    let mut value: u32 = 0x2023_0928;
    for part in [
        query_digest.as_slice(),
        &body_hash[..],
        &seconds.to_le_bytes()[..],
    ] {
        for (index, byte) in part.iter().enumerate() {
            if index % 2 == 1 {
                value = !(value ^ (value >> 7) ^ (value.wrapping_shl(12) | *byte as u32));
            } else {
                value = value ^ (value >> 4) ^ value.wrapping_shl(6) ^ *byte as u32;
            }
        }
    }
    value
}

/// checksum（python: `phone_account_medusa_digest.py:33`，取 value[:12]，
/// `((result|4)^0x01000000)` 收尾）。
pub fn checksum(value: &[u8]) -> u32 {
    let mut result: u32 = 0x2022_0420;
    for (index, byte) in value.iter().take(12).enumerate() {
        if index % 2 == 1 {
            result = result ^ (result >> 5) ^ !(result.wrapping_shl(11) | *byte as u32);
        } else {
            result = result ^ (result >> 3) ^ result.wrapping_shl(7) ^ *byte as u32;
        }
    }
    (result | 4) ^ 0x0100_0000
}

/// digest_v5 外层（python: `phone_playback_digest_v5.py:12`）：
/// SM3(query) + MD5(body) + selector&15 → 52B payload → core 16B 前缀 + le32(checksum|0x20)。
pub fn digest_v5(query: &[u8], body: &[u8], seconds: u32, core: DigestCore<'_>) -> ApiResult<[u8; 20]> {
    if query.len() > 1024 * 1024 {
        return Err(ApiError::internal("invalid-query-bytes"));
    }
    if body.len() > 16 * 1024 * 1024 {
        return Err(ApiError::internal("invalid-body-bytes"));
    }
    let query_hash = sm3_hash(query);
    let body_hash: [u8; 16] = if body.is_empty() { [0; 16] } else { Md5::digest(body).into() };
    let mode = (selector(&query_hash, &body_hash, seconds) & 15) as u8;
    let mut payload = [0u8; 52];
    payload[..32].copy_from_slice(&query_hash);
    payload[32..48].copy_from_slice(&body_hash);
    payload[48..].copy_from_slice(&seconds.to_le_bytes());
    let prefix = core(&payload, mode, seconds)?;
    let mut out = [0u8; 20];
    out[..16].copy_from_slice(&prefix);
    out[16..].copy_from_slice(&(checksum(&prefix) | 0x20).to_le_bytes());
    Ok(out)
}

/// advance_ladon（python: `phone_sdk_bootstrap_v5.py:86`）：
/// CRC64 风格校验（多项式 0x95ac9329ac4bc9b5 反射）于 `646637794`，
/// rotl 4 后与 previous 混合。ladon 状态跨请求演进。
pub fn advance_ladon(previous: u32, allocation: u64, seconds: u32) -> u32 {
    let mut state: u64 = 0;
    for byte in b"646637794" {
        state ^= *byte as u64;
        for _ in 0..8 {
            state = if state & 1 != 0 {
                (state >> 1) ^ 0x95ac_9329_ac4b_c9b5
            } else {
                state >> 1
            };
        }
    }
    let mixed = allocation ^ state ^ seconds as u64;
    previous ^ (mixed.rotate_left(4) as u32)
}

/// RC4（就地加解密；python: `Crypto.Cipher.ARC4`）。
pub fn rc4(key: &[u8], data: &mut [u8]) {
    let mut s: Vec<u8> = (0..=255u8).collect();
    let mut j: usize = 0;
    for i in 0..256 {
        j = (j + s[i] as usize + key[i % key.len()] as usize) & 0xff;
        s.swap(i, j);
    }
    let (mut i, mut j) = (0usize, 0usize);
    for byte in data.iter_mut() {
        i = (i + 1) & 0xff;
        j = (j + s[i] as usize) & 0xff;
        s.swap(i, j);
        *byte ^= s[(s[i] as usize + s[j] as usize) & 0xff];
    }
}

/// XGorgon 位变换（python: `vendor/XGorgon.py:58` `__handle`，就地处理 20 字节）。
/// 每字节：半字节交换 ^ 下一个字节 → 8 位反转 → ^长度 → 取反。
pub fn xgorgon_handle(input: &mut [u8; 20]) {
    for i in 0..20 {
        let b = input[i].rotate_left(4);
        let c = input[(i + 1) % 20];
        let d = b ^ c;
        let e = d.reverse_bits();
        input[i] = !(e ^ 20);
    }
}

/// gorgon_v5（python: `phone_playback_signing_v5.py:15`）：
/// MD5(query)[:4] + MD5(body)[:4] + 4 零 + `00030a04` + be32(seconds)
/// → RC4(key 含 nonce/flags) → XGorgon 位变换 → `8404+le16(nonce)+flags` + 结果 hex。
pub fn gorgon_v5(query: &[u8], body: &[u8], seconds: u32, nonce: u16, flags: &[u8; 2]) -> String {
    let query_hash: [u8; 16] = Md5::digest(query).into();
    let body_hash: [u8; 16] = if body.is_empty() { [0; 16] } else { Md5::digest(body).into() };
    let mut payload = [0u8; 20];
    payload[..4].copy_from_slice(&query_hash[..4]);
    payload[4..8].copy_from_slice(&body_hash[..4]);
    payload[12..16].copy_from_slice(&[0x00, 0x03, 0x0a, 0x04]);
    payload[16..].copy_from_slice(&seconds.to_be_bytes());
    let key = [0x4a, flags[0], 0x16, (nonce >> 8) as u8, 0x47, 0x6c, flags[1], nonce as u8];
    rc4(&key, &mut payload);
    xgorgon_handle(&mut payload);
    let mut out = Vec::with_capacity(24);
    out.extend_from_slice(&[0x84, 0x04]);
    out.extend_from_slice(&nonce.to_le_bytes());
    out.extend_from_slice(flags);
    out.extend_from_slice(&payload);
    hex::encode(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // 向量来源：C:\Users\ADMINI~1\AppData\Local\Temp\deveco\gen_p2_vectors.py
    // （Python 参考实现在 PC 上对固定确定性输入跑出）。

    fn det(n: usize, seed: &str) -> Vec<u8> {
        // 与生成脚本一致的确定性字节：sha256(seed + str(i)) 串联。
        let mut out = Vec::new();
        let mut i = 0u32;
        while out.len() < n {
            let mut hasher = sha2::Sha256::new();
            sha2::Digest::update(&mut hasher, seed.as_bytes());
            sha2::Digest::update(&mut hasher, i.to_string().as_bytes());
            out.extend_from_slice(&sha2::Digest::finalize(hasher));
            i += 1;
        }
        out.truncate(n);
        out
    }

    #[test]
    fn selector_matches_python() {
        let query_digest: [u8; 32] = det(32, "sel")[..].try_into().unwrap();
        let body_hash: [u8; 16] = det(16, "sel")[..].try_into().unwrap();
        assert_eq!(selector(&query_digest, &body_hash, 1795000000), 2120939371);
    }

    #[test]
    fn checksum_matches_python() {
        let input = hex::decode("97736a04a59e489f368febc2b7e24bf5").unwrap();
        assert_eq!(checksum(&input), 3515034935);
    }

    #[test]
    fn digest_v5_with_mock_core_matches_python() {
        let query = det(64, "q");
        let body = det(48, "b");
        let mock: [u8; 16] = hex::decode("000102030405060708090a0b0c0d0e0f")
            .unwrap()[..]
            .try_into()
            .unwrap();
        let core = |_payload: &[u8; 52], _mode: u8, _seconds: u32| -> ApiResult<[u8; 16]> { Ok(mock) };
        let digest = digest_v5(&query, &body, 1795000010, &core).unwrap();
        assert_eq!(hex::encode(digest), "000102030405060708090a0b0c0d0e0f7d9a37d9");
    }

    #[test]
    fn digest_v5_empty_body_uses_zero_hash() {
        let query = det(64, "q");
        let core = |_payload: &[u8; 52], mode: u8, _seconds: u32| -> ApiResult<[u8; 16]> {
            // 校验空 body 时 payload 中段为 16 零。
            assert_eq!(&_payload[32..48], &[0u8; 16]);
            Ok([mode; 16])
        };
        assert!(digest_v5(&query, b"", 1795000010, &core).is_ok());
    }

    #[test]
    fn advance_ladon_matches_python() {
        assert_eq!(advance_ladon(0x11223344, 0x8877665544332210, 1795000003), 1337777974);
        assert_eq!(advance_ladon(0, 16, 1), 2993987674);
        assert_eq!(advance_ladon(0xffffffff, 0, 0), 1300979381);
    }

    #[test]
    fn gorgon_v5_matches_python() {
        let query = det(40, "gq");
        let body = det(24, "gb");
        let flags: [u8; 2] = [0x04, 0x05];
        assert_eq!(
            gorgon_v5(&query, &body, 1795000004, 0xabcd, &flags),
            "8404cdab04054cbed8949ab6e417b3e8ffa7c787907fd91d73a0"
        );
        assert_eq!(
            gorgon_v5(&query, b"", 1795000004, 0xabcd, &flags),
            "8404cdab04054cbed86a1e7de8aab3e8ffa7c787907fd91d73a0"
        );
    }

    #[test]
    fn xgorgon_handle_matches_python() {
        let mut input: [u8; 20] = hex::decode("1d3e637982fc45ae15cd429ed6e31a4b7c10f520")
            .unwrap()[..]
            .try_into()
            .unwrap();
        xgorgon_handle(&mut input);
        assert_eq!(hex::encode(input), "1cea1943c0bab414d292b6179acfbcf800c41593");
    }

    #[test]
    fn rc4_matches_python_and_rfc() {
        let key = det(20, "rc4k");
        let mut data = det(100, "rc4d");
        rc4(&key, &mut data);
        assert_eq!(
            hex::encode(&data),
            "88d23eb8c52ad27a6fed45b2751b70a5b2a48c955439ca4cafd2289d5fc2cff54d0c8708ad8953b3b6642562279cc425ad966b5c23ebfae5a1f886f879e99f9e5a58086b0476f860f9f2efccb9840cab702450bcf4a4919e132828415961e35f2bf9207a"
        );
        let mut classic = b"Plaintext".to_vec();
        rc4(b"Key", &mut classic);
        assert_eq!(hex::encode(&classic), "bbf316e8d940af0ad3");
    }

    #[test]
    fn sm3_matches_python() {
        let input = det(100, "sm3");
        assert_eq!(
            hex::encode(sm3_hash(&input)),
            "2a6966be27965078dd098667f14bcd1c892ea5b922a1d39d3a5dc8e1ed897275"
        );
    }

    #[test]
    fn helios_matches_python_ladon() {
        // X-Helios 即 XLadon：复用既有 sign::ladon 实现，与 Python `ladon_encrypt`
        // （vendor/XLadon.py:99）对拍。参数固定 646637794/8662，数据 25 字节
        // 永不 16 对齐，padding 语义差异（Python 对齐时跳过填充）不触发。
        let value = crate::sign::ladon::ladon_encrypt(1795000005, 646637794, 8662, &hex::decode("f6e7beff").unwrap());
        assert_eq!(value, "9ue+/0+YNNz72nkbGC71mbSGsMl2AvKK3obJrZww03c9lt/+");
    }
}
