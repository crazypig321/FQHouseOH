fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        build_sp_crypto();
        return;
    }
    // FQHouseOH patch: compile the Unicorn digest core when building the
    // OpenHarmony target (aarch64-unknown-linux-ohos). Host builds get a Rust
    // stub instead (see endpoints/hongguo/sdk_digest.rs).
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("ohos") {
        build_sdk_digest();
    }
}

fn build_sp_crypto() {
    let sources = [
        "crypto_core/sp_error.c",
        "crypto_core/sp_stream.c",
        "crypto_core/mp4_cenc.c",
        "crypto_core/sp_aes.c",
        "third_party/tiny_aes/aes.c",
    ];
    let mut build = cc::Build::new();
    build
        .include("../native/crypto_core")
        .std("c11")
        .flag_if_supported("/experimental:c11atomics")
        .define("CBC", "0")
        .define("CTR", "0")
        .define("ECB", "1");
    for source in sources {
        let path = format!("../native/{source}");
        println!("cargo:rerun-if-changed={path}");
        build.file(path);
    }
    println!("cargo:rerun-if-changed=../native/crypto_core/sp_crypto.h");
    build.compile("sp_crypto_core");
}

/// Compiles the libmetasec_ml.so digest core (native/sdk_digest) against the
/// vendored Unicorn 2.1.3 prebuilt (rust/vendor/unicorn) and links
/// libunicorn.a statically into fqapi_core. ohos-only.
fn build_sdk_digest() {
    let source = "../native/sdk_digest/sdk_digest_core.c";
    println!("cargo:rerun-if-changed={source}");
    println!("cargo:rerun-if-changed=../native/sdk_digest/sdk_digest.h");
    println!("cargo:rerun-if-changed=vendor/unicorn/lib/libunicorn.a");
    let mut build = cc::Build::new();
    build
        .include("../native/sdk_digest")
        .include("vendor/unicorn/include")
        .std("c11")
        .file(source);
    build.compile("sdk_digest_core");
    // Absolute path: the linker's CWD is the workspace root, not the manifest
    // dir, so a relative -L would resolve to a nonexistent directory.
    let vendor_lib = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor/unicorn/lib");
    println!("cargo:rustc-link-search=native={}", vendor_lib.display());
    println!("cargo:rustc-link-lib=static=unicorn");
    // Unicorn pulls in pthread; the OHOS toolchain resolves it from libc.
}
