//! Signing for the v04.10.03 playback endpoint.
//!
//! Protocol data and the transform structure are ported from the GPL-3.0-only
//! `N3urda/hongguoTV` implementation at `18c37c2afd0567520135abcae312352542f09083`
//! (`Signer.kt`, `AesV3.kt`, `V5Constants.kt`, and `MobilePlayback.kt`), and
//! cross-checked against `beilunyang/openhongguo` PR 13 at
//! `788103f6`. The caller supplies the exact gzip bytes that will be sent;
//! this module hashes those bytes and never compresses the payload.

use std::sync::OnceLock;

use base64::Engine as _;
use md5::{Digest, Md5};
use rand::Rng;

use super::sm3::sm3_hash;
use super::v5_tables::{HASH_TABLE, SBOX};

const APP_ID: i64 = 8662;
const VERSION_CODE: &str = "74332";
const VERSION_NAME: &str = "7.4.3.32";
const CHANNEL: &str = "vivo_8662_64";
const DEVICE_TYPE: &str = "PGT-AN10";
const OS_VERSION: &str = "12";
const LICENSE: i64 = 646_637_794;
const USER_AGENT: &str =
    "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)";

const MAGIC: [u8; 16] = [
    0x2d, 0x4b, 0x4f, 0xca, 0x49, 0x75, 0x0d, 0x43, 0x3f, 0xb5, 0xae, 0x2c, 0x22, 0x6d, 0xcc, 0x56,
];
const SIGN_KEY: [u8; 32] = [
    0xb2, 0x3c, 0x2a, 0x47, 0x0a, 0x20, 0xd1, 0x05, 0xdc, 0x3f, 0x8c, 0x44, 0x38, 0xf8, 0x27, 0x2e,
    0xd4, 0x6d, 0x6c, 0x89, 0xff, 0xdc, 0xde, 0xdd, 0x51, 0x08, 0x69, 0x8d, 0x26, 0xe9, 0x48, 0x9d,
];

const BASE64_URL_NO_PAD: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// Anonymous device values carried in the V5 query and Medusa message.
#[derive(Debug, Clone, Default)]
pub struct V5Identity<'a> {
    pub device_id: &'a str,
    pub install_id: &'a str,
    pub cdid: &'a str,
}

/// A request ready to be sent with the caller's original compressed body.
#[derive(Debug, Clone)]
pub struct V5Request {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

struct ProcessState {
    nonce: String,
    started_ms: i64,
}

#[derive(Debug, Clone, Copy)]
struct Entropy {
    helios: u32,
    medusa_nonce: u32,
    packed: u32,
    message: u32,
}

fn le32(value: u32) -> [u8; 4] {
    value.to_le_bytes()
}

fn md5_bytes(data: &[u8]) -> [u8; 16] {
    let digest = Md5::digest(data);
    let mut output = [0u8; 16];
    output.copy_from_slice(&digest);
    output
}

fn process_state(now_ms: i64) -> &'static ProcessState {
    static STATE: OnceLock<ProcessState> = OnceLock::new();
    STATE.get_or_init(|| {
        let mut nonce = [0u8; 18];
        rand::thread_rng().fill(&mut nonce);
        ProcessState {
            nonce: BASE64_URL_NO_PAD.encode(nonce),
            started_ms: now_ms,
        }
    })
}

fn entropy() -> Entropy {
    let mut rng = rand::thread_rng();
    Entropy {
        helios: rng.gen(),
        medusa_nonce: rng.gen(),
        packed: rng.gen(),
        message: rng.gen(),
    }
}

fn varint(mut value: u64, output: &mut Vec<u8>) {
    while value > 0x7f {
        output.push(((value & 0x7f) as u8) | 0x80);
        value >>= 7;
    }
    output.push(value as u8);
}

const fn zigzag(value: i64) -> u64 {
    if value < 0 {
        value.wrapping_neg().wrapping_mul(2).wrapping_sub(1) as u64
    } else {
        (value as u64) * 2
    }
}

