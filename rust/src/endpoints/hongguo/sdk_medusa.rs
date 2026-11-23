//! Medusa v5 信封原语（纯算法）。
//!
//! 移植自 hongguo-drama 参考实现（对拍蓝本，行号指向
//! `vendor/phone_account/phone_account_medusa_cipher.py` 与
//! `vendor/phone_account/phone_playback_medusa_v5.py`）。
//! 替换表由调用方提供（真实链路来自 `libmetasec_ml.so` 镜像切片）。

use base64::Engine as _;
use md5::{Digest, Md5};

use crate::error::{ApiError, ApiResult};
use crate::sign::sm3::sm3_hash;

// V5 wire 参数（python: `phone_playback_medusa_v5.py:15-19`，与 V3 协议不同）。
const ROUND_CONSTANTS: [u32; 4] = [0xbbb5_de72, 0xd463_8d5b, 0x92a5_f73b, 0x89f8_a1c9];
const ROW_ORDERS: [[usize; 4]; 4] = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]];
const LAST_COLUMN: [[usize; 4]; 4] = [[15, 7, 3, 11], [11, 3, 15, 7], [3, 15, 11, 7], [15, 3, 11, 7]];
const SOURCE_BITS: [u32; 8] = [6, 5, 3, 4, 2, 7, 1, 0];
const PACKED_BITS: [u32; 8] = [1, 7, 3, 6, 2, 0, 4, 5];

fn twice(value: u8) -> u8 {
    (value.wrapping_shl(1)) ^ (if value & 0x80 != 0 { 0x1b } else { 0 })
}

/// derive_scramble_key（python: `phone_account_medusa_cipher.py:31`）：
/// SM3(seed+le32(nonce)+seed) + 位混合 mask。
pub fn derive_scramble_key(seed: &[u8; 32], nonce: u32) -> ([u8; 32], [u8; 4]) {
    let mut input = Vec::with_capacity(68);
    input.extend_from_slice(seed);
    input.extend_from_slice(&nonce.to_le_bytes());
    input.extend_from_slice(seed);
    let digest = sm3_hash(&input);
    let byte = (nonce >> 16) & 255;
    let inner = (((nonce >> 5) & 0x7f800) | (nonce >> 24)) ^ ((byte as u32) >> 5) ^ byte as u32;
    (digest, (!inner).to_le_bytes())
}

/// scramble（python: `phone_account_medusa_cipher.py:38`）。
pub fn scramble(payload: &[u8], key: &[u8; 32]) -> ApiResult<Vec<u8>> {
    if payload.len() < 4 {
        return Err(ApiError::internal("invalid-scramble-input"));
    }
    let mut transformed = vec![0u8; payload.len()];
    for (index, value) in payload.iter().enumerate() {
        let a = key[(index % 8) * 4];
        let b = key[(index % 8) * 4 + 1];
        let x = value.rotate_left(4);
        let middle = ((!x.wrapping_add(a)) ^ b).rotate_left(3);
        transformed[index] = !(middle.wrapping_add(b) ^ a);
    }
    let mut out: Vec<u8> = transformed.into_iter().rev().collect();
    let len = out.len();
    let original_first = out[0];
    let edge = out[len - 1] ^ out[len - 2];
    out[0] = out[0].wrapping_add(!edge);
    out[1] = out[1].wrapping_add(out[len - 1] ^ out[0] ^ 0xfe);
    out[2] = out[2].wrapping_add(edge.wrapping_sub(original_first) ^ out[1].rotate_left(3) ^ 2);
    for index in 3..len - 1 {
        out[index] =
            out[index].wrapping_add(!(out[index - 2] ^ out[index - 1].rotate_left(3) ^ index as u8));
    }
    out[len - 1] ^= out[len - 2];
    let tail_sum: u32 = out[1..].iter().map(|b| *b as u32).sum();
    out[0] = (out[0] ^ out[1]).wrapping_add(tail_sum as u8);
    Ok(out)
}

/// V5BlockCipher（python: `phone_playback_medusa_v5.py:22`）：
/// key 16B + 256B 替换表 + variant 0-3；两轮自定义 SPN，非 AES。
pub struct V5BlockCipher {
    substitution: [u8; 256],
    rows: [usize; 4],
    shift: [usize; 16],
    keys: [[u8; 16]; 3],
}

