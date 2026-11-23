//! SDK v5 材料解码与镜像切片（纯算法，无 I/O）。
//!
//! 移植自 hongguo-drama 参考实现（对拍蓝本，行号指向
//! `vendor/phone_account/phone_sdk_materials_v5.py` 与
//! `vendor/phone_account/phone_account_medusa.py`）：
//! - [`decode_app_config`]：`sdk-app-config.encoded`（304B）→ sign_key/common_key。
//! - [`read_sdk_image`]：`libmetasec_ml.so` 四切片（frame/substitutions/inner/unavailable）。
//! - [`pb_encode`]/[`wire_fields`]：SDI protobuf 手写编解码（字段少，不引 prost）。
//!
//! 所有输入由调用方读取并提供；本模块不访问文件系统与网络。

use aes::Aes128;
use base64::Engine as _;
use cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
use md5::{Digest, Md5};
use sha1::Sha1;
use sha2::Sha256;

use crate::error::{ApiError, ApiResult};

use super::sdk_sign::rc4;

/// 钉死的 `libmetasec_ml.so`（版本 74532）长度与 SHA256
/// （python: `phone_sdk_materials_v5.py:29`）。
const SDK_IMAGE_LEN: usize = 4_501_136;
const SDK_IMAGE_SHA256: &str = "c6831ab265a0cb76dacfa3b7041e9ea0f706490106a74e12f39058671cc14fe3";

/// 解码后的 SDK 配置密钥（python: `SdkMaterials`）。
#[derive(Debug, Clone)]
pub struct SdkMaterials {
    pub signing_key: [u8; 32],
    pub exchange_key: [u8; 32],
}

/// `libmetasec_ml.so` 镜像切片（python: `SdkImageParts`）。
#[derive(Debug, Clone)]
pub struct SdkImageParts {
    pub frame: [u8; 16],
    pub substitutions: [u8; 1024],
    pub exchange_inner_key: [u8; 16],
    pub unavailable: String,
}

