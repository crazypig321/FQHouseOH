//! 红果 App 新签名套件（`multi_video_model` POST / `bookapi` 搜索 GET）。
//!
//! 1:1 移植自 hongguoTV `server/vendor/hongguo.cjs`（drpys「红果果[短]」，
//! GPL-3.0；本项目同为 GPL-3.0）。期望值 golden 由
//! `rust/testdata/gen_hongguo_vsign_golden.mjs`（Node vm 钉死
//! `Date.now`/`Math.random` 调用同一 cjs）生成，对拍见本文件 `tests` 与
//! `rust/testdata/hongguo_vsign_golden.json`。
//!
//! 与 [`super::sign`]（guoapp 旧版签名）完全不同的一套：
//! - 固定硬编码设备号（[`DEVICE`]/[`app_device`]），免注册。
//! - `x-gorgon`：8404 版（RC4 变种 + 位变换），见 [`x_gorgon`]。
//! - `x-helios`：md5 种子 34 轮 u64 ARX，见 [`helios`]。
//! - `x-medusa`：[`hash_f13`] 三分支 + 手写 protobuf + 自定义 AES 变体
//!   （[`AesV3`]），见 [`build_medusa`]。
//! - `branchOf` 规避 branch 1（该签名变体服务端不认）：`_rticket` 抖动
//!   最多 32 个偏移，见 [`branch_of`]。
//!
//! 算法块自实测可用的 cjs 移植，勿随意改动常量与位运算顺序。

use base64::Engine as _;
use md5::{Digest, Md5};
use percent_encoding::{utf8_percent_encode, AsciiSet};

use crate::sign::sm3::sm3_hash;

pub(crate) const VIDEO_API: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/";
pub(crate) const APP_SEARCH_API: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/search/tab/v";
pub(crate) const VIDEO_UA: &str = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";
pub(crate) const APP_UA: &str =
    "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)";

/// 固定设备号（cjs `DEVICE`）：免注册，catalog/media/map 全链路共用。
/// 键序即 query 编码序（签名对 query 字节级敏感，勿调换）。
pub(crate) const DEVICE: &[(&str, &str)] = &[
    ("iid", "1905892595382586"),
    ("device_id", "1905892595378490"),
    ("ac", "wifi"),
    ("channel", "update_64"),
    ("aid", "8662"),
    ("app_name", "novelread"),
    ("version_code", "71332"),
    ("version_name", "7.1.3.32"),
    ("device_platform", "android"),
    ("os", "android"),
    ("ssmix", "a"),
    ("device_type", "25053RT47C"),
    ("device_brand", "Redmi"),
    ("language", "zh"),
    ("os_api", "36"),
    ("os_version", "16"),
    ("manifest_version_code", "71332"),
    ("resolution", "1280*2772"),
    ("dpi", "520"),
    ("update_version_code", "71332"),
    ("host_abi", "arm64-v8a"),
    ("dragon_device_type", "phone"),
    ("pv_player", "71332"),
    ("compliance_status", "0"),
    ("need_personal_recommend", "1"),
    ("player_so_load", "1"),
    ("is_android_pad_screen", "0"),
];

/// 搜索用 App 设备号（cjs `APP_DEVICE`）：`DEVICE` 原键序上覆盖 72232 版本字段。
pub(crate) fn app_device() -> Vec<(String, String)> {
    DEVICE
        .iter()
        .map(|(k, v)| {
            let v = match *k {
                "version_code" | "manifest_version_code" | "update_version_code"
                | "pv_player" => "72232",
                "version_name" => "7.2.2.32",
                _ => *v,
            };
            ((*k).to_string(), v.to_string())
        })
        .collect()
}

fn device_field(key: &str) -> &'static str {
    DEVICE
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, v)| *v)
        .unwrap_or("")
}

// ---------- 基础字节工具 ----------

fn md5_digest(data: &[u8]) -> [u8; 16] {
    let mut h = Md5::new();
    h.update(data);
    let out = h.finalize();
    let mut buf = [0u8; 16];
    buf.copy_from_slice(&out);
    buf
}

fn md5_upper_hex(data: &[u8]) -> String {
    hex::encode_upper(md5_digest(data))
}

/// cjs `pythonUrlEncode` 单项：encodeURIComponent + `!'()` 兜底大写编码，
/// 未转义集合为 `A-Za-z0-9-_.~*`（与 python urllib.parse.quote 对齐，
/// 签名对 query 字节级敏感，勿改）。
const PUE_SAFE: &AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~')
    .remove(b'*');

pub(crate) fn pue_one(s: &str) -> String {
    utf8_percent_encode(s, PUE_SAFE).to_string()
}

/// cjs `pythonUrlEncode(values)`：按插入序拼 `k=v&k=v`。
pub(crate) fn python_url_encode(values: &[(String, String)]) -> String {
    values
        .iter()
        .map(|(k, v)| format!("{}={}", pue_one(k), pue_one(v)))
        .collect::<Vec<_>>()
        .join("&")
}

// ---------- protobuf（cjs 专用语义：空字符串跳过字段、sint 走 zigzag） ----------

fn varint(mut n: u64) -> Vec<u8> {
    let mut out = Vec::new();
    while n > 127 {
        out.push(((n & 127) | 128) as u8);
        n >>= 7;
    }
    out.push(n as u8);
    out
}

fn zigzag(n: i64) -> u64 {
    ((n as u64) << 1) ^ ((n >> 63) as u64)
}

enum ProtoVal {
    Str(String),
    Bytes(Vec<u8>),
    Msg(Vec<u8>),
    Float(f64),
    Sint(i64),
}

fn proto_field(tag: u32, val: &ProtoVal) -> Vec<u8> {
    let mut out = Vec::new();
    match val {
        // cjs：undefined/null/'' 均跳过该字段（空串跳过，空 bytes/message 不跳过）。
        ProtoVal::Str(s) => {
            if s.is_empty() {
                return out;
            }
            out.extend(varint(((tag as u64) << 3) | 2));
            out.extend(varint(s.len() as u64));
            out.extend_from_slice(s.as_bytes());
        }
        ProtoVal::Bytes(b) => {
            out.extend(varint(((tag as u64) << 3) | 2));
            out.extend(varint(b.len() as u64));
            out.extend_from_slice(b);
        }
        ProtoVal::Msg(m) => {
            out.extend(varint(((tag as u64) << 3) | 2));
            out.extend(varint(m.len() as u64));
            out.extend_from_slice(m);
        }
        ProtoVal::Float(f) => {
            // writeFloatLE：f64 就近舍入到 f32 小端。
            out.extend(varint(((tag as u64) << 3) | 5));
            out.extend_from_slice(&(*f as f32).to_le_bytes());
        }
        ProtoVal::Sint(v) => {
            out.extend(varint((tag as u64) << 3));
            out.extend(varint(zigzag(*v)));
        }
    }
    out
}