enum Field {
    Sint(i64),
    Bytes(Vec<u8>),
}

fn proto(fields: &[(u32, Field)]) -> Vec<u8> {
    let mut output = Vec::new();
    for (tag, field) in fields {
        match field {
            Field::Sint(value) => {
                varint((*tag as u64) << 3, &mut output);
                varint(zigzag(*value), &mut output);
            }
            Field::Bytes(value) => {
                if value.is_empty() {
                    continue;
                }
                varint(((*tag as u64) << 3) | 2, &mut output);
                varint(value.len() as u64, &mut output);
                output.extend_from_slice(value);
            }
        }
    }
    output
}

fn string_field(tag: u32, value: &str) -> (u32, Field) {
    (tag, Field::Bytes(value.as_bytes().to_vec()))
}

fn bytes_field(tag: u32, value: &[u8]) -> (u32, Field) {
    (tag, Field::Bytes(value.to_vec()))
}

fn get_iv(initial: u32, data: &[u8]) -> u32 {
    let mut value = initial;
    for (index, byte) in data.iter().enumerate() {
        value = if index & 1 == 0 {
            (value >> 4) ^ value ^ value.wrapping_shl(6) ^ (*byte as u32)
        } else {
            !((value >> 7) ^ value ^ ((*byte as u32) | value.wrapping_shl(12)))
        };
    }
    value
}

fn branch_iv(query_hash: &[u8; 32], body_md5: &[u8; 16], ts: u32) -> u32 {
    let step = get_iv(0x2023_0928, query_hash);
    let step = get_iv(step, body_md5);
    get_iv(step, &le32(ts))
}

fn sum_md5(data: &[u8; 16]) -> u32 {
    let mut check = 0x2022_0420u32;
    for (index, byte) in data.iter().take(12).enumerate() {
        let shift = if index & 1 == 0 { 3 } else { 5 };
        let temp = (check >> shift) ^ check;
        check = if index & 1 == 0 {
            (*byte as u32) ^ check.wrapping_shl(7)
        } else {
            !((*byte as u32) | check.wrapping_shl(11))
        };
        check ^= temp;
    }
    (check | 4) ^ 0x0100_0000
}