/// protobuf 编码值（python: `phone_account_medusa.protobuf` 的 int/float/str/bytes）。
#[derive(Debug, Clone)]
pub enum PbField<'a> {
    Varint(u64),
    F32(f32),
    Str(&'a str),
    Bytes(&'a [u8]),
}

fn varint(out: &mut Vec<u8>, mut value: u64) {
    while value > 127 {
        out.push((value as u8 & 127) | 128);
        value >>= 7;
    }
    out.push(value as u8);
}

/// protobuf 编码器（python: `phone_account_medusa.py:26`）。
/// int → varint；float → fixed32；str/bytes → length-delimited（空值整体跳过）。
pub fn pb_encode(fields: &[(u32, PbField<'_>)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (field, value) in fields {
        match value {
            PbField::Varint(v) => {
                varint(&mut out, (*field as u64) << 3);
                varint(&mut out, *v);
            }
            PbField::F32(v) => {
                varint(&mut out, ((*field as u64) << 3) | 5);
                out.extend_from_slice(&v.to_bits().to_le_bytes());
            }
            PbField::Str(s) => {
                if !s.is_empty() {
                    varint(&mut out, ((*field as u64) << 3) | 2);
                    varint(&mut out, s.len() as u64);
                    out.extend_from_slice(s.as_bytes());
                }
            }
            PbField::Bytes(b) => {
                if !b.is_empty() {
                    varint(&mut out, ((*field as u64) << 3) | 2);
                    varint(&mut out, b.len() as u64);
                    out.extend_from_slice(b);
                }
            }
        }
    }
    out
}

/// 读取到的 protobuf 字段值。
#[derive(Debug, Clone, PartialEq)]
pub enum WireValue {
    Varint(u64),
    Fixed64([u8; 8]),
    Fixed32([u8; 4]),
    Bytes(Vec<u8>),
}

/// 读取到的 protobuf 字段行。
#[derive(Debug, Clone)]
pub struct WireField {
    pub number: u32,
    pub encoding: u8,
    pub value: WireValue,
}

/// 严格有界 protobuf 读取器（python: `phone_sdk_materials_v5.py:37`）。
/// 保留重复字段；varint 最多 10 字节；行数上限 512。
pub fn wire_fields(data: &[u8], limit: usize) -> ApiResult<Vec<WireField>> {
    if data.len() > limit {
        return Err(ApiError::internal("invalid-sdk-wire-data"));
    }
    let mut cursor = 0usize;
    fn integer(data: &[u8], cursor: &mut usize) -> ApiResult<u64> {
        let mut result: u64 = 0;
        for part in 0..10 {
            if *cursor >= data.len() {
                return Err(ApiError::internal("truncated-sdk-wire-number"));
            }
            let byte = data[*cursor];
            *cursor += 1;
            if part == 9 && byte > 1 {
                return Err(ApiError::internal("overflow-sdk-wire-number"));
            }
            result |= ((byte & 127) as u64) << (7 * part);
            if byte < 128 {
                return Ok(result);
            }
        }
        Err(ApiError::internal("invalid-sdk-wire-number"))
    }
    let mut rows = Vec::new();
    while cursor < data.len() {
        let tag = integer(data, &mut cursor)?;
        let number = (tag >> 3) as u32;
        let encoding = (tag & 7) as u8;
        if number == 0 || number >= 1 << 29 {
            return Err(ApiError::internal("invalid-sdk-wire-field"));
        }
        let value = match encoding {
            0 => WireValue::Varint(integer(data, &mut cursor)?),
            2 => {
                let size = integer(data, &mut cursor)? as usize;
                if size > data.len() - cursor {
                    return Err(ApiError::internal("truncated-sdk-wire-field"));
                }
                let value = data[cursor..cursor + size].to_vec();
                cursor += size;
                WireValue::Bytes(value)
            }
            1 => {
                if cursor + 8 > data.len() {
                    return Err(ApiError::internal("truncated-sdk-wire-field"));
                }
                let mut buf = [0u8; 8];
                buf.copy_from_slice(&data[cursor..cursor + 8]);
                cursor += 8;
                WireValue::Fixed64(buf)
            }
            5 => {
                if cursor + 4 > data.len() {
                    return Err(ApiError::internal("truncated-sdk-wire-field"));
                }
                let mut buf = [0u8; 4];
                buf.copy_from_slice(&data[cursor..cursor + 4]);
                cursor += 4;
                WireValue::Fixed32(buf)
            }
            _ => return Err(ApiError::internal("unsupported-sdk-wire-encoding")),
        };
        rows.push(WireField { number, encoding, value });
        if rows.len() > 512 {
            return Err(ApiError::internal("too-many-sdk-wire-fields"));
        }
    }
    Ok(rows)
}

/// 解码 `sdk-app-config.encoded`（python: `phone_sdk_materials_v5.py:107`）。
/// base64 → MD5 wrapping key → AES-ECB PKCS7 → mask XOR → SHA1+RC4 → 反转 → protobuf 切 key。
pub fn decode_app_config(encoded: &[u8], app_id: &str) -> ApiResult<SdkMaterials> {
    if encoded.len() != 304 {
        return Err(ApiError::internal("invalid-sdk-config-size"));
    }
    if app_id.is_empty() || app_id.len() > 12 || !app_id.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ApiError::internal("invalid-sdk-app-id"));
    }
    let raw = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| ApiError::internal("invalid-sdk-config-base64"))?;
    if raw.len() != 228 {
        return Err(ApiError::internal("invalid-sdk-config-frame"));
    }
    let application = app_id.as_bytes();
    let nonce = &raw[..4];
    let mut wrapping_hasher = Md5::new();
    wrapping_hasher.update(application);
    wrapping_hasher.update(nonce);
    wrapping_hasher.update(application);
    let wrapping_key: [u8; 16] = wrapping_hasher.finalize().into();
    let mut ciphertext = raw[4..].to_vec();
    let decryptor = Aes128::new(GenericArray::from_slice(&wrapping_key));
    for chunk in ciphertext.chunks_mut(16) {
        decryptor.decrypt_block(GenericArray::from_mut_slice(chunk));
    }
    let padding = *ciphertext.last().unwrap() as usize;
    if !(1..=16).contains(&padding)
        || ciphertext[ciphertext.len() - padding..]
            .iter()
            .any(|b| *b != padding as u8)
    {
        return Err(ApiError::internal("invalid-sdk-config-padding"));
    }
    let plaintext = &ciphertext[..ciphertext.len() - padding];
    if plaintext.len() < 9 {
        return Err(ApiError::internal("invalid-sdk-config-payload"));
    }
    let (head, tail) = (&plaintext[..4], &plaintext[plaintext.len() - 4..]);
    let mut mask: u8 = 0;
    for byte in nonce.iter().chain(head).chain(tail) {
        mask ^= byte;
    }
    let mut stream_hasher = Sha1::new();
    stream_hasher.update(head);
    stream_hasher.update(application);
    stream_hasher.update(nonce);
    let stream_key = stream_hasher.finalize();
    let payload = &plaintext[4..plaintext.len() - 4];
    let mut decrypted = payload.to_vec();
    rc4(&stream_key, &mut decrypted);
    // message = reverse(payload) 每个字节 XOR mask（python: `phone_sdk_materials_v5.py:134`）。
    let message: Vec<u8> = decrypted.iter().rev().map(|b| b ^ mask).collect();
    key_entries(&message)
}