fn proto(fields: &[(u32, ProtoVal)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (tag, val) in fields {
        out.extend(proto_field(*tag, val));
    }
    out
}

/// cjs `deviceProto`：medusa env 字段 12 的设备信息 message。
fn device_proto(device_id: &str) -> Vec<u8> {
    proto(&[
        (1, ProtoVal::Sint(1)),
        (2, ProtoVal::Sint(2)),
        (3, ProtoVal::Str("8662".into())),
        (4, ProtoVal::Str(device_id.into())),
        (5, ProtoVal::Str("Ai6svO3PyrwDOUSmO6ZcResxu".into())),
        (6, ProtoVal::Str("!noperm!".into())),
        (7, ProtoVal::Sint(-888_888)),
        (8, ProtoVal::Sint(-888_888)),
        (9, ProtoVal::Sint(3)),
        (10, ProtoVal::Sint(-888_888)),
        (11, ProtoVal::Str("!notset!".into())),
        (12, ProtoVal::Str("Asia/Shanghai,8".into())),
        (13, ProtoVal::Str("zh_CN".into())),
        (14, ProtoVal::Sint(4)),
        (16, ProtoVal::Float(255.249_938_964_843_75)),
        (17, ProtoVal::Float(35.585_990_905_761_72)),
        (18, ProtoVal::Float(3.467_449_188_232_422)),
        (19, ProtoVal::Float(3.467_449_188_232_422)),
        (20, ProtoVal::Float(255.175_491_333_007_8)),
        (21, ProtoVal::Float(42.175_441_741_943_36)),
        (22, ProtoVal::Str("16".into())),
        (23, ProtoVal::Sint(41)),
        (24, ProtoVal::Sint(36)),
        (25, ProtoVal::Sint(1_728_388_016_635)),
        (26, ProtoVal::Sint(1_728_388_016_635)),
        (27, ProtoVal::Sint(1_728_388_016_635)),
        (28, ProtoVal::Sint(1_728_388_016_637)),
        (29, ProtoVal::Sint(-1)),
        (30, ProtoVal::Str("25053RT47C".into())),
        (31, ProtoVal::Str("Redmi".into())),
        (32, ProtoVal::Str("25053RT47C".into())),
        (33, ProtoVal::Str("25053RT47C".into())),
        (34, ProtoVal::Str("Xiaomi".into())),
        (35, ProtoVal::Str("Redmi".into())),
        (36, ProtoVal::Str("Redmi".into())),
        (38, ProtoVal::Sint(31)),
    ])
}

// ---------- hashF13 三分支（x-medusa 的 query+body+ts 摘要） ----------

/// cjs `getIv`：奇偶交替的 32 位混合迭代。
fn get_iv(mut value: u32, data: &[u8]) -> u32 {
    for (i, &b) in data.iter().enumerate() {
        if (i & 1) == 0 {
            value = (value >> 4) ^ value ^ (value << 6) ^ b as u32;
        } else {
            value = !((value >> 7) ^ value ^ (b as u32 | (value << 12)));
        }
    }
    value
}

/// cjs `sumMd5`：12 字节校验和（多个分支的尾部 4 字节来源）。
fn sum_md5(data: &[u8]) -> u32 {
    assert!(data.len() >= 12, "sumMd5 需要 >=12 字节输入");
    let mut check: u32 = 0x2022_0420;
    for (i, &b) in data.iter().take(12).enumerate() {
        let temp = if (i & 1) == 0 {
            (check >> 3) ^ check
        } else {
            (check >> 5) ^ check
        };
        check = if (i & 1) == 0 {
            (b as u32) ^ (check << 7)
        } else {
            (b as u32) | (check << 11)
        };
        if (i & 1) != 0 {
            check = !check;
        }
        check ^= temp;
    }
    (check | 4) ^ 0x0100_0000
}

const BRANCH2_SV: [u32; 64] = [
    0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef,
    0xb2bbad73, 0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b,
    0x31d833ee, 0x953fce64, 0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177,
    0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e, 0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9,
    0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28, 0x66c4ff96, 0x51716443, 0x0dd2fc3b,
    0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec, 0xf4188ecf, 0xf7d793db,
    0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754, 0x39b663c0,
    0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da,
    0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7,
    0xa5ab26a3,
];

const BRANCH2_ORDERS_HEX: &str = "0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e0d070e0f0b0208030c0509010004060a0d0902060f0b0a040807000c0503010e0c090f07060f030e020d0405010b0a000c050a090e0802040407030f01060b000b0f0408020a0700090d06010e03050c0b060a0508020c03070f0e090d0001040906080f050800040a0b030d01020c0e090d0c0604070a03030f00080105020e01000d0f090a0b0e0402080703060c0501080a0c0f0905060b000304020e070d04080f000c0f0e0d0a01060207090503040205080d0b0a0606000e0f070c09030a08040f000b01060d0c0709030e05020a070b050f00020e0108030d0c0609040d070f08050f06040b0a0e0c090002030d0c020704010b0e0e08060f09050003";

fn branch2_orders() -> &'static [u8] {
    static O: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    O.get_or_init(|| hex::decode(BRANCH2_ORDERS_HEX).expect("branch2 orders hex"))
}

/// cjs `md5V3Step`：md5 轮函数变体（4 种 f，b + rol(a+f+m+c, s)）。
fn md5v3_step(kind: u8, a: u32, b: u32, c: u32, d: u32, m: u32, shift: u32, constant: u32) -> u32 {
    let f = match kind {
        0 => (b & c) | (!b & d),
        1 => (b & d) | (c & !d),
        2 => b ^ c ^ d,
        _ => c ^ (b | !d),
    };
    b.wrapping_add(
        a.wrapping_add(f)
            .wrapping_add(m)
            .wrapping_add(constant)
            .rotate_left(shift),
    )
}

/// cjs `md5SumV3`：64 字节 message 的 4 轮 16 步混合，输出 16+4 字节。
fn md5_sum_v3(message: &[u8], count_v2: u32, orders: &[u8], count_v1: u32) -> Vec<u8> {
    assert!(message.len() >= 64 && orders.len() >= 64, "md5SumV3 输入不足");
    let sv: Vec<u32> = BRANCH2_SV
        .iter()
        .map(|&v| v.rotate_right(count_v1 & 31))
        .collect();
    let start = [
        0x79e0f2fbu32.rotate_right(count_v2 & 31),
        0xc8b52570u32.rotate_right(count_v2 & 31),
        0xebc2f8cdu32.rotate_right(count_v2 & 31),
        0x7c104d93u32.rotate_right(count_v2 & 31),
    ];
    let end_count = count_v2.wrapping_add(6) & 255;
    let end = [
        0x19be4866u32.rotate_right(end_count & 31),
        0xe85986b4u32.rotate_right(end_count & 31),
        0xe19b326eu32.rotate_right(end_count & 31),
        0x71d1d7d4u32.rotate_right(end_count & 31),
    ];
    let mut m = [0u32; 16];
    for i in 0..16 {
        m[i] = u32::from_le_bytes(message[i * 4..i * 4 + 4].try_into().unwrap());
    }
    let mut a = start[0];
    let mut b = start[1];
    let mut c = start[2];
    let mut d = start[3];
    let rounds: [(u8, [u32; 4]); 4] = [
        (0, [7, 12, 17, 22]),
        (1, [5, 9, 14, 20]),
        (2, [4, 11, 16, 23]),
        (3, [6, 10, 15, 21]),
    ];
    for (round, (kind, shifts)) in rounds.iter().enumerate() {
        let offset = round * 16;
        for i in 0..16 {
            let phase = i & 3;
            let mi = m[orders[offset + i] as usize];
            let svv = sv[offset + i];
            let shift = shifts[i & 3];
            let next = match phase {
                0 => md5v3_step(*kind, a, b, c, d, mi, shift, svv),
                1 => md5v3_step(*kind, d, a, b, c, mi, shift, svv),
                2 => md5v3_step(*kind, c, d, a, b, mi, shift, svv),
                _ => md5v3_step(*kind, b, c, d, a, mi, shift, svv),
            };
            match phase {
                0 => a = next,
                1 => d = next,
                2 => c = next,
                _ => b = next,
            }
        }
    }
    let mut ret = [0u8; 16];
    let finals = [
        start[0].wrapping_add(a) ^ end[0],
        start[1].wrapping_add(b) ^ end[1],
        start[2].wrapping_add(c) ^ end[2],
        start[3].wrapping_add(d) ^ end[3],
    ];
    for i in 0..4 {
        ret[i * 4..i * 4 + 4].copy_from_slice(&finals[i].to_le_bytes());
    }
    let mut out = ret.to_vec();
    out.extend_from_slice(&sum_md5(&ret).to_le_bytes());
    out
}

