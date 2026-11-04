use super::*;

#[test]
fn detects_encrypted_tracks_and_rewrites_the_sample_entry() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    assert!(mp4_needs_cenc_decrypt(&file), "encv must be detected");

    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");

    // encv -> hvc1 and sinf -> free, so a re-run must no longer see it as
    // encrypted (that is what makes the call idempotent).
    assert!(
        !mp4_needs_cenc_decrypt(&file),
        "the sample entry must be rewritten to a clear one"
    );
}

#[test]
fn renames_the_sample_entry_to_the_original_format_from_frma() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    // Turn the fixture into the TTS-voice shape: an audio entry whose
    // original format is Opus. The fixture entry is a video one, so the
    // 78-byte fixed part is reinterpreted: the first 28 bytes stay as the
    // audio fixed fields and the rest becomes a dOps config box, matching
    // the real device files (dOps + sinf/frma=opus).
    let entry = file
        .windows(4)
        .position(|w| w == b"encv")
        .expect("encv sample entry");
    file[entry..entry + 4].copy_from_slice(b"enca");
    // The audio fixed part is 28 bytes (video uses 78), so the bytes
    // between the audio fixed fields and sinf become a dOps config box,
    // matching the real device files (dOps + sinf/frma=opus).
    let dops = entry + 32;
    file[dops..dops + 4].copy_from_slice(&((170 - dops) as u32).to_be_bytes());
    file[dops + 4..dops + 8].copy_from_slice(b"dOps");
    for byte in &mut file[dops + 8..170] {
        *byte = 0;
    }
    let frma = file.windows(4).position(|w| w == b"frma").expect("frma");
    file[frma + 4..frma + 8].copy_from_slice(b"opus");
    assert!(mp4_needs_cenc_decrypt(&file));

    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");

    // The entry must carry the frma tag, not the hardcoded mp4a fallback
    // (an mp4a entry without esds is undecodable).
    assert!(
        file.windows(4).any(|w| w == b"opus"),
        "entry must be renamed to the frma tag"
    );
    assert!(
        !file.windows(4).any(|w| w == b"mp4a"),
        "must not fall back to mp4a when frma is present"
    );
    assert!(!mp4_needs_cenc_decrypt(&file));
}

#[test]
fn keeps_the_hardcoded_fallback_when_frma_is_unreadable() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    let entry = file
        .windows(4)
        .position(|w| w == b"encv")
        .expect("encv sample entry");
    file[entry..entry + 4].copy_from_slice(b"enca");
    let dops = entry + 8 + 28;
    let dops_size = (170 - dops) as u32;
    file[dops..dops + 4].copy_from_slice(&dops_size.to_be_bytes());
    file[dops + 4..dops + 8].copy_from_slice(b"dOps");
    for byte in &mut file[dops + 8..170] {
        *byte = 0;
    }
    let frma = file.windows(4).position(|w| w == b"frma").expect("frma");
    file[frma + 4..frma + 8].copy_from_slice(&[0, 0, 0, 0]);

    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");

    assert!(
        file.windows(4).any(|w| w == b"mp4a"),
        "unreadable frma must keep the mp4a fallback"
    );
    assert!(!mp4_needs_cenc_decrypt(&file));
}

#[test]
fn decrypts_every_whole_encrypted_sample_with_the_go_plaintext() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let expected = plain_samples(c, "full_sample_plain_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

    // The samples are laid out contiguously in mdat, in stsz order.
    let before = encrypted_region(&file, c, "full_mdat_offset");
    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");
    let after = encrypted_region(&file, c, "full_mdat_offset");

    let mut cursor = 0usize;
    for (i, want) in expected.iter().enumerate() {
        let got = &after[cursor..cursor + want.len()];
        assert_eq!(got, want.as_slice(), "sample {i}");
        // Go's ciphertext must differ from the plaintext for a non-trivial
        // sample, otherwise the comparison proves nothing.
        assert_ne!(
            &before[cursor..cursor + want.len()],
            want.as_slice(),
            "sample {i} was not actually encrypted"
        );
        cursor += want.len();
    }
    assert_eq!(cursor, after.len(), "all samples covered");
}