/// protobuf 切 key entries（python: `phone_sdk_materials_v5.py:78`）。
fn key_entries(message: &[u8]) -> ApiResult<SdkMaterials> {
    let mut sign_key: Option<[u8; 32]> = None;
    let mut common_key: Option<[u8; 32]> = None;
    for row in wire_fields(message, 8192)? {
        if row.number != 8 {
            continue;
        }
        let WireValue::Bytes(item) = row.value else {
            return Err(ApiError::internal("invalid-sdk-key-entry"));
        };
        let mut name: Option<Vec<u8>> = None;
        let mut value: Option<Vec<u8>> = None;
        for sub in wire_fields(&item, 8192)? {
            match (sub.number, sub.encoding) {
                (1, 2) if name.is_none() => {
                    let WireValue::Bytes(v) = sub.value else {
                        return Err(ApiError::internal("invalid-sdk-key-entry"));
                    };
                    name = Some(v);
                }
                (2, 2) if value.is_none() => {
                    let WireValue::Bytes(v) = sub.value else {
                        return Err(ApiError::internal("invalid-sdk-key-entry"));
                    };
                    value = Some(v);
                }
                _ => return Err(ApiError::internal("invalid-sdk-key-entry")),
            }
        }
        let (Some(name), Some(value)) = (name, value) else {
            return Err(ApiError::internal("incomplete-sdk-key-entry"));
        };
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&value)
            .map_err(|_| ApiError::internal("invalid-sdk-key-format"))?;
        let Ok(key) = <[u8; 32]>::try_from(decoded.as_slice()) else {
            return Err(ApiError::internal("invalid-sdk-key-size"));
        };
        if name == b"sign_key" && sign_key.is_none() {
            sign_key = Some(key);
        } else if name == b"common_key" && common_key.is_none() {
            common_key = Some(key);
        } else {
            return Err(ApiError::internal("unexpected-sdk-key-entry"));
        }
    }
    match (sign_key, common_key) {
        (Some(signing_key), Some(exchange_key)) => Ok(SdkMaterials { signing_key, exchange_key }),
        _ => Err(ApiError::internal("missing-sdk-key-entry")),
    }
}

/// `libmetasec_ml.so` 镜像切片（python: `phone_sdk_materials_v5.py:28`）。
pub fn read_sdk_image(image: &[u8]) -> ApiResult<SdkImageParts> {
    if image.len() != SDK_IMAGE_LEN || hex::encode(Sha256::digest(image)) != SDK_IMAGE_SHA256 {
        return Err(ApiError::internal("unsupported-original-sdk-image"));
    }
    let mut frame = [0u8; 16];
    frame.copy_from_slice(&image[0x665f0..0x66600]);
    let mut substitutions = [0u8; 1024];
    substitutions.copy_from_slice(&image[0xffcf9..0xffcf9 + 1024]);
    let mut exchange_inner_key = [0u8; 16];
    exchange_inner_key[..8].copy_from_slice(&image[0x66690..0x66698]);
    for i in 0..8 {
        exchange_inner_key[8 + i] = image[0x9d08c + i] ^ image[0x9d118 + i];
    }
    let unavailable = image[0x66c44..0x66c4c]
        .to_vec()
        .try_into()
        .ok()
        .and_then(|bytes: [u8; 8]| {
            if bytes.iter().all(|b| b.is_ascii()) {
                Some(String::from_utf8(bytes.to_vec()).unwrap())
            } else {
                None
            }
        })
        .ok_or_else(|| ApiError::internal("unsupported-original-sdk-image"))?;
    Ok(SdkImageParts { frame, substitutions, exchange_inner_key, unavailable })
}