/// cjs `branch2F13`：branch 2 的 md5SumV3 封装。
fn branch2_f13(iv: u32, query_sm3: &[u8], body_md5: &[u8], ts_bytes: &[u8], khronos: u32) -> Vec<u8> {
    let v = (iv & 13).wrapping_mul(86);
    let iv_v0 = ((v >> 15) & 255) + ((v >> 8) & 255);
    let n1 = [
        0x8980f29bu32, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4,
    ][iv_v0 as usize];
    let count_v1 = n1.wrapping_add(khronos).wrapping_add(1) & 255;
    let count_v2 = n1.wrapping_add(khronos);
    let shift = count_v2.wrapping_add(5) & 7;
    let seed = [0x84u32, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8];
    let pad: Vec<u8> = seed
        .iter()
        .map(|&x| (((x | (x << 8)) >> shift) & 255) as u8)
        .collect();
    let mut input = Vec::with_capacity(64);
    input.extend_from_slice(query_sm3);
    input.extend_from_slice(body_md5);
    input.extend_from_slice(ts_bytes);
    input.extend_from_slice(&pad);
    input.extend_from_slice(&[0xa0, 0x01, 0x00, 0x00]);
    md5_sum_v3(
        &input,
        count_v2,
        &branch2_orders()[(iv_v0 as usize) << 6..(iv_v0 as usize + 1) << 6],
        count_v1,
    )
}

/// cjs `bxor`：按较长者循环短 key 的 XOR（此处等长调用，取 min 即可）。
fn bxor(a: &[u8], b: &[u8]) -> Vec<u8> {
    let n = a.len().min(b.len());
    (0..n).map(|i| a[i] ^ b[i]).collect()
}

const TT02: [u32; 64] = [
    0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638,
    0x34180eb8, 0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1,
    0x57473c12, 0xf76f0288, 0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d,
    0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e, 0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83,
    0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c, 0x617ce2a6, 0xe423417e, 0x0a40e143,
    0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3, 0xe1d0b866, 0xbaa3dcb8,
    0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8, 0x72aad10d,
    0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
    0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x0284ba7, 0x08387cfa,
    0x5fb37586,
];

