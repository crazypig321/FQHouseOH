//! Wire tables for the v04.10.03 playback signature.
//!
//! Extracted from `N3urda/hongguoTV` (`V5Constants.kt` /
//! `VendorConstants.kt`, GPL-3.0-only) at
//! `18c37c2afd0567520135abcae312352542f09083`, and cross-checked with
//! `beilunyang/openhongguo` PR 13 at `788103f6`. `SBOX` and `HASH_TABLE` are
//! protocol data; neither contains a credential.

const SBOX_HEX: &str = concat!(
    "53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9",
    "445ec6ada2f865d22b696c4188f24c0df37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea",
    "8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a80c594daaab19b6279fbd75070cb52eb",
    "2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d",
    "d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a1",
    "3fccdb30b957a8acafe127400248591238922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55b",
    "a67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65b7b3a881aa908cc74f0ad76bbbb58617",
    "c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe",
    "1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c51",
    "56be4c8dfbe13a684bda39cf836697c894545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd95",
    "1d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dccd759fb722789b08807cc0fda293f7e5e",
    "1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d",
    "e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab285",
    "1466a7cdfc4ad1b52c2ae95a58d3734e47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187",
    "745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd288fd2bc1fc7bd675412138169cb092498",
    "75ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5",
    "d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e",
    "108da894b38970561ae9002619fbbac91fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46d",
    "a6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443fd830a4232e53da21a1f2d1bdfebc3a02",
    "c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168",
    "1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb6",
    "18496ecd76c35c798325590c2fb27a5e",
);

const fn nibble(value: u8) -> u8 {
    match value {
        b'0'..=b'9' => value - b'0',
        b'a'..=b'f' => value - b'a' + 10,
        b'A'..=b'F' => value - b'A' + 10,
        _ => panic!("invalid hex digit in V5 table"),
    }
}

const fn decode_hex<const N: usize>(input: &str) -> [u8; N] {
    let input = input.as_bytes();
    assert!(input.len() == N * 2, "wrong decoded V5 table length");
    let mut output = [0u8; N];
    let mut index = 0;
    while index < N {
        output[index] = (nibble(input[index * 2]) << 4) | nibble(input[index * 2 + 1]);
        index += 1;
    }
    output
}

/// Four 256-byte substitution boxes; `timestamp & 3` selects one.
pub(super) const SBOX: [u8; 1024] = decode_hex::<1024>(SBOX_HEX);

/// The 64-word `V5Constants.kt` diffusion table used by the branch-12 hash.
pub(super) const HASH_TABLE: [u32; 64] = [
    0xebb6_4faf,
    0x07aa_dcc2,
    0xcf31_87bf,
    0xe011_38ff,
    0x6d0b_fcff,
    0x5a30_a3be,
    0xb41a_d638,
    0x3418_0eb8,
    0xf233_eb6f,
    0xb1a5_84cc,
    0xccc3_0dc7,
    0x47d1_db51,
    0xd556_53de,
    0x70a8_4fa1,
    0x5747_3c12,
    0xf76f_0288,
    0x2c07_7f0a,
    0xda0d_cad0,
    0xfbb8_6f6c,
    0xfdc4_cf00,
    0x688a_020d,
    0xe676_c6a6,
    0x8cd6_338b,
    0x1a3c_8d0e,
    0xcce8_b06b,
    0x6ad0_ed0b,
    0xa052_2717,
    0xdc71_ac83,
    0x2285_db71,
    0xd5b4_dda6,
    0x736f_8650,
    0x6560_306c,
    0x617c_e2a6,
    0xe423_417e,
    0x0a40_e143,
    0x544e_4032,
    0x88df_fb2a,
    0x716c_1ae0,
    0x4c46_7a88,
    0x05b2_3bb3,
    0xe1d0_b866,
    0xbaa3_dcb8,
    0xae33_74d3,
    0xc338_1a50,
    0x1702_f75b,
    0xfe6d_a368,
    0xf0b4_cf48,
    0x4e0f_fbb8,
    0x72aa_d10d,
    0x26c5_3a3d,
    0xf2bc_e0f6,
    0xb455_7581,
    0x4a25_7fdd,
    0x8c31_82a2,
    0xab0b_3b86,
    0x3d5d_fb14,
    0x4f10_3634,
    0xd37b_52d7,
    0x444e_ff16,
    0xeb0a_33d1,
    0x6ca8_6f6e,
    0x0028_4ba7,
    0x0838_7cfa,
    0x5fb3_7586,
];