impl V5BlockCipher {
    pub fn new(key: &[u8; 16], substitution: &[u8; 256], variant: usize) -> Self {
        let rows = ROW_ORDERS[variant];
        let mut shift = [0usize; 16];
        for (index, slot) in shift.iter_mut().enumerate() {
            *slot = if index % 4 == 3 {
                LAST_COLUMN[variant][index / 4]
            } else {
                (index + [0usize, 8, 12][index % 4]) % 16
            };
        }
        let constant = ROUND_CONSTANTS[variant];
        let constant_bytes = constant.to_le_bytes();
        let mut initial = *key;
        for (i, byte) in initial.iter_mut().enumerate() {
            *byte ^= constant_bytes[i % 4];
        }
        let mut words: Vec<[u8; 4]> = vec![[0u8; 4]; 12];
        for i in 0..4 {
            words[i].copy_from_slice(&initial[i * 4..i * 4 + 4]);
        }
        for index in 4..12usize {
            let mut previous = words[index - 1];
            if index % 4 == 0 {
                previous.rotate_left(1);
                for byte in previous.iter_mut() {
                    *byte = substitution[*byte as usize];
                }
                let round_byte = ((constant.wrapping_shr(((2 * index) & 24) as u32)) & 255) as u8;
                previous[0] ^= round_byte;
            }
            for i in 0..4 {
                words[index][i] = words[index - 4][i] ^ previous[i];
            }
        }
        let mut keys = [[0u8; 16]; 3];
        for (k, round_key) in keys.iter_mut().enumerate() {
            for i in 0..4 {
                round_key[i * 4..i * 4 + 4].copy_from_slice(&words[k * 4 + i]);
            }
        }
        V5BlockCipher { substitution: *substitution, rows, shift, keys }
    }

    fn add_key(&self, state: &[u8; 16], key: &[u8; 16]) -> [u8; 16] {
        let mut out = [0u8; 16];
        for row in 0..4 {
            for col in 0..4 {
                out[row * 4 + col] = state[row * 4 + col] ^ key[row * 4 + self.rows[col]];
            }
        }
        out
    }

    pub fn block(&self, block: &[u8; 16]) -> [u8; 16] {
        let mut state = self.add_key(block, &self.keys[0]);
        for step in 1..=2usize {
            let mut sub = [0u8; 16];
            for i in 0..16 {
                sub[i] = self.substitution[state[i] as usize];
            }
            let mut reordered = [0u8; 16];
            for r in 0..4 {
                let src = self.rows[r] * 4;
                reordered[r * 4..r * 4 + 4].copy_from_slice(&sub[src..src + 4]);
            }
            let mut permuted = [0u8; 16];
            for i in 0..16 {
                permuted[i] = reordered[self.shift[i]];
            }
            state = permuted;
            if step == 1 {
                let mut reordered2 = [0u8; 16];
                for row in 0..4 {
                    for col in 0..4 {
                        reordered2[row * 4 + col] = state[row * 4 + self.rows[col]];
                    }
                }
                state = reordered2;
                let mut mixed = [0u8; 16];
                for col in 0..4 {
                    let column = [
                        state[col],
                        state[4 + col],
                        state[8 + col],
                        state[12 + col],
                    ];
                    let total = column[0] ^ column[1] ^ column[2] ^ column[3];
                    for row in 0..4 {
                        mixed[row * 4 + col] =
                            column[row] ^ total ^ twice(column[row] ^ column[(row + 1) % 4]);
                    }
                }
                state = mixed;
            }
            state = self.add_key(&state, &self.keys[step]);
        }
        for i in 0..16 {
            state[i] ^= self.keys[1][i];
        }
        state
    }
}

