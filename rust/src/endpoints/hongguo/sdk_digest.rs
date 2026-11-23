//! SDK v5 Metasec digest（libmetasec_ml.so Unicorn 全量模拟，ohos 独占）。
//!
//! 对齐 hongguo-drama `phone_sdk_core_v5.py` 的 `SdkDigestCore`：VM 一次建
//! 立、多次 digest 复用（heap / once-done 状态跨调用保留）。宿主（Windows /
//! Android）构建无 Unicorn 链接，返回错误而非 panic——SDK 链路在宿主上整体
//! 不可用，由上层回退。
//!
//! C 核心：`native/sdk_digest/sdk_digest_core.c`（build.rs 在
//! `target_env = "ohos"` 时编译并静态链接 `rust/vendor/unicorn`）。
//!
//! 引擎串行：`digest()` 为同步阻塞调用（冷启 ~300ms、热 ~50ms），
//! 异步上下文须用 `spawn_blocking` 包裹。

use std::sync::OnceLock;

/// SDK 链路运行资源路径（ArkTS 侧启动时经 napi `setSdkPaths` 注入一次）。
pub struct SdkPaths {
    /// libmetasec_ml.so 镜像（bundle libs 目录）。
    pub image_path: String,
    /// SDK 链路持久化目录（filesDir 下，device.json 等落点）。
    /// P2/P3（设备注册、签名状态机）消费；P1 尚无读取方。
    #[allow(dead_code)]
    pub cache_dir: String,
}

static PATHS: OnceLock<SdkPaths> = OnceLock::new();

/// 注入 SDK 路径。`image_path` 为空或重复注入返回 false。
pub fn configure(image_path: String, cache_dir: String) -> bool {
    if image_path.trim().is_empty() {
        return false;
    }
    PATHS
        .set(SdkPaths {
            image_path,
            cache_dir,
        })
        .is_ok()
}

/// 已注入的 SDK 路径（SDK 链路各模块共用）。
pub fn paths() -> Option<&'static SdkPaths> {
    PATHS.get()
}

/// 跑一次 52 字节 payload 的 digest，返回 20 字节原始值。
/// 同步阻塞；失败信息面向日志，不面向用户文案。
pub fn digest(payload: &[u8; 52], selector: u32, seconds: u64) -> Result<[u8; 20], String> {
    imp::digest(payload, selector, seconds)
}

/// 锚点自检：固定 payload（32×(0xa0+i) + 16×(0x50+i) + le32(1795000000)，
/// selector=3），期望 digest
/// `62b5cbd4e7db5b1e854aa448ecc5b77d6069302f`（Python / 冒烟 / 本实现三方
/// 对齐）。返回 `digest=<hex> elapsed_ms=<ms>`。
pub fn self_test() -> Result<String, String> {
    let mut payload = [0u8; 52];
    for (i, slot) in payload.iter_mut().enumerate().take(32) {
        *slot = 0xa0 + i as u8;
    }
    for i in 0..16 {
        payload[32 + i] = 0x50 + i as u8;
    }
    payload[48..52].copy_from_slice(&1795000000u32.to_le_bytes());
    let started = std::time::Instant::now();
    match digest(&payload, 3, 1795000000) {
        Ok(out) => {
            let hex: String = out.iter().map(|b| format!("{b:02x}")).collect();
            // 预期 62b5cbd4e7db5b1e854aa448ecc5b77d6069302f（Python / 冒烟 /
            // 本实现三方对齐锚点）。
            if hex != "62b5cbd4e7db5b1e854aa448ecc5b77d6069302f" {
                log::warn!("sdk digest anchor mismatch: {hex}");
            } else {
                log::info!("sdk digest anchor ok");
            }
            Ok(format!(
                "digest={hex} elapsed_ms={}",
                started.elapsed().as_millis()
            ))
        }
        Err(e) => {
            log::warn!("sdk digest anchor failed: {e}");
            Err(e)
        }
    }
}

#[cfg(target_env = "ohos")]
mod imp {
    use std::ffi::{c_char, CStr};
    use std::sync::Mutex;

    use super::paths;

    #[repr(C)]
    struct SdkDigestCtx {
        _private: [u8; 0],
    }

    extern "C" {
        fn sdk_digest_open(
            out: *mut *mut SdkDigestCtx,
            image: *const u8,
            image_size: usize,
            err: *mut c_char,
            err_len: usize,
        ) -> i32;
        fn sdk_digest_run(
            ctx: *mut SdkDigestCtx,
            payload: *const u8,
            selector: u32,
            seconds: u64,
            out: *mut u8,
            err: *mut c_char,
            err_len: usize,
        ) -> i32;
        fn sdk_digest_close(ctx: *mut SdkDigestCtx);
    }

    struct Engine(*mut SdkDigestCtx);
    // 仅在 ENGINE 锁内触碰；指针本身无线程亲和。
    unsafe impl Send for Engine {}

    static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

    fn cstr_err(buf: &[c_char]) -> String {
        let ptr = buf.as_ptr();
        if ptr.is_null() {
            return String::new();
        }
        unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
    }

    pub(super) fn digest(
        payload: &[u8; 52],
        selector: u32,
        seconds: u64,
    ) -> Result<[u8; 20], String> {
        let config = paths().ok_or_else(|| "sdk paths not configured".to_string())?;
        let mut guard = ENGINE.lock().unwrap();
        if guard.is_none() {
            let image = std::fs::read(&config.image_path)
                .map_err(|e| format!("read sdk image failed: {e}"))?;
            let mut ctx: *mut SdkDigestCtx = std::ptr::null_mut();
            let mut err = [0 as c_char; 256];
            let rc = unsafe {
                sdk_digest_open(&mut ctx, image.as_ptr(), image.len(), err.as_mut_ptr(), err.len())
            };
            if rc != 0 {
                return Err(format!("sdk_digest_open: {}", cstr_err(&err)));
            }
            *guard = Some(Engine(ctx));
        }
        let ctx = guard.as_ref().expect("engine present").0;
        let mut out = [0u8; 20];
        let mut err = [0 as c_char; 256];
        let rc = unsafe {
            sdk_digest_run(
                ctx,
                payload.as_ptr(),
                selector,
                seconds,
                out.as_mut_ptr(),
                err.as_mut_ptr(),
                err.len(),
            )
        };
        if rc != 0 {
            // C 契约：run 失败后 ctx 状态不定，必须销毁重建。
            let message = cstr_err(&err);
            unsafe { sdk_digest_close(ctx) };
            *guard = None;
            return Err(format!("sdk_digest_run: {message}"));
        }
        Ok(out)
    }
}

#[cfg(not(target_env = "ohos"))]
mod imp {
    pub(super) fn digest(
        _payload: &[u8; 52],
        _selector: u32,
        _seconds: u64,
    ) -> Result<[u8; 20], String> {
        Err("sdk digest requires the OpenHarmony build".to_string())
    }
}
