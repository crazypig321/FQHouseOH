//! Golden vectors for the V5 signature internals.
//!
//! The fixtures are the independent cross-implementation vectors shipped with
//! `N3urda/hongguoTV` (`SignerV5Test.kt` + `signing-v5-f13.json` /
//! `signing-v5-carrier.json`, GPL-3.0-only): 32 f13 digests covering every
//! `ts & 3` rotation, and 4 carrier ciphertexts covering all four sbox
//! variants. They pin the branch-12 hash and the V5 AES carrier byte-for-byte
//! against both public implementations.

use serde_json::Value;

use super::{hash_f13_v5, AesV5};

#[test]
fn f13_matches_independent_vectors_across_all_timestamp_rotations() {
    let vectors: Vec<Value> =
        serde_json::from_str(include_str!("../../testdata/hongguo_v5_f13.json"))
            .expect("f13 golden file is valid JSON");
    assert_eq!(vectors.len(), 32, "the f13 fixture covers 32 rotations");
    for (index, row) in vectors.iter().enumerate() {
        let ts = row["ts"].as_i64().expect("ts") as u32;
        let query: [u8; 32] = hex::decode(row["query"].as_str().expect("query"))
            .expect("query hex")
            .try_into()
            .expect("query is 32 bytes");
        let body: [u8; 16] = hex::decode(row["body"].as_str().expect("body"))
            .expect("body hex")
            .try_into()
            .expect("body is 16 bytes");
        let result = hash_f13_v5(&query, &body, ts);
        assert_eq!(result.len(), 20, "f13 vector {index}");
        assert_eq!(
            hex::encode(result[..16].iter()),
            row["digest"].as_str().expect("digest"),
            "f13 vector {index}"
        );
        assert_eq!(result[16] & 0x24, 0x24, "f13 vector {index}");
    }
}

#[test]
fn carrier_matches_vectors_across_all_four_sbox_variants() {
    let rows: Vec<Value> =
        serde_json::from_str(include_str!("../../testdata/hongguo_v5_carrier.json"))
            .expect("carrier golden file is valid JSON");
    for (index, row) in rows.iter().enumerate() {
        let ts = row["ts"].as_i64().expect("ts") as u32;
        let key: [u8; 16] = hex::decode(row["key"].as_str().expect("key"))
            .expect("key hex")
            .try_into()
            .expect("key is 16 bytes");
        let iv: [u8; 16] = hex::decode(row["iv"].as_str().expect("iv"))
            .expect("iv hex")
            .try_into()
            .expect("iv is 16 bytes");
        let source = hex::decode(row["source"].as_str().expect("source")).expect("source hex");
        let encrypted = AesV5::new(&key, ts)
            .encrypt(&source, &iv)
            .unwrap_or_else(|e| panic!("carrier variant {index}: {e}"));
        assert_eq!(
            hex::encode(&encrypted),
            row["encrypted"].as_str().expect("encrypted"),
            "carrier variant {index}"
        );
    }
}