fn hash_f13_v5(query_hash: &[u8; 32], body_md5: &[u8; 16], ts: u32) -> [u8; 20] {
    // The seed, schedule, state layout and tag are V5 wire constants from the
    // public implementations above. They are intentionally transcribed with
    // explicit indices; do not "simplify" them into another hash family.
    const SEED: u32 = 0x9d4a_97c2;
    const ROUNDS: [usize; 11] = [96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7];
    const INITIAL: [u32; 8] = [
        0x7aba_4fc8,
        0x6716_6507,
        0x6403_fa00,
        0x340f_512f,
        984_304_912,
        3_005_047_866,
        2_874_125_293,
        2_152_413_264,
    ];

    let count = SEED.wrapping_add(ts);
    let table = HASH_TABLE.map(|value| value.rotate_right(count.wrapping_add(1) & 255));

    let shift = count.wrapping_add(2) & 7;
    let mut pad = [0u8; 4];
    for (index, value) in [0xfa_u32, 0x45, 0x61, 0xd7].iter().enumerate() {
        pad[index] = ((value | (value << 8)) >> shift) as u8;
    }

    let mut data = Vec::with_capacity(64);
    data.extend_from_slice(query_hash);
    data.extend_from_slice(body_md5);
    data.extend_from_slice(&le32(ts));
    data.extend_from_slice(&pad);
    data.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0x01, 0xa0]);

    let mut words: Vec<u32> = data
        .as_chunks::<4>()
        .0
        .iter()
        .map(|chunk| u32::from_be_bytes(*chunk))
        .collect();
    for index in 0..112 {
        let x = words[index + 1];
        let y = words[index + 14];
        let value = words[index]
            .wrapping_add(words[index + 9])
            .wrapping_add(x.rotate_left(14) ^ x.rotate_left(25) ^ (x >> 3))
            .wrapping_add(y.rotate_left(13) ^ y.rotate_left(15) ^ (y >> 10));
        words.push(value);
    }

    let initial = INITIAL.map(|value| value.rotate_right(count));
    let mut state = initial;
    for index in 0..ROUNDS[0] {
        let base = SEED.wrapping_add(index as u32);
        let n1 = ((state[ROUNDS[3]] ^ state[ROUNDS[4]]) & state[ROUNDS[1]]) ^ state[ROUNDS[3]];
        let x = state[ROUNDS[1]];
        let n2 = x.rotate_left(26) ^ x.rotate_left(21) ^ x.rotate_left(7);
        let n4 = words[(base & 127) as usize]
            .wrapping_add(n1)
            .wrapping_add(n2)
            .wrapping_add(table[(base & 63) as usize])
            .wrapping_add(state[ROUNDS[5]]);
        let y = state[ROUNDS[2]];
        let n5 = y.rotate_left(30) ^ y.rotate_left(19) ^ y.rotate_left(10);
        let n6 = (y & state[ROUNDS[6]]) | ((y | state[ROUNDS[6]]) & state[ROUNDS[7]]);
        let old = state[ROUNDS[9]];
        state.rotate_right(1);
        state[ROUNDS[10]] = n5.wrapping_add(n6).wrapping_add(n4);
        state[ROUNDS[8]] = old.wrapping_add(n4);
    }

    let mut expanded = [0u8; 32];
    for (index, value) in state.iter().enumerate() {
        let encoded = value.wrapping_add(initial[index]).to_be_bytes();
        expanded[index * 4..index * 4 + 4].copy_from_slice(&encoded);
    }

    let mut folded = [0u8; 16];
    for index in 0..16 {
        folded[index] = expanded[index] ^ expanded[index + 16];
    }

    let mut output = [0u8; 20];
    output[..16].copy_from_slice(&folded);
    output[16..].copy_from_slice(&le32(sum_md5(&folded) | 0x20));
    output
}

fn xmxor(data: &[u8], key: &[u8]) -> Vec<u8> {
    let length = data.len();
    let mut encoded = vec![0u8; length];

    for (index, value) in data.iter().enumerate() {
        let at = (index * 4) & 28;
        let d0 = key[at] as u32;
        let d1 = key[at + 1] as u32;
        let value = *value as u32;
        let mut mixed = ((((value << 4) | (value >> 4)) & 0xff) + d0) & 0xff;
        mixed = (!mixed) ^ d1;
        let masked = mixed & 0xff;
        mixed = ((((masked << 3) | (masked >> 5)) & 0xff) + d1) & 0xff;
        mixed = (mixed ^ d0) & 0xff;
        encoded[length - index - 1] = (!mixed) as u8;
    }

    let last = encoded[length - 1] ^ encoded[length - 2];
    let first = encoded[0];
    encoded[0] = (!last).wrapping_add(first);
    encoded[1] = (encoded[0] ^ encoded[length - 1] ^ 0xfe).wrapping_add(encoded[1]);
    encoded[2] = encoded[2].wrapping_add(last.wrapping_sub(first) ^ encoded[1].rotate_left(3) ^ 2);

    for index in 0..length - 4 {
        let temp =
            encoded[index + 2].rotate_left(3) ^ encoded[index + 1] ^ (index as u8).wrapping_add(3);
        encoded[index + 3] = (!temp).wrapping_add(encoded[index + 3]);
    }

    encoded[length - 1] ^= encoded[length - 2];
    let total = encoded[1..]
        .iter()
        .fold(0u8, |sum, value| sum.wrapping_add(*value));
    encoded[0] = (encoded[0] ^ encoded[1]).wrapping_add(total);
    encoded
}

struct AesV5 {
    sbox: [u8; 256],
    con: [usize; 4],
    order: [usize; 16],
    keys: [[u8; 4]; 12],
}

