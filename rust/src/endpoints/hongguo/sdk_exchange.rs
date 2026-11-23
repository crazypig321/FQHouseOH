//! SDI token 交换编解码（纯算法）。
//!
//! 移植自 hongguo-drama 参考实现（对拍蓝本：
//! `vendor/phone_account/phone_sdk_exchange_v5.py`）：
//! AES-128-CBC（common 32B：前 16 key/后 16 IV）→ XTEA-CBC 变轮数
//! （`32+8*(nonce_le%5)`，DELTA 0x9e3779b9，魔数 0x20200427/0x20200422/0x20120312）
//! → CRC16-CCITT → zlib；SDI 请求/响应 protobuf 手写编解码。

use std::io::Write as _;

use aes::Aes128;
use cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};

use crate::error::{ApiError, ApiResult};

use super::sdk_materials::{pb_encode, wire_fields, PbField, WireValue};

pub const MAX_PLAIN: usize = 65_536;
const DELTA: u32 = 0x9e37_79b9;

/// SDI 会话交换结果（python: `SdkSessionResult`）。
#[derive(Debug, Clone)]
pub struct SdkSessionResult {
    pub token: String,
    pub status: i64,
}

/// CRC16-CCITT（python: `binascii.crc_hqx(data, 0)`，无反射无 xorout）。
fn crc_hqx(data: &[u8]) -> u16 {
    let mut crc: u16 = 0;
    for byte in data {
        crc ^= (*byte as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 };
        }
    }
    crc
}

fn zigzag_decode(value: u64) -> i64 {
    ((value >> 1) as i64) ^ -((value & 1) as i64)
}

fn xor8(a: &[u8; 8], b: &[u8; 8]) -> [u8; 8] {
    let mut out = *a;
    for i in 0..8 {
        out[i] ^= b[i];
    }
    out
}

/// XTEA-CBC 变轮数链（python: `phone_sdk_exchange_v5.py:33`）。
/// key 16B（4 个大端字），nonce 4B；cycles = 32 + 8*(le32(nonce)%5)。
fn xtea_step(words: &mut [u32; 2], step: u32, key_words: &[u32; 4], decrypt: bool) {
    let target = (step & 1) as usize;
    let total = ((step + 1) / 2).wrapping_mul(DELTA);
    let other = words[1 - target];
    let key_index = (total.wrapping_shr((11 * target) as u32) & 3) as usize;
    let mix = ((other.wrapping_shl(4) ^ (other >> 5)).wrapping_add(other))
        ^ total.wrapping_add(key_words[key_index]);
    if decrypt {
        words[target] = words[target].wrapping_sub(mix);
    } else {
        words[target] = words[target].wrapping_add(mix);
    }
}

fn xtea_chain(data: &[u8], key: &[u8; 16], nonce: &[u8; 4], decrypt: bool) -> ApiResult<Vec<u8>> {
    if data.is_empty() || data.len() % 8 != 0 || data.len() > MAX_PLAIN * 2 {
        return Err(ApiError::internal("invalid-xtea-blocks"));
    }
    let mut key_words = [0u32; 4];
    for (i, word) in key_words.iter_mut().enumerate() {
        *word = u32::from_be_bytes(key[i * 4..i * 4 + 4].try_into().unwrap());
    }
    let cycles = 32 + 8 * (u32::from_le_bytes(*nonce) % 5);
    let mut previous = [0u8; 8];
    previous[..4].copy_from_slice(nonce);
    previous[4..].copy_from_slice(&0x2020_0427u32.to_le_bytes());
    let mut result = Vec::with_capacity(data.len());
    for block in data.chunks(8) {
        let source: [u8; 8] = block.try_into().unwrap();
        let input: [u8; 8] = if decrypt { source } else { xor8(&source, &previous) };
        let mut words = [
            u32::from_be_bytes(input[..4].try_into().unwrap()),
            u32::from_be_bytes(input[4..].try_into().unwrap()),
        ];
        if decrypt {
            for step in (0..cycles * 2).rev() {
                xtea_step(&mut words, step, &key_words, true);
            }
        } else {
            for step in 0..cycles * 2 {
                xtea_step(&mut words, step, &key_words, false);
            }
        }
        let transformed: [u8; 8] = [words[0].to_be_bytes(), words[1].to_be_bytes()]
            .concat()
            .try_into()
            .unwrap();
        let out_block: [u8; 8] = if decrypt { xor8(&transformed, &previous) } else { transformed };
        result.extend_from_slice(&out_block);
        previous = if decrypt { source } else { transformed };
    }
    Ok(result)
}