/// compact_cipher_v5（python: `phone_playback_medusa_v5.py:48`）：
/// 采样 payload 位 → 32B 压块 → 两轮 V5BlockCipher（CBC 样式）。
pub fn compact_cipher_v5(
    payload: &[u8],
    seconds: u32,
    key_material: &[u8; 32],
    substitution_tables: &[u8; 1024],
) -> ApiResult<[u8; 32]> {
    if payload.len() < 248 {
        return Err(ApiError::internal("invalid-wire-payload"));
    }
    let mut sampled = [0u8; 32];
    for group in 0..31 {
        let mut byte = 0u8;
        for bit in 0..8 {
            byte |= ((payload[group * 8 + bit] >> SOURCE_BITS[bit]) & 1) << PACKED_BITS[bit];
        }
        sampled[group] = byte;
    }
    sampled[31] = 1;
    let variant = (seconds & 3) as usize;
    let mut substitution = [0u8; 256];
    substitution.copy_from_slice(&substitution_tables[variant * 256..variant * 256 + 256]);
    let key: [u8; 16] = Md5::digest(&key_material[..16]).into();
    let cipher = V5BlockCipher::new(&key, &substitution, variant);
    let first_iv: [u8; 16] = Md5::digest(&key_material[16..]).into();
    let mut first_input: [u8; 16] = sampled[..16].try_into().unwrap();
    for i in 0..16 {
        first_input[i] ^= first_iv[i];
    }
    let first = cipher.block(&first_input);
    let mut second_input: [u8; 16] = sampled[16..].try_into().unwrap();
    for i in 0..16 {
        second_input[i] ^= first[i];
    }
    let second = cipher.block(&second_input);
    let mut out = [0u8; 32];
    out[..16].copy_from_slice(&first);
    out[16..].copy_from_slice(&second);
    Ok(out)
}