#[cfg(test)]
mod tests {
    use super::*;

    // 向量来源：C:\Users\ADMINI~1\AppData\Local\Temp\deveco\gen_p2_vectors.py
    // （Python 参考实现 `phone_sdk_materials_v5.py` 在 PC 上对真实资产跑出）。
    const CONFIG_PATH: &str =
        concat!(env!("CARGO_MANIFEST_DIR"), "\\..\\entry\\src\\main\\resources\\rawfile\\hg_sdk\\sdk-app-config.encoded");
    const IMAGE_PATH: &str =
        concat!(env!("CARGO_MANIFEST_DIR"), "\\..\\entry\\libs\\arm64-v8a\\libmetasec_ml.so");

    fn read_file(path: &str) -> Vec<u8> {
        std::fs::read(path).unwrap_or_else(|e| panic!("读取 {path} 失败：{e}（host 测试须在仓库内运行）"))
    }

    #[test]
    fn decode_app_config_matches_python() {
        let encoded = read_file(CONFIG_PATH);
        let materials = decode_app_config(&encoded, "8662").unwrap();
        assert_eq!(
            hex::encode(materials.signing_key),
            "b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d"
        );
        assert_eq!(
            hex::encode(materials.exchange_key),
            "6fda42c82dc6084103cb078972edb06fa33ceb7a623b8a9d045c773a8602486c"
        );
    }

    #[test]
    fn decode_app_config_rejects_bad_input() {
        assert!(decode_app_config(&[0u8; 303], "8662").is_err());
        assert!(decode_app_config(&[0u8; 304], "8662").is_err());
        assert!(decode_app_config(&read_file(CONFIG_PATH), "1967").is_err());
    }

    #[test]
    fn read_sdk_image_matches_python() {
        let image = read_file(IMAGE_PATH);
        let parts = read_sdk_image(&image).unwrap();
        assert_eq!(hex::encode(parts.frame), "2d4b4fca49750d433fb5ae2c226dcc56");
        assert_eq!(
            hex::encode(parts.exchange_inner_key),
            "782399bdfacedead3230313030343034"
        );
        assert_eq!(parts.unavailable, "!notset!");
        assert_eq!(
            hex::encode(Sha256::digest(parts.substitutions)),
            "e9d1231f6646212e4360944ea29e8698f1e5fa655ed1e88ea3fa0370de730ec9"
        );
        assert_eq!(
            &parts.substitutions[..32],
            &hex::decode("53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e").unwrap()[..]
        );
        assert_eq!(
            &parts.substitutions[1024 - 32..],
            &hex::decode("0b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e").unwrap()[..]
        );
        assert!(read_sdk_image(&image[..image.len() - 1]).is_err());
    }

    #[test]
    fn pb_encode_matches_python() {
        let big = (1u64 << 45) + 123;
        let out = pb_encode(&[
            (1, PbField::Varint(150)),
            (2, PbField::Str("testing")),
            (3, PbField::Bytes(&[])),
            (4, PbField::Bytes(&[0xde, 0xad, 0xbe, 0xef])),
            (5, PbField::Varint(big)),
            (6, PbField::Str("中文")),
        ]);
        assert_eq!(
            hex::encode(out),
            "089601120774657374696e672204deadbeef28fb8080808080083206e4b8ade69687"
        );
    }

    #[test]
    fn wire_fields_roundtrip() {
        let data = pb_encode(&[
            (1, PbField::Varint(150)),
            (2, PbField::Str("hello")),
            (3, PbField::Bytes(&[0xde, 0xad])),
            (4, PbField::Varint(4294967295)),
        ]);
        let rows = wire_fields(&data, 8192).unwrap();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].number, 1);
        assert_eq!(rows[0].encoding, 0);
        assert_eq!(rows[0].value, WireValue::Varint(150));
        assert_eq!(rows[1].value, WireValue::Bytes(b"hello".to_vec()));
        assert_eq!(rows[2].value, WireValue::Bytes(vec![0xde, 0xad]));
        assert_eq!(rows[3].value, WireValue::Varint(4294967295));
        // 截断 / 非法编码。
        assert!(wire_fields(&data[..data.len() - 1], 8192).is_err());
        assert!(wire_fields(&[0x0f, 0x01], 8192).is_err());
        assert!(wire_fields(&data, 4).is_err());
    }
}