/// encrypt_payload（python: `phone_sdk_exchange_v5.py:60`）。
pub fn encrypt_payload(
    plaintext: &[u8],
    common: &[u8; 32],
    inner: &[u8; 16],
    nonce: &[u8; 4],
    entropy_byte: u8,
) -> ApiResult<Vec<u8>> {
    if plaintext.len() > MAX_PLAIN {
        return Err(ApiError::internal("invalid-sdk-plaintext"));
    }
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder
        .write_all(plaintext)
        .map_err(|_| ApiError::internal("invalid-sdk-compression"))?;
    let mut compressed = encoder
        .finish()
        .map_err(|_| ApiError::internal("invalid-sdk-compression"))?;
    compressed[0] = 0x78;
    compressed[1] = 0x01;
    let mut container = Vec::with_capacity(4 + compressed.len());
    container.extend_from_slice(&(plaintext.len() as u32).to_le_bytes());
    container.extend_from_slice(&compressed);
    let extra = (-(container.len() as i64)).rem_euclid(8) as usize;
    let position = 1 + (extra + 3) % 4;
    let mut frame = vec![0u8; container.len() + 8 + extra];
    frame[0] = (entropy_byte & 0xf8) | extra as u8;
    frame[position..position + container.len()].copy_from_slice(&container);
    let crc_offset = if position >= 3 { 1 } else { position + container.len() };
    frame[crc_offset..crc_offset + 2].copy_from_slice(&crc_hqx(&container).to_be_bytes());
    let encrypted = xtea_chain(&frame, inner, nonce, false)?;
    let mut wrapped = Vec::with_capacity(encrypted.len() + 5);
    wrapped.push(encrypted[0] ^ 3);
    wrapped.extend_from_slice(&encrypted);
    wrapped.extend_from_slice(nonce);
    let encryptor = cbc::Encryptor::<Aes128>::new_from_slices(&common[..16], &common[16..])
        .map_err(|_| ApiError::internal("invalid-sdk-exchange-materials"))?;
    Ok(encryptor.encrypt_padded_vec_mut::<Pkcs7>(&wrapped))
}

/// decrypt_payload（python: `phone_sdk_exchange_v5.py:81`）。
/// `response_frame=true` 跳过 CRC16（响应协议未确立该填充为 CRC）。
pub fn decrypt_payload(
    ciphertext: &[u8],
    common: &[u8; 32],
    inner: &[u8; 16],
    response_frame: bool,
) -> ApiResult<Vec<u8>> {
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 || ciphertext.len() > MAX_PLAIN * 2 {
        return Err(ApiError::internal("invalid-sdk-ciphertext"));
    }
    let decryptor = cbc::Decryptor::<Aes128>::new_from_slices(&common[..16], &common[16..])
        .map_err(|_| ApiError::internal("invalid-sdk-exchange-materials"))?;
    let wrapped = decryptor
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .map_err(|_| ApiError::internal("invalid-sdk-padding"))?;
    if wrapped.len() < 13 || (wrapped.len() - 5) % 8 != 0 || wrapped[0] ^ wrapped[1] != 3 {
        return Err(ApiError::internal("invalid-sdk-outer-frame"));
    }
    let nonce: [u8; 4] = wrapped[wrapped.len() - 4..].try_into().unwrap();
    let frame = xtea_chain(&wrapped[1..wrapped.len() - 4], inner, &nonce, true)?;
    let extra = (frame[0] & 7) as usize;
    let length = frame.len() as isize - 8 - extra as isize;
    let position = 1 + (extra + 3) % 4;
    if length < 4 {
        return Err(ApiError::internal("invalid-sdk-inner-frame"));
    }
    let length = length as usize;
    let container = &frame[position..position + length];
    let crc_offset = if position >= 3 { 1 } else { position + length };
    if !response_frame && frame[crc_offset..crc_offset + 2] != crc_hqx(container).to_be_bytes() {
        return Err(ApiError::internal("invalid-sdk-inner-checksum"));
    }
    let expected_size = u32::from_le_bytes(container[..4].try_into().unwrap()) as usize;
    if expected_size > MAX_PLAIN {
        return Err(ApiError::internal("sdk-response-too-large"));
    }
    inflate_bounded(&container[4..], expected_size)
}