/// envelope_v5（python: `phone_playback_medusa_v5.py:67`）：
/// scramble + 位回填 + compact_cipher_v5 → base64 X-Medusa。
#[allow(clippy::too_many_arguments)]
pub fn envelope_v5(
    proto: &[u8],
    query_digest: &[u8; 32],
    body_proof: &[u8; 20],
    seconds: u32,
    key_nonce: u32,
    frame_nonce: u32,
    seed: &[u8; 32],
    frame: &[u8; 16],
    prefix: &[u8; 8],
    substitution_tables: &[u8; 1024],
) -> ApiResult<String> {
    if !(229..=1024 * 1024).contains(&proto.len()) {
        return Err(ApiError::internal("invalid-proof-message"));
    }
    let (key, mask) = derive_scramble_key(seed, key_nonce);
    let scrambled = scramble(proto, &key)?;
    let mut mixed: Vec<u8> = Vec::with_capacity(prefix.len() + scrambled.len());
    mixed.extend_from_slice(prefix);
    mixed.extend_from_slice(&scrambled);
    mixed.reverse();
    for (index, value) in mixed.iter_mut().enumerate() {
        *value ^= mask[(!index) & 3];
    }
    let flags: u32 = 0x1800_0001
        | (((query_digest[0] & 63) as u32) << 14)
        | (((body_proof[0] & 63) as u32) << 8);
    let mut payload = Vec::with_capacity(11 + mixed.len());
    payload.push(0xca);
    payload.extend_from_slice(&frame_nonce.to_le_bytes());
    payload.extend_from_slice(&flags.to_le_bytes());
    payload.extend_from_slice(&mixed);
    payload.extend_from_slice(&((key_nonce >> 16) as u16).to_le_bytes());
    let encrypted = compact_cipher_v5(&payload, seconds, seed, substitution_tables)?;
    for group in 0..31 {
        for offset in 0..8 {
            let bit = (encrypted[group] >> PACKED_BITS[offset]) & 1;
            let index = group * 8 + offset;
            payload[index] = (payload[index] & !(1 << SOURCE_BITS[offset]))
                | (bit << SOURCE_BITS[offset]);
        }
    }
    let mut result = (seconds ^ 5).to_le_bytes().to_vec();
    let seconds_bytes = seconds.to_le_bytes();
    let mut frame_mixed = *frame;
    for i in 0..16 {
        frame_mixed[i] ^= seconds_bytes[i % 4];
    }
    result.extend_from_slice(&frame_mixed);
    result.extend_from_slice(&((key_nonce & 0xffff) as u16).to_le_bytes());
    result.extend_from_slice(&[0x00, 0x01]);
    result.extend_from_slice(&encrypted[31..32]);
    result.extend_from_slice(&payload);
    Ok(base64::engine::general_purpose::STANDARD.encode(result))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 向量来源：C:\Users\ADMINI~1\AppData\Local\Temp\deveco\gen_p2_vectors.py
    // （Python 参考实现在 PC 上对固定确定性输入跑出）。

    fn det(n: usize, seed: &str) -> Vec<u8> {
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
    fn derive_scramble_key_matches_python() {
        let seed: [u8; 32] = det(32, "seed")[..].try_into().unwrap();
        let (key, mask) = derive_scramble_key(&seed, 0x12345678);
        assert_eq!(
            hex::encode(key),
            "43d7f322dd9f8fbdc3bc9ab38edbf973ec7707388aa8e10a3bf59221dbe756dc"
        );
        assert_eq!(hex::encode(mask), "d85ffeff");
    }

    #[test]
    fn scramble_matches_python() {
        let payload = det(300, "scr");
        let key: [u8; 32] = det(32, "key")[..].try_into().unwrap();
        let out = scramble(&payload, &key).unwrap();
        assert_eq!(
            hex::encode(&out),
            "28bf7f5c2eeb232d8bcf3c945d9b6a1dafe0ba7cee82aefb1c2af4fe555dffca15aef9e1423e6969263d8da091958d320ea21e91244d5a85e0fc3fe2fc30578cc0b6f87239fc6ce56007d51e056c317241755e20c4ecf5c39eafcc304188f278377964b93b127202de56c7102d7b51ab0a17a47e3a58e3d413578fd93b3ad1dfcb83011a908d3a28521f5ba5927172d7bbf7e186ddace4c256f22788cb8fdae888b7ceabf8570adb80798badb67d582e342c83ebe53c179e1877af733fd8f585c64c230af7be0bdfda59362a2c59b7c2be56477b2e074bd25cd3e94a410f0071fe57b4b525764a7de9c790b5fcfa9da5fce91025d48ab22ccc345c52c79e806698f4cd8491c7c6a53733244219b2132385d4585d33351776d99d4f606111cec01a169b9d6b148671dd10710a"
        );
        // 小 payload（37B）。
        let small = det(37, "scrsmall");
        let out = scramble(&small, &key).unwrap();
        assert_eq!(
            hex::encode(&out),
            "9a5bbbd6afe5f74575e7dc3a2423e6c42c9aad8e771e55cb3e53d432e9529c825d5ad2044d"
        );
        assert!(scramble(&[1, 2, 3], &key).is_err());
    }

    #[test]
    fn compact_cipher_v5_matches_python() {
        let payload = det(248, "cc");
        let key_material: [u8; 32] = det(32, "km")[..].try_into().unwrap();
        let substitution_tables: [u8; 1024] = det(1024, "st")[..].try_into().unwrap();
        let out = compact_cipher_v5(&payload, 1795000001, &key_material, &substitution_tables).unwrap();
        assert_eq!(
            hex::encode(out),
            "e8ef25c44e29fa33cce8fde4ae5f36ef4c51397a2303ff9ec8c49cc6c0d2f70a"
        );
        assert!(compact_cipher_v5(&payload[..247], 1795000001, &key_material, &substitution_tables).is_err());
    }

    #[test]
    fn envelope_v5_matches_python() {
        let proto = det(229, "proto");
        let query_digest: [u8; 32] = det(32, "qd")[..].try_into().unwrap();
        let body_proof: [u8; 20] = det(20, "bp")[..].try_into().unwrap();
        let seed: [u8; 32] = det(32, "seed2")[..].try_into().unwrap();
        let frame: [u8; 16] = det(16, "frame")[..].try_into().unwrap();
        let prefix: [u8; 8] = [0x04, 0x05, 0, 0, 0, 0, 0, 0];
        let substitution_tables: [u8; 1024] = det(1024, "st")[..].try_into().unwrap();
        let value = envelope_v5(
            &proto, &query_digest, &body_proof, 1795000002, 0xdeadbeef, 0xcafebabe,
            &seed, &frame, &prefix, &substitution_tables,
        )
        .unwrap();
        assert_eq!(
            value,
            "x4b9arTZWRYT7kFAtZmjBy1M0KnvvgAB+sq+su7KAasFGABiuPpPhNSKbw6Z5qK1wFomRuoRFqvshRylaIl3A+hZBCheebM1YqFdXsyLTiXs1GRVs6Y6aZhRkMTC8k2iQOjXGeZJiQEwm2kpGRw5k/MnYZoGz3mJpz2tIRUARGlx+uQW+3SADTfdlcsbTWVmXadLdQ5rvWIQkrTWqeyBIg1dwK4+ZXSEbdlPTBnpodL8Qzy6zuEJEFIiSV9S4AxLVPyKftZ2VMWEu8ndsyXyiQRa43NnkrvELg3+1WPBR3998hCKVvO7zozpFKFqECmcChyex1dWvwv3uIVpWAVRt661xsJtu2X4l4n/8peIe63f"
        );
        // proto 过短被拒。
        assert!(envelope_v5(
            &proto[..228], &query_digest, &body_proof, 1795000002, 1, 1,
            &seed, &frame, &prefix, &substitution_tables,
        )
        .is_err());
    }

    #[test]
    fn envelope_v5_with_real_materials_matches_python() {
        // 真实资产链路：sign_key 做 seed、镜像 frame/substitutions（gen 脚本 8b 段）。
        let config = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "\\..\\entry\\src\\main\\resources\\rawfile\\hg_sdk\\sdk-app-config.encoded"
        ))
        .unwrap();
        let image = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "\\..\\entry\\libs\\arm64-v8a\\libmetasec_ml.so"
        ))
        .unwrap();
        let materials = super::super::sdk_materials::decode_app_config(&config, "8662").unwrap();
        let parts = super::super::sdk_materials::read_sdk_image(&image).unwrap();
        let proto = det(500, "proto2");
        let query_digest: [u8; 32] = crate::sign::sm3::sm3_hash(&det(64, "q"));
        let body_proof: [u8; 20] = det(20, "bp2")[..].try_into().unwrap();
        let prefix: [u8; 8] = [0x04, 0x05, 0, 0, 0, 0, 0, 0];
        let value = envelope_v5(
            &proto, &query_digest, &body_proof, 1795000012, 0x01020304, 0x0a0b0c0d,
            &materials.signing_key, &parts.frame, &prefix, &parts.substitutions,
        )
        .unwrap();
        assert_eq!(
            value,
            "yYb9auHNsqCF8/Ap8zNTRu7rMTwEAwABCMotBBsKAU4MWPPOoO6BJjzRnrqTFFdBnoarIWTAHz7gSEqSgi4EKztY0jaxt37GeDIIXjQ1YWuWd4bakSfDBBnf7y7MCVE2Zh42HyajxRnoxW8Wyzw9Zo2j+MLTGtfWlYeouOLWAqoPGz8i0E7l1DRop4tOZ3lFY/lo1Lvc9XM4MN7DQCH+fW1TbeKJpulv7YqRPK3Zt8e3qJKznhJjzrpn76O4o7bO/3xrpme5LShBgP4NWSQXca9TFING9tE07097QM94/nm4UXMO70PNCAPwW0BS+g81ZyIiR6MstP4FaNRoF+TWYXzuUg5DyFTNsnk88i5JTm8cPQYKTx0dPW/HDhxIAKyuPh525xQNe1s8bcRKnT15mUcNMheer4YQ5XKartsn5EecSteA+z5sYG590IWGbsBS7AJRKtgJ4OtlxSGFEmq1rb/fGQ99hHK6gi84IbGUDkWfs6ersCowMJkyhYVCIqbXvoAgEXiAGc6cHvC5IUXAcsSytTY7EwwYwwZlQNqnG6bTSghteNTsuGu+LBkb2QOLP5OIeZXTK18w+FdPkUmRz9v7M3dQshQknav6Sac3x5Ros7jCNXE5mkSYpTPucljEW1Wms679loYmea50+v+CryrqFH+1TN0EU7hX8eV6h56w/5oKEFV2URwN1WZGL4P/l8JbcnJr///v/P//6vgCAQ=="
        );
    }
}