#[test]
fn decrypts_subsample_encrypted_payloads_and_keeps_the_clear_header() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "subsample_b64");
    let expected = plain_samples(c, "subsample_plain_b64");
    let clear_head = c["subsample_clear_head"].as_u64().unwrap() as usize;
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");
    let after = encrypted_region(&file, c, "subsample_mdat_offset");

    let mut cursor = 0usize;
    for (i, want) in expected.iter().enumerate() {
        let got = &after[cursor..cursor + want.len()];
        assert_eq!(got, want.as_slice(), "sample {i}");
        // senc flags=2 marks the head as clear: it must survive untouched.
        assert_eq!(
            &got[..clear_head],
            &want[..clear_head],
            "sample {i} clear head"
        );
        cursor += want.len();
    }
}

#[test]
fn a_wrong_key_produces_different_bytes_and_a_bad_length_is_rejected() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let original = file.clone();
    let expected = plain_samples(c, "full_sample_plain_b64");

    assert!(decrypt_cenc_mp4(&mut file.clone(), &[0u8; 7]).is_err());
    decrypt_cenc_mp4(&mut file, &[0xAAu8; 16]).expect("wrong key still decrypts");
    let after = encrypted_region(&file, c, "full_mdat_offset");
    assert_ne!(
        &after[..expected[0].len()],
        expected[0].as_slice(),
        "a wrong key must not reproduce the Go plaintext"
    );
    assert_ne!(file, original, "the wrong key must have changed the bytes");
}

/// P1-7: the cache file now stays encrypted on disk and the decrypted
/// view is produced per served range. Applying the index range by range
/// — unaligned probes, block-straddling slices, and a sequential
/// small-chunk pass like the streaming body's — must reproduce the
/// whole-file decrypt byte for byte.
#[test]
fn served_ranges_match_the_whole_file_decrypt() {
    let f = fixture();
    let c = &f["cenc"];
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    for case in ["full_sample_b64", "subsample_b64"] {
        let encrypted = b64(c, case);
        let mut whole = encrypted.clone();
        decrypt_cenc_mp4(&mut whole, &key).expect("whole decrypt");
        assert_ne!(whole, encrypted, "{case} must actually be encrypted");

        let index = build_cenc_index(&encrypted, 0, encrypted.len() as u64)
            .expect("index build")
            .expect("encrypted fixture must produce an index");
        let mut probes: Vec<(usize, usize)> = vec![(0, encrypted.len()), (0, 28)];
        let mut off = 0;
        while off < encrypted.len() {
            probes.push((off, (encrypted.len() - off).min(37)));
            off += 37;
        }
        for (off, len) in probes {
            let mut buf = encrypted[off..off + len].to_vec();
            apply_cenc_index(&mut buf, off as u64, &index, &key).expect("apply");
            assert_eq!(buf, whole[off..off + len], "{case} range {off}+{len}");
        }
        let mut streamed = Vec::with_capacity(encrypted.len());
        let mut pos = 0usize;
        while pos < encrypted.len() {
            let take = (encrypted.len() - pos).min(7);
            let mut buf = encrypted[pos..pos + take].to_vec();
            apply_cenc_index(&mut buf, pos as u64, &index, &key).expect("chunk apply");
            streamed.extend_from_slice(&buf);
            pos += take;
        }
        assert_eq!(streamed, whole, "{case} chunked stream");
    }
}

/// The serve path builds its index from the moov box alone; that index
/// must agree with the one built from the whole file.
#[test]
fn index_from_moov_slice_matches_whole_file_index() {
    let f = fixture();
    let c = &f["cenc"];
    let encrypted = b64(c, "full_sample_b64");
    let dir = p17_temp_dir("moov");
    let path = dir.join("sample.mp4");
    std::fs::write(&path, &encrypted).expect("write fixture");

    let (moov_off, moov) = read_moov_bytes(&path).expect("moov must be readable");
    assert_eq!(moov_off, 28, "fixture moov offset");
    let from_moov = build_cenc_index(&moov, moov_off, encrypted.len() as u64)
        .expect("build from moov")
        .expect("index from moov");
    let from_file = build_cenc_index(&encrypted, 0, encrypted.len() as u64)
        .expect("build from file")
        .expect("index from file");
    assert_eq!(from_moov.patches.len(), from_file.patches.len());
    for (a, b) in from_moov.patches.iter().zip(&from_file.patches) {
        assert_eq!((a.off, &a.bytes), (b.off, &b.bytes), "patch");
    }
    assert_eq!(from_moov.ranges.len(), from_file.ranges.len());
    for (a, b) in from_moov.ranges.iter().zip(&from_file.ranges) {
        assert_eq!(
            (a.off, a.size, a.base, a.counter0),
            (b.off, b.size, b.base, b.counter0),
            "range"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}