impl AesV5 {
    fn new(key: &[u8; 16], ts: u32) -> Self {
        const INITIAL: [u32; 4] = [0xbbb5_de72, 0xd463_8d5b, 0x92a5_f73b, 0x89f8_a1c9];
        const CON: [[usize; 4]; 4] = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]];
        const ORDER: [[usize; 16]; 4] = [
            [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
            [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
            [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
            [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7],
        ];

        let word = (ts & 3) as usize;
        let initial = INITIAL[word];
        let mut sbox = [0u8; 256];
        sbox.copy_from_slice(&SBOX[word * 256..(word + 1) * 256]);

        let mut expanded = [0u8; 48];
        let initial_bytes = initial.to_le_bytes();
        for offset in 0..4 {
            let start = offset * 4;
            expanded[start..start + 4].copy_from_slice(&initial_bytes);
        }
        for index in 0..16 {
            expanded[index] ^= key[index];
        }

        let mut rotation = 8u32;
        for index in 4..12usize {
            let at = 4 * (index - 1);
            let mut a = expanded[at];
            let mut b = expanded[at + 1];
            let mut c = expanded[at + 2];
            let mut d = expanded[at + 3];
            if index & 3 == 0 {
                let mixed = ((initial >> (rotation & 24)) ^ sbox[b as usize] as u32) & 0xff;
                b = sbox[c as usize];
                c = sbox[d as usize];
                d = sbox[a as usize];
                a = mixed as u8;
            }
            rotation = rotation.wrapping_add(2);
            expanded[at + 4] = a ^ expanded[at - 12];
            expanded[at + 5] = b ^ expanded[at - 11];
            expanded[at + 6] = c ^ expanded[at - 10];
            expanded[at + 7] = d ^ expanded[at - 9];
        }

        let mut keys = [[0u8; 4]; 12];
        for index in 0..12 {
            keys[index].copy_from_slice(&expanded[index * 4..index * 4 + 4]);
        }

        Self {
            sbox,
            con: CON[word],
            order: ORDER[word],
            keys,
        }
    }

    #[allow(clippy::needless_range_loop)] // The row and column indices are wire positions.
    fn add_con(&self, rows: &mut [[u8; 4]; 4], start: usize) {
        for row in 0..4 {
            for column in 0..4 {
                rows[row][column] ^= self.keys[start + row][self.con[column]];
            }
        }
    }

    #[allow(clippy::needless_range_loop)] // This transform is transcribed with explicit matrix indices.
    fn block(&self, value: &[u8; 16]) -> [u8; 16] {
        let mut rows = [[0u8; 4]; 4];
        for row in 0..4 {
            rows[row].copy_from_slice(&value[row * 4..row * 4 + 4]);
        }
        self.add_con(&mut rows, 0);

        for round in 1..=2 {
            for row in 0..4 {
                for column in 0..4 {
                    rows[row][column] = self.sbox[rows[row][column] as usize];
                }
            }

            let previous = rows;
            for row in 0..4 {
                rows[row] = previous[self.con[row]];
            }

            let mut flat = [0u8; 16];
            for row in 0..4 {
                flat[row * 4..row * 4 + 4].copy_from_slice(&rows[row]);
            }
            for index in 0..16 {
                rows[index / 4][index % 4] = flat[self.order[index]];
            }

            if round == 1 {
                for row in 0..4 {
                    let previous = rows[row];
                    for column in 0..4 {
                        rows[row][column] = previous[self.con[column]];
                    }
                }

                let double = |value: u8| (value << 1) ^ if value & 0x80 != 0 { 0x1b } else { 0 };
                for column in 0..4 {
                    let sum = rows[0][column] ^ rows[1][column] ^ rows[2][column] ^ rows[3][column];
                    let first = rows[0][column];
                    rows[0][column] ^= sum ^ double(rows[0][column] ^ rows[1][column]);
                    rows[1][column] ^= sum ^ double(rows[1][column] ^ rows[2][column]);
                    rows[2][column] ^= sum ^ double(rows[2][column] ^ rows[3][column]);
                    rows[3][column] ^= sum ^ double(rows[3][column] ^ first);
                }
            }

            self.add_con(&mut rows, round * 4);
        }

        for row in 0..4 {
            for column in 0..4 {
                rows[row][column] ^= self.keys[4 + row][column];
            }
        }

        let mut output = [0u8; 16];
        for row in 0..4 {
            output[row * 4..row * 4 + 4].copy_from_slice(&rows[row]);
        }
        output
    }

    #[allow(clippy::needless_range_loop)] // The bit positions are protocol data, not iterator order.
    fn encrypt(&self, source: &[u8], iv: &[u8; 16]) -> Result<Vec<u8>, String> {
        const WIRE: [u8; 8] = [6, 5, 3, 4, 2, 7, 1, 0];
        const COMPACT: [u8; 8] = [1, 7, 3, 6, 2, 0, 4, 5];

        if source.len() < 248 {
            return Err("V5 AES payload is shorter than 248 bytes".to_string());
        }

        let mut plain = [0u8; 32];
        for index in 0..31 {
            for position in 0..8 {
                let bit = (source[index * 8 + position] >> WIRE[position]) & 1;
                plain[index] |= bit << COMPACT[position];
            }
        }
        plain[31] = 1;

        let mut head = [0u8; 16];
        for index in 0..16 {
            head[index] = plain[index] ^ iv[index];
        }
        let first = self.block(&head);

        let mut tail = [0u8; 16];
        for index in 0..16 {
            tail[index] = plain[16 + index] ^ first[index];
        }
        let second = self.block(&tail);

        let mut bits = [0u8; 32];
        bits[..16].copy_from_slice(&first);
        bits[16..].copy_from_slice(&second);

        let mut output = source.to_vec();
        for index in 0..31 {
            for position in 0..8 {
                let at = index * 8 + position;
                let bit = (bits[index] >> COMPACT[position]) & 1;
                output[at] = (output[at] & !(1 << WIRE[position])) | ((bit) << WIRE[position]);
            }
        }

        let mut result = Vec::with_capacity(output.len() + 1);
        result.push(bits[31]);
        result.extend_from_slice(&output);
        Ok(result)
    }
}

fn helios(ts: u32, random: u32) -> String {
    super::ladon::ladon_encrypt(ts as i64, LICENSE, APP_ID, &le32(random))
}

fn medusa(
    query_hash: &[u8; 32],
    body_md5: &[u8; 16],
    ts: u32,
    identity: &V5Identity<'_>,
    state: &ProcessState,
    entropy: Entropy,
) -> Result<String, String> {
    let app_id = APP_ID.to_string();
    let license = LICENSE.to_string();
    let f13 = hash_f13_v5(query_hash, body_md5, ts);
    let flags = [0u8; 8];

    let device = proto(&[
        (1, Field::Sint(1)),
        (2, Field::Sint(2)),
        string_field(3, &app_id),
        string_field(4, identity.device_id),
        string_field(5, &state.nonce),
        string_field(6, "!noperm!"),
        string_field(12, "Asia/Shanghai,8"),
        string_field(13, "zh_CN"),
        string_field(22, OS_VERSION),
        (25, Field::Sint(state.started_ms)),
        string_field(30, DEVICE_TYPE),
        string_field(31, "HONOR"),
        string_field(32, DEVICE_TYPE),
        string_field(34, "HONOR"),
    ]);

    let environment = proto(&[
        string_field(6, "v04.10.03.04-bugfix"),
        string_field(8, CHANNEL),
        bytes_field(12, &device),
        string_field(14, VERSION_NAME),
    ]);

    let message = proto(&[
        bytes_field(1, &MAGIC),
        (2, Field::Sint(5)),
        (3, Field::Sint(entropy.message as i64)),
        string_field(4, &app_id),
        string_field(5, identity.device_id),
        string_field(6, &license),
        string_field(7, VERSION_NAME),
        string_field(8, "v04.10.03-ml-android"),
        (9, Field::Sint(0x040a_0300)),
        bytes_field(10, &flags),
        (12, Field::Sint(ts as i64)),
        bytes_field(13, &f13),
        bytes_field(14, &query_hash[..6]),
        (
            15,
            Field::Bytes(proto(&[
                (1, Field::Sint(1)),
                (2, Field::Sint(1)),
                (3, Field::Sint(1)),
                (5, Field::Sint(1)),
            ])),
        ),
        (17, Field::Sint(ts as i64)),
        string_field(20, "none"),
        (21, Field::Sint(377)),
        bytes_field(23, &environment),
        string_field(
            24,
            r#"{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}"#,
        ),
    ]);

    let mut seed_input = Vec::with_capacity(68);
    seed_input.extend_from_slice(&SIGN_KEY);
    seed_input.extend_from_slice(&le32(entropy.medusa_nonce));
    seed_input.extend_from_slice(&SIGN_KEY);
    let seed_hash = sm3_hash(&seed_input);

    let high = (entropy.medusa_nonce >> 16) & 0xff;
    let seed_word = (high.wrapping_shl(11) | (entropy.medusa_nonce >> 24)) ^ (high >> 5) ^ high;
    let seed = le32(!seed_word);

    let mut transformed = flags.to_vec();
    transformed.extend_from_slice(&xmxor(&message, &seed_hash));
    transformed.reverse();
    for (index, value) in transformed.iter_mut().enumerate() {
        *value ^= seed[3 - (index & 3)];
    }

    let check =
        0x1800_0001u32 | (((query_hash[0] as u32) & 63) << 14) | (((f13[0] as u32) & 63) << 8);
    let mut packed = Vec::with_capacity(11 + transformed.len());
    packed.push(0xca);
    packed.extend_from_slice(&le32(entropy.packed));
    packed.extend_from_slice(&le32(check));
    packed.extend_from_slice(&transformed);
    packed.push((entropy.medusa_nonce >> 16) as u8);
    packed.push((entropy.medusa_nonce >> 24) as u8);

    let key = md5_bytes(&SIGN_KEY[..16]);
    let iv = md5_bytes(&SIGN_KEY[16..]);
    let encrypted = AesV5::new(&key, ts).encrypt(&packed, &iv)?;

    let mut prefix = le32(5).to_vec();
    prefix.extend_from_slice(&MAGIC);
    let timestamp = le32(ts);
    for (index, value) in prefix.iter_mut().enumerate() {
        *value ^= timestamp[index & 3];
    }

    let mut output = prefix;
    output.push(entropy.medusa_nonce as u8);
    output.push((entropy.medusa_nonce >> 8) as u8);
    output.push(0);
    output.push(1);
    output.extend_from_slice(&encrypted);
    Ok(base64::engine::general_purpose::STANDARD.encode(output))
}

fn encode_component(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' | b'~' => {
                output.push(byte as char);
            }
            _ => output.push_str(&format!("%{byte:02X}")),
        }
    }
    output
}