/// 有界 zlib 解压（对齐 python `zlib.decompressobj` 的 max_length/eof/
/// unconsumed_tail/unused_data 语义：解出长度必须精确、流必须终结、
/// 输入必须被流完整消费）。
fn inflate_bounded(input: &[u8], expected_size: usize) -> ApiResult<Vec<u8>> {
    if expected_size > MAX_PLAIN {
        return Err(ApiError::internal("sdk-response-too-large"));
    }
    let mut decoder = flate2::Decompress::new(true);
    let mut out = vec![0u8; expected_size + 1];
    let status = decoder
        .decompress(input, &mut out, flate2::FlushDecompress::None)
        .map_err(|_| ApiError::internal("invalid-sdk-compression"))?;
    let decoded = decoder.total_out() as usize;
    let consumed = decoder.total_in() as usize;
    if decoded != expected_size
        || status != flate2::Status::StreamEnd
        || consumed != input.len()
    {
        return Err(ApiError::internal("invalid-sdk-decoded-size"));
    }
    out.truncate(expected_size);
    Ok(out)
}

/// exchange_request（python: `phone_sdk_exchange_v5.py:120`）：
/// SDI get_token 请求体（protobuf：魔数 0x20200422*2、类型、密文、时间戳）。
pub fn exchange_request(
    plaintext: &[u8],
    milliseconds: u64,
    common: &[u8; 32],
    inner: &[u8; 16],
    nonce: &[u8; 4],
    entropy_byte: u8,
) -> ApiResult<Vec<u8>> {
    if milliseconds >= 1 << 63 {
        return Err(ApiError::internal("invalid-sdk-request-time"));
    }
    let ciphertext = encrypt_payload(plaintext, common, inner, nonce, entropy_byte)?;
    Ok(pb_encode(&[
        (1, PbField::Varint(0x2020_0422 * 2)),
        (2, PbField::Varint(2)),
        (3, PbField::Varint(2)),
        (4, PbField::Bytes(&ciphertext)),
        (5, PbField::Varint(milliseconds * 2)),
    ]))
}

