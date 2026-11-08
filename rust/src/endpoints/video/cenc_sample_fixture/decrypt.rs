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
fn maps_the_bytevc2_entry_to_vvi1_with_a_minimal_vvcc() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    // Turn the fixture entry into the ByteDance VVC shape: frma = bvc2.
    let entry = file
        .windows(4)
        .position(|w| w == b"encv")
        .expect("encv sample entry");
    let frma = file.windows(4).position(|w| w == b"frma").expect("frma");
    file[frma + 4..frma + 8].copy_from_slice(b"bvc2");
    let sinf = file.windows(4).position(|w| w == b"sinf").expect("sinf") - 4;
    let sinf_size = u32_be(&file, sinf);

    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");

    // The entry carries the in-band VVC tag, not the unknown frma tag.
    assert_eq!(&file[entry..entry + 4], b"vvi1");
    // The sinf box is replaced by a 14-byte vvcC FullBox: mov.c skips the
    // 4 version/flags bytes, then 0xFE encodes lengthSizeMinusOne = 3
    // (u32 NAL length prefixes) with ptl_present_flag = 0 and 0x00
    // declares no parameter-set arrays (they ride in-band, vvi1-style).
    assert_eq!(
        &file[sinf..sinf + 14],
        &[0, 0, 0, 0x0E, b'v', b'v', b'c', b'C', 0, 0, 0, 0, 0xFE, 0x00][..]
    );
    // The fixture's sinf is only 20 bytes (frma alone): the 6-byte tail is
    // too small for a free box, so it is zeroed — demuxers ignore a
    // sub-8-byte remainder at the end of a container.
    assert_eq!(sinf_size, 20, "fixture sinf size");
    assert!(file[sinf + 14..sinf + sinf_size as usize]
        .iter()
        .all(|&b| b == 0));
    assert!(!mp4_needs_cenc_decrypt(&file));
}

/// The real device files carry a 80-byte sinf (frma + schm + schi); the
/// fixture only fits a 20-byte one. A full-size sinf must come back as a
/// 14-byte vvcC plus a free box covering the remainder, so the entry's
/// child box chain stays walkable.
#[test]
fn fills_a_real_sized_sinf_with_vvcc_and_a_free_box() {
    let frma = box_bytes(b"frma", b"bvc2");
    let schm = box_bytes(b"schm", &[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    let schi = box_bytes(b"schi", &vec![0u8; 32]);
    let sinf = box_bytes(b"sinf", &[frma, schm, schi].concat());
    assert_eq!(sinf.len(), 80, "real sinf size");
    let entry = box_bytes(b"encv", &[vec![0u8; 78], sinf].concat());
    // stsd payload: version/flags + entry_count(1) + the entry itself.
    let stsd = box_bytes(b"stsd", &[vec![0, 0, 0, 0, 0, 0, 0, 1], entry].concat());
    let moov = box_bytes(
        b"moov",
        box_bytes(
            b"trak",
            &box_bytes(b"mdia", &box_bytes(b"minf", &box_bytes(b"stbl", &stsd))),
        )
        .as_slice(),
    );

    let mut patches = Vec::new();
    for boxes in mp4_track_boxes(&moov) {
        collect_sample_entry_patches(&moov, &boxes, 0, &mut patches);
    }
    assert_eq!(patches.len(), 2, "entry tag + sinf replacement");
    patches.sort_by_key(|p| p.off);
    let mut patched = moov.clone();
    for p in &patches {
        patched[p.off as usize..p.off as usize + p.bytes.len()].copy_from_slice(&p.bytes);
    }

    // Layout: moov 8 + trak 8 + mdia 8 + minf 8 + stbl 8 + stsd 8 + 8
    // version/flags + entry_count = 56, entry fourcc at 60, its 78-byte
    // fixed part ends at 142 where the sinf box sits.
    assert_eq!(&patched[60..64], b"vvi1", "entry tag");
    assert_eq!(
        &patched[142..156],
        &[0, 0, 0, 0x0E, b'v', b'v', b'c', b'C', 0, 0, 0, 0, 0xFE, 0x00][..]
    );
    let free_size = u32_be(&patched, 156);
    assert_eq!(&patched[160..164], b"free", "free box type");
    assert_eq!(free_size as usize, 80 - 14, "vvcC + free == sinf size");
    assert!(patched[164..222].iter().all(|&b| b == 0));
    assert_eq!(patched.len(), 222, "moov size");
    assert_eq!(patches[0].bytes, b"vvi1".to_vec());
    assert_eq!(patches[1].bytes.len(), 80, "sinf-sized replacement");
}

fn box_bytes(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(8 + payload.len());
    v.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
    v.extend_from_slice(typ);
    v.extend_from_slice(payload);
    v
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