/// The player-version query bag shared by the v5 door and the `video_tab`
/// fallback.
///
/// Identity fields stay as placeholders: the request layer substitutes the
/// pooled device that signs the call, so both doors are always asked under one
/// identity.
/// The player-version identity bag every playback door starts from.
fn playback_query(
    identity: &V5Identity<'_>,
    ticket: i64,
    app_id: &str,
    extra: &[(&str, &str)],
) -> String {
    let pairs = [
        ("aid", app_id),
        ("app_name", "novelread"),
        ("version_code", VERSION_CODE),
        ("version_name", VERSION_NAME),
        ("channel", CHANNEL),
        ("device_platform", "android"),
        ("device_type", DEVICE_TYPE),
        ("os_version", OS_VERSION),
        ("update_version_code", VERSION_CODE),
        ("iid", identity.install_id),
        ("cdid", identity.cdid),
        ("device_id", identity.device_id),
    ];
    let mut query = String::new();
    for (key, value) in pairs {
        if !query.is_empty() {
            query.push('&');
        }
        query.push_str(&encode_component(key));
        query.push('=');
        query.push_str(&encode_component(value));
    }
    // Door-specific parameters sit between the identity bag and the ticket, so a
    // POST keeps the original byte order and a GET only appends its own fields.
    for (key, value) in extra {
        query.push('&');
        query.push_str(&encode_component(key));
        query.push('=');
        query.push_str(&encode_component(value));
    }
    query.push_str("&_rticket=");
    query.push_str(&ticket.to_string());
    query
}