const CHOSEN: [[usize; 11]; 6] = [
    [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
    [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
    [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
    [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
    [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
    [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
];

/// cjs `hashF13`：query+body+ts 的三分支摘要（medusa 字段 13）。
fn hash_f13(query_sm3: &[u8], body_md5: &[u8], ts_bytes: &[u8], khronos: u32) -> Vec<u8> {
    let iv = get_iv(get_iv(get_iv(0x20230928, query_sm3), body_md5), ts_bytes);
    let low = iv & 15;
    let iv_v0 = (low.wrapping_mul(171) >> 9) as usize;
    let branch = low - ((low.wrapping_mul(171) >> 9) * 3);
    if branch == 2 {
        return branch2_f13(iv, query_sm3, body_md5, ts_bytes, khronos);
    }
    if branch != 0 {
        let mut out = Vec::with_capacity(36);
        out.extend_from_slice(&query_sm3[..16]);
        out.extend_from_slice(body_md5);
        let mut sm_input = query_sm3.to_vec();
        sm_input.extend_from_slice(body_md5);
        out.extend_from_slice(&sum_md5(&sm_input).to_le_bytes());
        return out;
    }
    // branch 0：112 轮消息扩展 + chosen 序列的 8 字象压缩。
    let iv_v1_list = [
        0xc4a78580u32, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1,
    ];
    let iv_v1 = iv_v1_list[iv_v0];
    let count_v1 = iv_v1.wrapping_add(khronos).wrapping_add(1) & 255;
    let count_v2 = iv_v1.wrapping_add(khronos);
    let tt: Vec<u32> = TT02.iter().map(|&v| v.rotate_right(count_v1 & 31)).collect();
    let n0 = count_v2.wrapping_add(2) & 7;
    let seed = [0xfau32, 0x45, 0x61, 0xd7];
    let pad: Vec<u8> = seed
        .iter()
        .map(|&x| (((x | (x << 8)) >> n0) & 255) as u8)
        .collect();
    let mut data = Vec::with_capacity(64);
    data.extend_from_slice(query_sm3);
    data.extend_from_slice(body_md5);
    data.extend_from_slice(ts_bytes);
    data.extend_from_slice(&pad);
    data.extend_from_slice(&[0, 0, 0, 0, 0, 0, 1, 0xa0]);
    let mut di: Vec<u32> = Vec::with_capacity(128);
    for i in 0..16 {
        di.push(u32::from_be_bytes(data[i * 4..i * 4 + 4].try_into().unwrap()));
    }
    let mut di0 = di[0];
    for i in 0..112 {
        let di1 = di[i + 1];
        let di14 = di[i + 14];
        let r1 = di1.rotate_left(14) ^ di1.rotate_left(25) ^ (di1 >> 3);
        let r2 = di14.rotate_left(13) ^ di14.rotate_left(15) ^ (di14 >> 10);
        di.push(di0.wrapping_add(di[i + 9]).wrapping_add(r1).wrapping_add(r2));
        di0 = di1;
    }
    let init: Vec<u32> = [
        0x7aba4fc8u32,
        0x67166507,
        0x6403fa00,
        0x340f512f,
        984_304_912,
        3_005_047_866,
        2_874_125_293,
        2_152_413_264,
    ]
    .iter()
    .map(|&v| v.rotate_right(count_v2 & 31))
    .collect();
    let chosen = &CHOSEN[iv_v0];
    let mut d: Vec<u32> = init.clone();
    for i in 0..chosen[0] {
        let base = iv_v1.wrapping_add(i as u32);
        let n0v = di[(base & 127) as usize];
        let n1 = (d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]] ^ d[chosen[3]];
        let n2 = d[chosen[1]]
            .rotate_left(26)
            ^ d[chosen[1]].rotate_left(21)
            ^ d[chosen[1]].rotate_left(7);
        let n4 = n0v
            .wrapping_add(n1)
            .wrapping_add(n2)
            .wrapping_add(tt[(base & 63) as usize])
            .wrapping_add(d[chosen[5]]);
        let n5 = d[chosen[2]]
            .rotate_left(30)
            ^ d[chosen[2]].rotate_left(19)
            ^ d[chosen[2]].rotate_left(10);
        let n6 = (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]]);
        let n7 = n5.wrapping_add(n6);
        let old = d[chosen[9]];
        d.rotate_right(1);
        d[chosen[10]] = n7.wrapping_add(n4);
        d[chosen[8]] = old.wrapping_add(n4);
    }
    let mut ret = vec![0u8; 32];
    for i in 0..8 {
        ret[i * 4..i * 4 + 4]
            .copy_from_slice(&d[i].wrapping_add(init[i]).to_be_bytes());
    }
    let folded = bxor(&ret[0..16], &ret[16..32]);
    ret[0..16].copy_from_slice(&folded);
    let mut out = ret[0..16].to_vec();
    out.extend_from_slice(&sum_md5(&ret[0..16]).to_le_bytes());
    out
}

// ---------- x-gorgon 8404 ----------

/// cjs `rc4Gorgon`：KSA 无交换变体 + PRGA。
fn rc4_gorgon(data: &[u8], key: &[u8]) -> Vec<u8> {
    assert!(data.len() < 256 && !key.is_empty(), "rc4Gorgon 输入域");
    let mut s = [0u8; 256];
    for (i, slot) in s.iter_mut().enumerate() {
        *slot = i as u8;
    }
    let mut j = 0u8;
    for i in 0..256 {
        j = j
            .wrapping_add(s[i])
            .wrapping_add(key[i % key.len()]);
        s[i] = s[j as usize];
    }
    let mut i = 0usize;
    let mut j = 0u8;
    data.iter()
        .map(|&value| {
            i += 1;
            let x = s[i];
            j = j.wrapping_add(x);
            let y = s[j as usize];
            s[i] = y;
            value ^ s[y.wrapping_add(y) as usize]
        })
        .collect()
}

/// cjs `xGorgon`：8404 版（md5 前缀 + RC4 变种 + 位变换），hex 输出。
fn x_gorgon(query: &str, body: Option<&[u8]>, ts: u32, random: u16) -> String {
    let mut input = Vec::with_capacity(20);
    input.extend_from_slice(&md5_digest(query.as_bytes())[..4]);
    match body {
        Some(b) => input.extend_from_slice(&md5_digest(b)[..4]),
        None => input.extend_from_slice(&[0u8; 4]),
    }
    input.extend_from_slice(&[0u8; 4]);
    input.extend_from_slice(&67503104u32.to_le_bytes());
    input.extend_from_slice(&ts.to_be_bytes());
    let key = [
        0x4au8,
        0x40,
        0x16,
        ((random >> 8) & 255) as u8,
        0x47,
        0x6c,
        0x01,
        (random & 255) as u8,
    ];
    let mut out = rc4_gorgon(&input, &key);
    for i in 0..out.len() {
        let value = out[i].rotate_left(4);
        let next = if i + 1 < out.len() { out[i + 1] } else { out[0] };
        out[i] = !((next ^ value).reverse_bits() ^ 20);
    }
    let mut buf = vec![
        0x84u8,
        0x04,
        (random & 255) as u8,
        ((random >> 8) & 255) as u8,
        0x40,
        0x01,
    ];
    buf.extend_from_slice(&out);
    hex::encode(buf)
}

// ---------- x-helios ----------

/// cjs `helios`：md5(random_le||'8662') hex 建表的 34 轮 u64 ARX，base64 输出。
fn helios(khronos: u32, random: u32) -> String {
    let mut seed_data = random.to_le_bytes().to_vec();
    seed_data.extend_from_slice(b"8662");
    let digest = md5_digest(&seed_data);
    let ascii = hex::encode(digest).into_bytes();
    let mut words: std::collections::VecDeque<u64> = (0..4)
        .map(|i| u64::from_le_bytes(ascii[i * 8..i * 8 + 8].try_into().unwrap()))
        .collect();
    let mut table: Vec<u64> = Vec::with_capacity(35);
    table.push(words[0]);
    let mut b0 = words[0];
    let mut b8 = words[1];
    words.pop_front();
    words.pop_front();
    for i in 0..34u64 {
        let mut x8 = b8.rotate_right(8).wrapping_add(b0);
        x8 ^= i;
        words.push_back(x8);
        x8 ^= b0.rotate_right(61);
        table.push(x8);
        b0 = x8;
        b8 = words.pop_front().unwrap();
    }
    let text = format!("{khronos}-1588093228-8662");
    let text_bytes = text.as_bytes();
    let pad_len = (text_bytes.len() + 1 + 15) / 16 * 16;
    let fill = (16 - text_bytes.len() % 16) as u8;
    let mut pad = vec![fill; pad_len];
    pad[..text_bytes.len()].copy_from_slice(text_bytes);
    let mut out = random.to_le_bytes().to_vec();
    for block in pad.chunks_exact(16) {
        let mut a = u64::from_le_bytes(block[..8].try_into().unwrap());
        let mut b = u64::from_le_bytes(block[8..].try_into().unwrap());
        for round in table.iter().take(34) {
            b = round ^ a.wrapping_add(b.rotate_right(8));
            a = b ^ a.rotate_right(61);
        }
        out.extend_from_slice(&a.to_le_bytes());
        out.extend_from_slice(&b.to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(&out)
}

// ---------- x-medusa（AesV3 自定义 AES 变体 + protobuf 封装） ----------

const SBOX_B64: &str = "+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==";

fn sbox() -> &'static [u8] {
    static S: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    S.get_or_init(|| {
        base64::engine::general_purpose::STANDARD
            .decode(SBOX_B64)
            .expect("sbox base64")
    })
}

/// cjs `xorBytes`：按 `b` 循环异或。
fn xor_bytes(a: &[u8], b: &[u8]) -> Vec<u8> {
    assert!(!b.is_empty(), "xor_bytes 空密钥");
    a.iter()
        .enumerate()
        .map(|(i, x)| x ^ b[i % b.len()])
        .collect()
}

fn matrix(bytes: &[u8; 16]) -> [[u8; 4]; 4] {
    let mut rows = [[0u8; 4]; 4];
    for i in 0..4 {
        rows[i].copy_from_slice(&bytes[i * 4..i * 4 + 4]);
    }
    rows
}

fn flat(rows: &[[u8; 4]; 4]) -> [u8; 16] {
    let mut out = [0u8; 16];
    for i in 0..4 {
        out[i * 4..i * 4 + 4].copy_from_slice(&rows[i]);
    }
    out
}

/// cjs `aesMix`：列混合变体。
fn aes_mix(rows: &mut [[u8; 4]; 4]) {
    let xt = |x: u8| (x << 1) ^ if x & 128 != 0 { 0x1b } else { 0 };
    for i in 0..4 {
        let t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i];
        let u = rows[0][i];
        rows[0][i] ^= t ^ xt(rows[0][i] ^ rows[1][i]);
        rows[1][i] ^= t ^ xt(rows[1][i] ^ rows[2][i]);
        rows[2][i] ^= t ^ xt(rows[2][i] ^ rows[3][i]);
        rows[3][i] ^= t ^ xt(rows[3][i] ^ u);
    }
}

const CON2: [[usize; 4]; 4] = [
    [1, 0, 2, 3],
    [2, 0, 3, 1],
    [0, 1, 3, 2],
    [1, 0, 2, 3],
];

const ORDER: [[usize; 16]; 4] = [
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
    [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
];

/// cjs `AesV3`：自定义 AES 变体（SBOX 分段选盒、错位行变换、混合列序）。
struct AesV3 {
    box_: &'static [u8],
    con2: [usize; 4],
    order: [usize; 16],
    keys: Vec<[u8; 4]>,
}

impl AesV3 {
    fn new(key: &[u8; 16], khronos: u32) -> AesV3 {
        let word_size = (khronos & 3) as usize;
        let sbox = sbox();
        let box_ = &sbox[word_size * 256..word_size * 256 + 256];
        let init = [
            0xca025ddcu32, 0x823dc546, 0xc9420583, 0xc298225f,
        ][word_size];
        let mut initial = [0u8; 16];
        for i in 0..4 {
            initial[i * 4..i * 4 + 4].copy_from_slice(&init.to_le_bytes());
        }
        let mk = xor_bytes(&initial, key);
        let mut expanded = vec![0u8; 48];
        expanded[..16].copy_from_slice(&mk);
        let mut rounds = 8u32;
        for i in 4..12usize {
            let at = 4 * (i - 1);
            let (mut a, mut b, mut c, mut d) = (
                expanded[at],
                expanded[at + 1],
                expanded[at + 2],
                expanded[at + 3],
            );
            if (i & 3) == 0 {
                let t = ((init >> (rounds & 24)) ^ box_[b as usize] as u32) as u8;
                b = box_[c as usize];
                c = box_[d as usize];
                d = box_[a as usize];
                a = t;
            }
            rounds += 2;
            expanded[at + 4] = a ^ expanded[at - 12];
            expanded[at + 5] = b ^ expanded[at - 11];
            expanded[at + 6] = c ^ expanded[at - 10];
            expanded[at + 7] = d ^ expanded[at - 9];
        }
        let keys: Vec<[u8; 4]> = (0..12)
            .map(|i| expanded[i * 4..i * 4 + 4].try_into().unwrap())
            .collect();
        AesV3 {
            box_,
            con2: CON2[word_size],
            order: ORDER[word_size],
            keys,
        }
    }

    fn add_con(&self, rows: &mut [[u8; 4]; 4], keys: &[[u8; 4]]) {
        for i in 0..4 {
            for j in 0..4 {
                rows[i][j] ^= keys[i][self.con2[j]];
            }
        }
    }

    fn add(&self, rows: &mut [[u8; 4]; 4], keys: &[[u8; 4]]) {
        for i in 0..4 {
            for j in 0..4 {
                rows[i][j] ^= keys[i][j];
            }
        }
    }

    fn sub(&self, rows: &mut [[u8; 4]; 4]) {
        for r in rows.iter_mut() {
            for c in r.iter_mut() {
                *c = self.box_[*c as usize];
            }
        }
        let old = *rows;
        for i in 0..4 {
            rows[i] = old[self.con2[i]];
        }
    }

    fn shift(&self, rows: &mut [[u8; 4]; 4]) {
        let b = flat(rows);
        for i in 0..16 {
            rows[i / 4][i % 4] = b[self.order[i]];
        }
    }

    fn shift_con(&self, rows: &mut [[u8; 4]; 4]) {
        let old = *rows;
        for i in 0..4 {
            for j in 0..4 {
                rows[i][j] = old[i][self.con2[j]];
            }
        }
    }

    fn block(&self, value: &[u8; 16]) -> [u8; 16] {
        let mut rows = matrix(value);
        self.add_con(&mut rows, &self.keys[0..4]);
        for i in 1..3usize {
            self.sub(&mut rows);
            self.shift(&mut rows);
            if i == 1 {
                self.shift_con(&mut rows);
                aes_mix(&mut rows);
            }
            self.add_con(&mut rows, &self.keys[i * 4..i * 4 + 4]);
        }
        self.add(&mut rows, &self.keys[4..8]);
        flat(&rows)
    }

    /// cjs `encrypt`：输入需 >=248 字节（固定读写 31 组 8 字节位槽），
    /// 输出为 1 字节 key 尾 + 位嵌入后的原文。
    fn encrypt(&self, data: &[u8], iv: &[u8]) -> Vec<u8> {
        assert!(data.len() >= 248, "AesV3.encrypt 输入需 >=248 字节");
        assert_eq!(iv.len(), 16, "AesV3 iv 需 16 字节");
        let source = data;
        let mut plaintext = [0u8; 32];
        for i in 0..31 {
            let at = i * 8;
            let n0 = (source[at] as u32 >> 4) & 2;
            let n1 = n0 | (source[at + 1] as u32 & 64);
            let n2 = n1 | ((source[at + 2] as u32 >> 2) & 1);
            let n3 = n2 | (((source[at + 3] as u32) << 3) & 128);
            let n4 = n3 | ((source[at + 4] as u32 >> 1) & 4);
            let n5 = n4 | (((source[at + 5] as u32) << 3) & 16);
            let n6 = n5 | (((source[at + 6] as u32) << 5) & 32);
            plaintext[i] = (n6 | ((source[at + 7] as u32 >> 4) & 8)) as u8;
        }
        plaintext[31] = 1;
        let mut key = Vec::with_capacity(32);
        let mut previous = iv.to_vec();
        for chunk in plaintext.chunks_exact(16) {
            let xored = xor_bytes(chunk, &previous);
            let value = self.block(&xored.try_into().unwrap());
            key.extend_from_slice(&value);
            previous = value.to_vec();
        }
        let mut out = source.to_vec();
        for i in 0..31 {
            let at = i * 8;
            let k = key[i] as u32;
            out[at] &= 0xdf;
            out[at] |= ((k << 4) & 32) as u8;
            out[at + 1] &= 0xbf;
            out[at + 1] |= (k & 64) as u8;
            out[at + 2] &= 0xfb;
            out[at + 2] |= ((k << 2) & 4) as u8;
            out[at + 3] &= 0xef;
            out[at + 3] |= ((k >> 3) & 16) as u8;
            out[at + 4] &= 0xf7;
            out[at + 4] |= ((k << 1) & 8) as u8;
            out[at + 5] &= 0xfd;
            out[at + 5] |= ((k >> 3) & 2) as u8;
            out[at + 6] &= 0xfe;
            out[at + 6] |= ((k >> 5) & 1) as u8;
            out[at + 7] &= 0x7f;
            out[at + 7] |= ((k << 4) & 128) as u8;
        }
        let mut result = Vec::with_capacity(1 + out.len());
        result.push(key[31]);
        result.extend_from_slice(&out);
        result
    }
}

/// cjs `xmxor`：medusa message 的白盒混淆（位槽反转 + 链式校验）。
fn xmxor(data: &[u8], key: &[u8]) -> Vec<u8> {
    let len = data.len();
    assert!(len >= 4 && key.len() >= 4, "xmxor 输入域");
    let mut e: Vec<u32> = Vec::with_capacity(len);
    for i in 0..len {
        let at = (i * 4) & 28;
        let d0 = key[at] as u32;
        let d1 = key[at + 1] as u32;
        let mut d2 = (((data[i] as u32) << 4) | (data[i] as u32 >> 4)) & 255;
        d2 = d2.wrapping_add(d0);
        d2 = (!d2) ^ d1;
        d2 = ((d2 & 255) << 3 | (d2 & 255) >> 5) & 255;
        d2 = d2.wrapping_add(d1) & 255;
        d2 = (d2 ^ d0) & 255;
        e.push(!d2 & 255);
    }
    // JS 倒序写入：encoded[data.length - i - 1]。
    e.reverse();
    let last = e[len - 1] ^ e[len - 2];
    let first = e[0];
    e[0] = (!last).wrapping_add(first) & 255;
    e[1] = (e[0] ^ e[len - 1] ^ 254).wrapping_add(e[1]) & 255;
    e[2] = e[2].wrapping_add(
        (last.wrapping_sub(first) ^ ((e[1] << 3 | e[1] >> 5) & 255) ^ 2) & 0xffff_ffff,
    ) & 255;
    for i in 0..len.saturating_sub(4) {
        let temp = ((e[i + 2] << 3 | e[i + 2] >> 5) & 255) ^ e[i + 1] ^ (i as u32 + 3);
        e[i + 3] = (!temp).wrapping_add(e[i + 3]) & 255;
    }
    e[len - 1] ^= e[len - 2];
    let mut sum: u32 = 0;
    for i in 0..len - 1 {
        sum = sum.wrapping_add(e[i + 1]);
    }
    e[0] = (e[0] ^ e[1]).wrapping_add(sum) & 255;
    e.into_iter().map(|x| x as u8).collect()
}

/// cjs `keyHash`：medusa 的 message 密钥派生（sm3 + 随机扰动字节）。
fn key_hash(sign_key: &[u8], random: u32) -> ([u8; 32], [u8; 4]) {
    let mut input = Vec::with_capacity(sign_key.len() * 2 + 4);
    input.extend_from_slice(sign_key);
    input.extend_from_slice(&random.to_le_bytes());
    input.extend_from_slice(sign_key);
    let hash = sm3_hash(&input);
    let d1 = (random >> 16) & 255;
    let d2 = !(((d1 as u32) << 11 | random >> 24) ^ (d1 as u32) >> 5 ^ d1 as u32);
    (hash, d2.to_le_bytes())
}

/// medusa 内部 5 个随机量（cjs 依次 `Math.floor(Math.random()*N)` 取出，
/// 移植为显式参数以便 golden 对拍）。
pub(crate) struct MedusaRand {
    pub message_rand: u32,
    pub env_launch: u32,
    pub env_pid: u32,
    pub key_random: u32,
    pub xm_rand: u32,
}

/// cjs `buildMedusa`：hashF13 + protobuf + AesV3 + xmxor 封装，base64 输出。
fn build_medusa(url: &str, body: Option<&[u8]>, khronos: u32, rand: &MedusaRand) -> String {
    let query = url.split_once('?').expect("medusa url 需带 query").1;
    let body_md5: Vec<u8> = match body {
        Some(b) => md5_digest(b).to_vec(),
        None => vec![0u8; 16],
    };
    let query_sm3 = sm3_hash(query.as_bytes());
    let ts_bytes = khronos.to_le_bytes();
    let query_body_ts = hash_f13(&query_sm3, &body_md5, &ts_bytes, khronos);
    let nested = proto(&[
        (1, ProtoVal::Sint(111)),
        (2, ProtoVal::Sint(10)),
        (3, ProtoVal::Sint(694_367)),
        (5, ProtoVal::Sint(586_952_199)),
    ]);
    let env_inner = proto(&[
        (1, ProtoVal::Sint(khronos as i64)),
        (2, ProtoVal::Sint(-2)),
        (4, ProtoVal::Sint(200)),
    ]);
    let env = proto(&[
        (1, ProtoVal::Sint(rand.env_launch as i64)),
        (2, ProtoVal::Sint(146_331_399)),
        (3, ProtoVal::Sint(146_331_396)),
        (5, ProtoVal::Sint(7)),
        (6, ProtoVal::Str("v04.06.04.03-bugfix".into())),
        (7, ProtoVal::Sint(rand.env_pid as i64)),
        (
            12,
            ProtoVal::Msg(device_proto(device_field("device_id"))),
        ),
        (13, ProtoVal::Msg(env_inner)),
        (14, ProtoVal::Str(device_field("version_name").into())),
    ]);
    let mut qh_input = query.as_bytes().to_vec();
    qh_input.extend_from_slice(&body_md5);
    qh_input.extend_from_slice(b"none");
    let query_hash = sm3_hash(&qh_input);
    let message = proto(&[
        (
            1,
            ProtoVal::Bytes(
                hex::decode("f7e85ffad7d7dc3bd62ac87057cf6118").expect("medusa magic"),
            ),
        ),
        (2, ProtoVal::Sint(3)),
        (3, ProtoVal::Sint(rand.message_rand as i64)),
        (4, ProtoVal::Str("8662".into())),
        (5, ProtoVal::Str(device_field("device_id").into())),
        (6, ProtoVal::Str("1588093228".into())),
        (7, ProtoVal::Str(device_field("version_name").into())),
        (8, ProtoVal::Str("v04.06.04-ml-android".into())),
        (9, ProtoVal::Sint(67_503_104)),
        (
            10,
            ProtoVal::Bytes(vec![0x40, 0x01, 0, 0, 0, 0, 0, 0]),
        ),
        (12, ProtoVal::Sint(khronos as i64)),
        (13, ProtoVal::Bytes(query_body_ts.clone())),
        (14, ProtoVal::Bytes(query_sm3[..6].to_vec())),
        (15, ProtoVal::Msg(nested)),
        (16, ProtoVal::Str("AXYQOS6n2m60x1fVZHIrH3iol".into())),
        (17, ProtoVal::Sint(khronos as i64)),
        (19, ProtoVal::Bytes(query_hash.to_vec())),
        (20, ProtoVal::Str("none".into())),
        (21, ProtoVal::Sint(312)),
        (23, ProtoVal::Msg(env)),
        (
            24,
            ProtoVal::Str(
                "{\"cmr\":16777216,\"cmr2\":16777216,\"un_h\":1879194040,\"vpn\":0,\"kd\":0,\"fkd\":3672518972,\"pd\":-1872573247,\"dyn\":\"\",\"do\":0,\"tk\":true}"
                    .into(),
            ),
        ),
    ]);
    let sign_key = hex::decode("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
        .expect("medusa sign key");
    let (hash, seed) = key_hash(&sign_key, rand.key_random);
    let xored = xmxor(&message, &hash);
    let mut transformed: Vec<u8> = vec![0x40, 0x01, 0, 0, 0, 0, 0, 0];
    transformed.extend_from_slice(&xored);
    transformed.reverse();
    for (i, b) in transformed.iter_mut().enumerate() {
        *b ^= seed[(!i) & 3];
    }
    let check = (query_sm3[0] as u32 & 63) << 14 | 0x1800_0001 | (query_body_ts[0] as u32 & 63) << 8;
    let mut packed = Vec::with_capacity(11 + transformed.len());
    packed.push(0x35);
    packed.extend_from_slice(&rand.xm_rand.to_le_bytes());
    packed.extend_from_slice(&check.to_le_bytes());
    packed.extend_from_slice(&transformed);
    packed.push((rand.key_random >> 16) as u8);
    packed.push((rand.key_random >> 24) as u8);
    let aes_key: [u8; 16] =
        hex::decode("f1593376766ea98d34f31b057a9d5be4").expect("medusa aes key")[..16]
            .try_into()
            .unwrap();
    let aes_iv: [u8; 16] =
        hex::decode("1fe109a4125283f418de9e051a969e12").expect("medusa aes iv")[..16]
            .try_into()
            .unwrap();
    let encrypted = AesV3::new(&aes_key, khronos).encrypt(&packed, &aes_iv);
    let version = hex::decode("03000000f7e85ffad7d7dc3bd62ac87057cf6118").expect("medusa version");
    let mut prefix = [0u8; 20];
    for i in (0..20).step_by(4) {
        let v = u32::from_le_bytes(version[i..i + 4].try_into().unwrap()) ^ khronos;
        prefix[i..i + 4].copy_from_slice(&v.to_le_bytes());
    }
    let mut out = prefix.to_vec();
    out.push(rand.key_random as u8);
    out.push((rand.key_random >> 8) as u8);
    out.push(0);
    out.push(1);
    out.extend_from_slice(&encrypted);
    base64::engine::general_purpose::STANDARD.encode(&out)
}

// ---------- branchOf / 请求级封装 ----------

/// cjs `branchOf`：0..15 的分支判定（1 = 服务端不认的签名变体）。
fn branch_of(url: &str, body: Option<&[u8]>, khronos: u32) -> u32 {
    let body_md5: Vec<u8> = match body {
        Some(b) => md5_digest(b).to_vec(),
        None => vec![0u8; 16],
    };
    let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
    let q = sm3_hash(query.as_bytes());
    let iv = get_iv(
        get_iv(get_iv(0x20230928, &q), &body_md5),
        &khronos.to_le_bytes(),
    );
    let low = iv & 15;
    low - (low.wrapping_mul(171) >> 9) * 3
}

/// 一次请求的 7 个随机量（cjs 各签名函数内部自取，移植为显式注入）。
pub(crate) struct SignRand {
    pub gorgon: u16,
    pub helios: u32,
    pub medusa: MedusaRand,
}

impl SignRand {
    /// 生产路径：与 cjs 的 `Math.floor(Math.random()*N)` 同域均匀取值。
    pub(crate) fn new() -> SignRand {
        use rand::{Rng, RngCore};
        let mut rng = rand::thread_rng();
        SignRand {
            gorgon: rng.gen_range(0..=u16::MAX),
            helios: rng.next_u32(),
            medusa: MedusaRand {
                message_rand: rng.next_u32(),
                env_launch: rng.gen_range(100..121),
                env_pid: rng.gen_range(10001..12001),
                key_random: rng.next_u32(),
                xm_rand: rng.next_u32(),
            },
        }
    }
}

// hongguo 取流已切 kotlin-tv V5（`native.rs` 的 `Upstream::v5_playback`），
// V4 `multi_video_model` 签名保留作 golden 测试与对照参考。
#[allow(dead_code)]
pub(crate) struct SignedVideoRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// cjs `signedVideoRequest`：`multi_video_model` POST 签名请求
/// （`_rticket` 抖动规避 branch 1，最多 32 个偏移）。
#[allow(dead_code)]
fn signed_video_request_with(
    payload: &str,
    now_ms: i64,
    rand: &SignRand,
) -> SignedVideoRequest {
    let khronos = (now_ms / 1000) as u32;
    let body = payload.as_bytes().to_vec();
    let ticket_base = now_ms;
    let mut request_ticket = ticket_base;
    let mut query = String::new();
    let mut url = String::new();
    for offset in 0..32 {
        request_ticket = ticket_base + offset;
        let mut values: Vec<(String, String)> = DEVICE
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        values.push(("ts".into(), khronos.to_string()));
        values.push(("_rticket".into(), request_ticket.to_string()));
        query = python_url_encode(&values);
        url = format!("{}?{}", VIDEO_API, query);
        if branch_of(&url, Some(&body), khronos) != 1 {
            break;
        }
    }
    let headers = vec![
        ("User-Agent".into(), VIDEO_UA.into()),
        (
            "Accept".into(),
            "application/json; charset=utf-8,application/x-protobuf".into(),
        ),
        ("Content-Type".into(), "application/json; charset=UTF-8".into()),
        ("x-xs-from-web".into(), "0".into()),
        ("x-ss-req-ticket".into(), request_ticket.to_string()),
        ("x-tt-request-tag".into(), "t=0;n=0".into()),
        ("sdk-version".into(), "2".into()),
        ("passport-sdk-version".into(), "50561".into()),
        ("x-vc-bdturing-sdk-version".into(), "3.7.2.cn".into()),
        ("x-ss-stub".into(), md5_upper_hex(&body)),
        (
            "x-gorgon".into(),
            x_gorgon(&query, Some(&body), khronos, rand.gorgon),
        ),
        ("x-khronos".into(), khronos.to_string()),
        (
            "x-ladon".into(),
            base64::engine::general_purpose::STANDARD.encode(khronos.to_be_bytes()),
        ),
        (
            "x-argus".into(),
            base64::engine::general_purpose::STANDARD.encode(khronos.to_le_bytes()),
        ),
        ("x-helios".into(), helios(khronos, rand.helios)),
        (
            "x-medusa".into(),
            build_medusa(&url, Some(&body), khronos, &rand.medusa),
        ),
        ("x-tt-dt".into(), String::new()),
    ];
    SignedVideoRequest { url, headers, body }
}

/// 生产入口（内部随机）。
#[allow(dead_code)]
pub(crate) fn signed_video_request(payload: &str, now_ms: i64) -> SignedVideoRequest {
    let rand = SignRand::new();
    signed_video_request_with(payload, now_ms, &rand)
}

pub(crate) struct SignedAppGet {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

/// cjs `signedAppGet`：`bookapi` 搜索 GET 签名请求（body 为空）。
fn signed_app_get_with(values: &[(String, String)], now_ms: i64, rand: &SignRand) -> SignedAppGet {
    signed_bookapi_get_with(APP_SEARCH_API, values, now_ms, rand)
}

/// 同一签名套件签任意 `bookapi` GET 基址（搜索 / 云端收藏共用）。
fn signed_bookapi_get_with(
    base: &str,
    values: &[(String, String)],
    now_ms: i64,
    rand: &SignRand,
) -> SignedAppGet {
    let khronos = (now_ms / 1000) as u32;
    let ticket = now_ms;
    let mut v = values.to_vec();
    v.push(("ts".into(), khronos.to_string()));
    v.push(("_rticket".into(), ticket.to_string()));
    let query = python_url_encode(&v);
    let url = format!("{}?{}", base, query);
    let headers = vec![
        ("User-Agent".into(), APP_UA.into()),
        (
            "Accept".into(),
            "application/json; charset=utf-8,application/x-protobuf".into(),
        ),
        ("x-ss-req-ticket".into(), ticket.to_string()),
        ("x-tt-request-tag".into(), "t=0;n=0".into()),
        ("sdk-version".into(), "2".into()),
        ("passport-sdk-version".into(), "50561".into()),
        ("x-xs-from-web".into(), "0".into()),
        ("x-khronos".into(), khronos.to_string()),
        (
            "x-ladon".into(),
            base64::engine::general_purpose::STANDARD.encode(khronos.to_be_bytes()),
        ),
        (
            "x-argus".into(),
            base64::engine::general_purpose::STANDARD.encode(khronos.to_le_bytes()),
        ),
        (
            "x-gorgon".into(),
            x_gorgon(&query, None, khronos, rand.gorgon),
        ),
        ("x-helios".into(), helios(khronos, rand.helios)),
        (
            "x-medusa".into(),
            build_medusa(&url, None, khronos, &rand.medusa),
        ),
        ("x-tt-dt".into(), String::new()),
    ];
    SignedAppGet { url, headers }
}

/// 生产入口（内部随机）。
pub(crate) fn signed_app_get(values: &[(String, String)], now_ms: i64) -> SignedAppGet {
    let rand = SignRand::new();
    signed_app_get_with(values, now_ms, &rand)
}

/// 生产入口（内部随机）：按指定 `bookapi` 基址签名 GET。
pub(crate) fn signed_bookapi_get(
    base: &str,
    values: &[(String, String)],
    now_ms: i64,
) -> SignedAppGet {
    let rand = SignRand::new();
    signed_bookapi_get_with(base, values, now_ms, &rand)
}

/// App 搜索游标（cjs `appSearchPage` 的 page>1 时从上一页带出）。
#[derive(Clone, Default)]
pub(crate) struct AppSearchCursor {
    pub search_id: String,
    pub passback: String,
}

/// cjs `appSearchParams`：`APP_DEVICE` + 搜索字段（query/count/offset/tab_type...）。
pub(crate) fn app_search_params(
    keyword: &str,
    tab_type: u32,
    limit: u32,
    cursor: &AppSearchCursor,
    page: u32,
) -> Vec<(String, String)> {
    let mut values = app_device();
    values.push(("query".into(), keyword.trim().to_string()));
    values.push(("count".into(), limit.to_string()));
    values.push((
        "offset".into(),
        page
            .saturating_sub(1)
            .saturating_mul(limit)
            .to_string(),
    ));
    values.push(("tab_type".into(), tab_type.to_string()));
    values.push(("bookshelf_search_plan".into(), "4".into()));
    values.push(("use_correct".into(), "true".into()));
    values.push(("user_is_login".into(), "0".into()));
    if !cursor.search_id.is_empty() {
        values.push(("search_id".into(), cursor.search_id.clone()));
    }
    if !cursor.passback.is_empty() {
        values.push(("passback".into(), cursor.passback.clone()));
    }
    values
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn golden() -> Value {
        let raw = include_str!("../../../testdata/hongguo_vsign_golden.json");
        serde_json::from_str(raw).expect("hongguo_vsign_golden.json")
    }

    fn unhex(s: &str) -> Vec<u8> {
        hex::decode(s).expect("golden hex")
    }

    #[test]
    fn sm3_matches_cjs() {
        let u = &golden()["unit"]["sm3"];
        let out = sm3_hash(u["input_text"].as_str().unwrap().as_bytes());
        assert_eq!(hex::encode(out), u["out_hex"].as_str().unwrap());
    }

    #[test]
    fn md5_upper_matches_cjs() {
        let u = &golden()["unit"]["md5_upper"];
        let out = md5_upper_hex(u["input_text"].as_str().unwrap().as_bytes());
        assert_eq!(out, u["out"].as_str().unwrap());
    }

    #[test]
    fn python_url_encode_matches_cjs() {
        let u = &golden()["unit"]["python_url_encode"];
        let pairs: Vec<(String, String)> = u["input_pairs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                (
                    p[0].as_str().unwrap().to_string(),
                    p[1].as_str().unwrap().to_string(),
                )
            })
            .collect();
        assert_eq!(python_url_encode(&pairs), u["output"].as_str().unwrap());
    }

    #[test]
    fn proto_nested_matches_cjs() {
        let g = golden();
        let u = g["unit"]["proto_nested_hex"].as_str().unwrap();
        let out = proto(&[
            (1, ProtoVal::Sint(111)),
            (2, ProtoVal::Sint(10)),
            (3, ProtoVal::Sint(694_367)),
            (5, ProtoVal::Sint(586_952_199)),
        ]);
        assert_eq!(hex::encode(out), u);
    }

    #[test]
    fn device_proto_matches_cjs() {
        let g = golden();
        let u = g["unit"]["device_proto_hex"].as_str().unwrap();
        let out = device_proto(device_field("device_id"));
        assert_eq!(hex::encode(out), u);
    }

    #[test]
    fn get_iv_matches_cjs() {
        let u = &golden()["unit"]["get_iv"];
        let out = get_iv(
            u["iv"].as_u64().unwrap() as u32,
            &unhex(u["data_hex"].as_str().unwrap()),
        );
        assert_eq!(out, u["out"].as_u64().unwrap() as u32);
    }

    #[test]
    fn sum_md5_matches_cjs() {
        let u = &golden()["unit"]["sum_md5"];
        let out = sum_md5(&unhex(u["data_hex"].as_str().unwrap()));
        assert_eq!(out, u["out"].as_u64().unwrap() as u32);
    }

    #[test]
    fn md5_sum_v3_matches_cjs() {
        let u = &golden()["unit"]["md5_sum_v3"];
        let out = md5_sum_v3(
            &unhex(u["message_hex"].as_str().unwrap()),
            u["count_v2"].as_u64().unwrap() as u32,
            &unhex(u["orders_hex"].as_str().unwrap()),
            u["count_v1"].as_u64().unwrap() as u32,
        );
        assert_eq!(hex::encode(out), u["out_hex"].as_str().unwrap());
    }

    #[test]
    fn hash_f13_matches_cjs() {
        let u = &golden()["unit"]["hash_f13"];
        let out = hash_f13(
            &unhex(u["query_sm3_hex"].as_str().unwrap()),
            &unhex(u["body_md5_hex"].as_str().unwrap()),
            &unhex(u["ts_hex"].as_str().unwrap()),
            u["khronos"].as_u64().unwrap() as u32,
        );
        assert_eq!(hex::encode(out), u["out_hex"].as_str().unwrap());
    }

    #[test]
    fn rc4_gorgon_matches_cjs() {
        let u = &golden()["unit"]["rc4_gorgon"];
        let out = rc4_gorgon(
            &unhex(u["data_hex"].as_str().unwrap()),
            &unhex(u["key_hex"].as_str().unwrap()),
        );
        assert_eq!(hex::encode(out), u["out_hex"].as_str().unwrap());
    }

    #[test]
    fn x_gorgon_matches_cjs() {
        let u = &golden()["unit"]["x_gorgon"];
        let out = x_gorgon(
            u["query"].as_str().unwrap(),
            Some(&unhex(u["body_hex"].as_str().unwrap())),
            u["ts"].as_u64().unwrap() as u32,
            u["random"].as_u64().unwrap() as u16,
        );
        assert_eq!(out, u["out"].as_str().unwrap());
    }

    #[test]
    fn helios_matches_cjs() {
        let u = &golden()["unit"]["helios"];
        let out = helios(
            u["khronos"].as_u64().unwrap() as u32,
            u["random"].as_u64().unwrap() as u32,
        );
        assert_eq!(out, u["out"].as_str().unwrap());
    }

    #[test]
    fn aes_v3_matches_cjs() {
        let u = &golden()["unit"]["aes_v3"];
        let key: [u8; 16] = unhex(u["key_hex"].as_str().unwrap())[..16].try_into().unwrap();
        let aes = AesV3::new(&key, u["khronos"].as_u64().unwrap() as u32);
        let out = aes.encrypt(
            &unhex(u["data_hex"].as_str().unwrap()),
            &unhex(u["iv_hex"].as_str().unwrap()),
        );
        assert_eq!(hex::encode(out), u["out_hex"].as_str().unwrap());
    }

    #[test]
    fn xmxor_matches_cjs() {
        let u = &golden()["unit"]["xmxor"];
        let out = xmxor(
            &unhex(u["data_hex"].as_str().unwrap()),
            &unhex(u["key_hex"].as_str().unwrap()),
        );
        assert_eq!(hex::encode(out), u["out_hex"].as_str().unwrap());
    }

    #[test]
    fn key_hash_matches_cjs() {
        let u = &golden()["unit"]["key_hash"];
        let (hash, seed) = key_hash(
            &unhex(u["sign_key_hex"].as_str().unwrap()),
            u["random"].as_u64().unwrap() as u32,
        );
        assert_eq!(hex::encode(hash), u["hash_hex"].as_str().unwrap());
        assert_eq!(hex::encode(seed), u["seed_hex"].as_str().unwrap());
    }

    #[test]
    fn build_medusa_matches_cjs() {
        let u = &golden()["unit"]["build_medusa"];
        let r = &u["rand"];
        let rand = MedusaRand {
            message_rand: r["message_rand"].as_u64().unwrap() as u32,
            env_launch: r["env_launch"].as_u64().unwrap() as u32,
            env_pid: r["env_pid"].as_u64().unwrap() as u32,
            key_random: r["key_random"].as_u64().unwrap() as u32,
            xm_rand: r["xm_rand"].as_u64().unwrap() as u32,
        };
        let out = build_medusa(
            u["url"].as_str().unwrap(),
            Some(&unhex(u["body_hex"].as_str().unwrap())),
            u["khronos"].as_u64().unwrap() as u32,
            &rand,
        );
        assert_eq!(out, u["out"].as_str().unwrap());
    }

    #[test]
    fn branch_of_matches_cjs() {
        let u = &golden()["unit"]["branch_of"];
        let out = branch_of(
            u["url"].as_str().unwrap(),
            Some(&unhex(u["body_hex"].as_str().unwrap())),
            u["khronos"].as_u64().unwrap() as u32,
        );
        assert_eq!(out, u["out"].as_u64().unwrap() as u32);
    }

    fn golden_sign_rand(g: &Value) -> SignRand {
        let d = &g["meta"]["derived_random"];
        let mr = &g["unit"]["build_medusa"]["rand"];
        SignRand {
            gorgon: d["u16"].as_u64().unwrap() as u16,
            helios: d["u32"].as_u64().unwrap() as u32,
            medusa: MedusaRand {
                message_rand: mr["message_rand"].as_u64().unwrap() as u32,
                env_launch: mr["env_launch"].as_u64().unwrap() as u32,
                env_pid: mr["env_pid"].as_u64().unwrap() as u32,
                key_random: mr["key_random"].as_u64().unwrap() as u32,
                xm_rand: mr["xm_rand"].as_u64().unwrap() as u32,
            },
        }
    }

    #[test]
    fn signed_video_request_matches_cjs() {
        let g = golden();
        let vr = &g["video_request"];
        let rand = golden_sign_rand(&g);
        let req = signed_video_request_with(
            vr["payload"].as_str().unwrap(),
            g["meta"]["now_ms"].as_i64().unwrap(),
            &rand,
        );
        assert_eq!(req.url, vr["url"].as_str().unwrap());
        assert_eq!(req.body, vr["body"].as_str().unwrap().as_bytes());
        let expect = vr["headers"].as_object().unwrap();
        assert_eq!(req.headers.len(), expect.len(), "header 数量");
        for (k, v) in &req.headers {
            assert_eq!(
                v,
                expect[k].as_str().unwrap_or_default(),
                "header {k} 不匹配"
            );
        }
    }

    #[test]
    fn signed_app_get_matches_cjs() {
        let g = golden();
        let ag = &g["app_get"];
        let values = &ag["values"];
        let cursor = AppSearchCursor::default();
        let params = app_search_params(
            values["query"].as_str().unwrap(),
            values["tab_type"].as_str().unwrap().parse().unwrap(),
            values["count"].as_str().unwrap().parse().unwrap(),
            &cursor,
            1,
        );
        let rand = golden_sign_rand(&g);
        let req = signed_app_get_with(&params, g["meta"]["now_ms"].as_i64().unwrap(), &rand);
        assert_eq!(req.url, ag["url"].as_str().unwrap());
        let expect = ag["headers"].as_object().unwrap();
        assert_eq!(req.headers.len(), expect.len(), "header 数量");
        for (k, v) in &req.headers {
            assert_eq!(
                v,
                expect[k].as_str().unwrap_or_default(),
                "header {k} 不匹配"
            );
        }
    }
}