/// exchange_response（python: `phone_sdk_exchange_v5.py:127`）：
/// 校验响应头（魔数 0x20120312*2）→ 解密 field 6 → 会话 token/status。
pub fn exchange_response(
    packet: &[u8],
    common: &[u8; 32],
    inner: &[u8; 16],
) -> ApiResult<SdkSessionResult> {
    let mut field1: Option<u64> = None;
    let mut field2: Option<u64> = None;
    let mut code: Option<u64> = None;
    let mut ciphertext: Option<Vec<u8>> = None;
    for row in wire_fields(packet, MAX_PLAIN * 2)? {
        match row.number {
            1 | 2 => {
                let WireValue::Varint(value) = row.value else {
                    return Err(ApiError::internal("invalid-sdk-response-header"));
                };
                let slot = if row.number == 1 { &mut field1 } else { &mut field2 };
                match slot {
                    Some(prev) if *prev != value => {
                        return Err(ApiError::internal("invalid-sdk-response-header"));
                    }
                    Some(_) => {}
                    None => *slot = Some(value),
                }
            }
            3 => {
                let WireValue::Varint(value) = row.value else {
                    return Err(ApiError::internal("invalid-sdk-response-status"));
                };
                code = Some(value);
            }
            6 => {
                let WireValue::Bytes(value) = row.value else {
                    return Err(ApiError::internal("invalid-sdk-response-ciphertext"));
                };
                if ciphertext.is_some() {
                    return Err(ApiError::internal("invalid-sdk-response-ciphertext"));
                }
                ciphertext = Some(value);
            }
            _ => continue,
        }
    }
    if field1 != Some(0x2012_0312 * 2) || field2 != Some(2) {
        return Err(ApiError::internal("invalid-sdk-response-header"));
    }
    let Some(ciphertext) = ciphertext else {
        if let Some(c) = code {
            return Err(ApiError::internal(format!(
                "sdk-exchange-refused:{}",
                zigzag_decode(c)
            )));
        }
        return Err(ApiError::internal("missing-sdk-response-ciphertext"));
    };
    let decoded = decrypt_payload(&ciphertext, common, inner, true)?;
    let mut token_field: Option<Vec<u8>> = None;
    let mut status_field: Option<u64> = None;
    for row in wire_fields(&decoded, 8192)? {
        match row.number {
            1 => {
                let WireValue::Bytes(value) = row.value else {
                    return Err(ApiError::internal("invalid-sdk-session-fields"));
                };
                if token_field.replace(value).is_some() {
                    return Err(ApiError::internal("invalid-sdk-session-fields"));
                }
            }
            2 => {
                let WireValue::Varint(value) = row.value else {
                    return Err(ApiError::internal("invalid-sdk-session-fields"));
                };
                if status_field.replace(value).is_some() {
                    return Err(ApiError::internal("invalid-sdk-session-fields"));
                }
            }
            _ => continue,
        }
    }
    let (Some(token_bytes), Some(status_raw)) = (token_field, status_field) else {
        return Err(ApiError::internal("incomplete-sdk-session"));
    };
    let status = zigzag_decode(status_raw);
    if status != 200 && status != 202 {
        return Err(ApiError::internal(format!("sdk-session-status:{status}")));
    }
    if token_bytes.is_empty() || token_bytes.len() > 256 {
        return Err(ApiError::internal("invalid-sdk-session-token"));
    }
    let token = String::from_utf8(token_bytes)
        .map_err(|_| ApiError::internal("invalid-sdk-session-token"))?;
    if !token.chars().all(|c| (33..=126).contains(&(c as u32))) {
        return Err(ApiError::internal("invalid-sdk-session-token"));
    }
    Ok(SdkSessionResult { token, status })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest;

    // 向量来源：C:\Users\ADMINI~1\AppData\Local\Temp\deveco\gen_p2_vectors.py
    // （Python 参考实现在 PC 上对固定确定性输入跑出）。

    fn det(n: usize, seed: &str) -> Vec<u8> {
        let mut out = Vec::new();
        let mut i = 0u32;
        while out.len() < n {
            let mut hasher = sha2::Sha256::new();
            hasher.update(seed.as_bytes());
            hasher.update(i.to_string().as_bytes());
            out.extend_from_slice(&hasher.finalize());
            i += 1;
        }
        out.truncate(n);
        out
    }

    const COMMON: &[u8; 32] =
        hex_literal_common();
    const INNER: &[u8; 16] = hex_literal_inner();

    const fn hex_literal_common() -> &'static [u8; 32] {
        &[
            0xd2, 0xc7, 0xc6, 0x01, 0x23, 0x15, 0x05, 0x5a, 0xd5, 0x7a, 0xf5, 0xd8, 0xb5, 0xfd,
            0xaa, 0x10, 0xc4, 0xe8, 0x01, 0x07, 0x27, 0xaf, 0xda, 0x72, 0xc9, 0xff, 0x07, 0xd0,
            0x52, 0x7d, 0xac, 0xe1,
        ]
    }

    const fn hex_literal_inner() -> &'static [u8; 16] {
        &[
            0xb9, 0x93, 0x8e, 0xb2, 0x45, 0xe6, 0xad, 0x3a, 0x5d, 0xcc, 0x14, 0xff, 0xb7, 0x68,
            0x12, 0xdc,
        ]
    }

    #[test]
    fn crc_hqx_known_vector() {
        // binascii.crc_hqx（XMODEM：init 0）的 "123456789" 校验值。
        assert_eq!(crc_hqx(b"123456789"), 0x31c3);
    }

    #[test]
    fn xtea_chain_matches_python() {
        let data = hex::decode("e14b17409b45843ab2d17ed3a09525a6a8981aaa101ac3e0193a56c4e1848205239af5b4d6efddefb46fb9ae35e53c73c05a12207654373b4a28f6f1b9338e55").unwrap();
        let key: [u8; 16] = hex::decode("73eb0c7aa8a21ec7d9749f78ba63c3f1").unwrap().try_into().unwrap();
        let expected = [
            "3283793ae9803986c9159be3ae4f4770a36d02f05f9359350125bd79b79935317b64fa581d9f98a8751aba2f2a0e49772052f97e101e7b77564cdbbe3d90bcee",
            "21a28d048cbbe811da2fd164c2d4a1d8c804bfc7ea43116468a0397cc0b3412e6c254d5844dd9805126c6b88dc30eee06399c6489f725ba64e9b4fef663c72f1",
            "85e3dca0856544139923812fa8c96016922c9551b745c86fecc7fb09a0cdb76da7dec115a064e4b784f237593ff48d4319dcd79dd77a765ded692f65746a92b6",
            "1dfe687a195752b8dd3fe3a5fabf881321e8fe43fce04c02969461e1f24149ce3795c1f93a56883e5904e976d041aea1ad1d2a98fe70764bb9f96b379abe226e",
            "b0f10ef89d7dba76408ff3da1d0df3c542652082bb64ff01fa6ab033914fe07499bb794372e01625c5f9b1d3a18a527ec1baed0b9c9dc5f883cb33b5360bf15b",
        ];
        for (m, expected) in expected.iter().enumerate() {
            let nonce: [u8; 4] = (m as u32 * 0x11111111 + 7).to_le_bytes();
            let enc = xtea_chain(&data, &key, &nonce, false).unwrap();
            assert_eq!(hex::encode(&enc), *expected);
            // 解密回环。
            let dec = xtea_chain(&enc, &key, &nonce, true).unwrap();
            assert_eq!(dec, data);
        }
    }

    #[test]
    fn encrypt_payload_matches_python() {
        let plaintext = det(200, "ep");
        let nonce: [u8; 4] = hex::decode("44534810").unwrap().try_into().unwrap();
        let out = encrypt_payload(&plaintext, COMMON, INNER, &nonce, 0x5a).unwrap();
        assert_eq!(
            hex::encode(&out),
            "b73d04bbb1bc1481f77e65376c0ec70f7b2f9c175566e37dff9509f78b1ba22afdcf3c26dacac66830beeb0aa50527fc68bb7c2ea205cf2e9af999d956e662cf4dc414d894781d7df7f817e84937adbd6e81da5cb63a6577b3f68129543aa7ae58739654b8e1b1bc0fb4d7ddeac06181cb7dee777a253cbdd7fb7fbe298da8b5794c777caad40aa27ac0ca197a0f0a2bab63147cfec34800b31740ccf0dfe585f8deb0958b316f3112e46bc2644214eac1f6b730f78c475fef14b616c9e3bbffc9f9ff1ae45fc60d6eef1f016e105ac15ed836bdd2e0eb765bd4a10d1c0057be7f3a2c1264f06048922b641e263bd177"
        );
        // Python 加密的向量必须能解回明文（请求帧 CRC 校验）。
        let decrypted = decrypt_payload(&out, COMMON, INNER, false).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn exchange_request_matches_python() {
        let plaintext = det(180, "req");
        let nonce: [u8; 4] = hex::decode("44534810").unwrap().try_into().unwrap();
        let out = exchange_request(&plaintext, 1795000006000, COMMON, INNER, &nonce, 0x37).unwrap();
        assert_eq!(
            hex::encode(&out),
            "08c4908082041002180222e001c7e5dfbdef5bdf15efbeaee86166b999eae38bd4fa8410151f05388ae2b357cbbc362a2a5294bc213d8d5296aafdd55da4dcb7b6ae4c00c4827d9da449750656d68e0aa515369dd5879a3e2c2bf14772deba168bc99535c72569a371d7154e156bd268b8783479ab0e9889e4d1ea9858cbe46cd1daa136e0f1a562b905581a9231bf427041f2316e09f9d72851d33f1ebacf69f3be175d90fa9e4a1a1c1f7aaf367e38886f19730df07ee14ba19a6faa313fe887039cce0dd5f20a6063460ad381236d6e4ceec02adc67156b38deb05d8267cb7d462ec8090288cf199de8f57528e0d5b3e5bd68"
        );
    }

    #[test]
    fn exchange_response_matches_python() {
        let resp200 = hex::decode("08a48c90810410023230cfcb05c3d45bd4b8d2ef4fffc449b184d786a5f66a37da048b5c47f6c86ee40cc214cf7ebcd542125622626419b37c5e").unwrap();
        let resp202 = hex::decode("08a48c90810410023230bac08f8df2d216cec52be0d674cd8bad3376f24c7af6ffdc8288bf425810cffa837d84b36464088b9fe93fe63f21fc38").unwrap();
        let resp_err = hex::decode("08a48c9081041002188201").unwrap();
        let result = exchange_response(&resp200, COMMON, INNER).unwrap();
        assert_eq!(result.token, "TOKEN123-abc");
        assert_eq!(result.status, 200);
        let result = exchange_response(&resp202, COMMON, INNER).unwrap();
        assert_eq!(result.token, "TOKEN202-xyz");
        assert_eq!(result.status, 202);
        let error = exchange_response(&resp_err, COMMON, INNER).unwrap_err();
        assert!(error.to_string().contains("sdk-exchange-refused:65"), "{error}");
        // 头魔数错误。
        let bad_header = hex::decode("08a48c9081041001108201").unwrap();
        assert!(exchange_response(&bad_header, COMMON, INNER).is_err());
    }
}