/// Signs one request for `/novel/player/multi_video_model/player/v1`.
///
/// `compressed_body` must be the exact gzip-compressed bytes that the HTTP
/// client sends. `base` must be the endpoint URL without a query string.
pub fn sign_playback_v5(
    base: &str,
    compressed_body: &[u8],
    identity: &V5Identity<'_>,
) -> Result<V5Request, String> {
    sign_v5_request(base, &[], Some(compressed_body), identity)
}

/// Signs a `GET` for a door of the same family, e.g. the `video_tab` model door.
///
/// `extra` carries the door's own query fields. A `GET` carries no body, so the
/// digest that selects the branch is the digest of zero bytes and the
/// body-describing headers (`Content-Type`, `Content-Encoding`, `x-ss-stub`)
/// are omitted: sending them without a body is what made the generic-signature
/// attempt answer `HTTP 200` with zero bytes in 72-139 ms.
pub fn sign_playback_v5_get(
    base: &str,
    extra: &[(&str, &str)],
    identity: &V5Identity<'_>,
) -> Result<V5Request, String> {
    sign_v5_request(base, extra, None, identity)
}

fn sign_v5_request(
    base: &str,
    extra: &[(&str, &str)],
    body: Option<&[u8]>,
    identity: &V5Identity<'_>,
) -> Result<V5Request, String> {
    if base.is_empty() {
        return Err("V5 playback base URL is empty".to_string());
    }
    if base.contains('?') || base.contains('#') {
        return Err("V5 playback base URL must not contain a query or fragment".to_string());
    }
    if identity.device_id.is_empty() || identity.install_id.is_empty() || identity.cdid.is_empty() {
        return Err("V5 playback identity is incomplete".to_string());
    }

    let now_ms = crate::timeutil::now_millis();
    let ts = u32::try_from(now_ms / 1000)
        .map_err(|_| "V5 playback timestamp is outside the protocol range".to_string())?;
    let body_md5 = md5_bytes(body.unwrap_or(&[]));
    let state = process_state(now_ms);
    let app_id = APP_ID.to_string();

    for offset in 0..1024i64 {
        let ticket = now_ms
            .checked_add(offset)
            .ok_or_else(|| "V5 playback request ticket overflow".to_string())?;
        let query = playback_query(identity, ticket, &app_id, extra);
        let query_hash = sm3_hash(query.as_bytes());
        if branch_iv(&query_hash, &body_md5, ts) & 15 != 12 {
            continue;
        }

        let entropy = entropy();
        let medusa = medusa(&query_hash, &body_md5, ts, identity, state, entropy)?;
        let url = format!("{base}?{query}");
        let mut headers = vec![
            ("x-khronos".to_string(), ts.to_string()),
            ("x-helios".to_string(), helios(ts, entropy.helios)),
            ("x-medusa".to_string(), medusa),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
            ("Accept".to_string(), "application/json".to_string()),
        ];
        if body.is_some() {
            headers.push((
                "Content-Type".to_string(),
                "application/json; charset=utf-8".to_string(),
            ));
            headers.push(("Content-Encoding".to_string(), "gzip".to_string()));
            headers.push(("x-ss-stub".to_string(), hex::encode_upper(body_md5)));
        }
        return Ok(V5Request { url, headers });
    }

    Err("V5 playback signing could not find the branch-12 ticket".to_string())
}

#[cfg(test)]
#[path = "v5_golden_tests.rs"]
mod v5_golden_tests;
