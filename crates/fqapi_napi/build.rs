// Links against the OHOS Node-API runtime library only for the OpenHarmony
// target; host builds (Windows check/test) must not try to resolve it.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if os == "linux" && env == "ohos" {
        println!("cargo:rustc-link-lib=dylib=ace_napi.z");
    }
}
