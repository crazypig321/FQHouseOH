//! fqapi_napi - Node-API adapter exposing the fqapi_core Rust core to
//! HarmonyOS ArkTS. This replaces the flutter_rust_bridge surface used by the
//! fqapp Flutter client: the same nine `rust/src/api/mod.rs` entry points,
//! registered as a native JS module (`libfqapi_napi.so`) instead of FRB.
//!
//! Design:
//! - Every async export uses the napi_create_async_work pattern: the JS
//!   callback creates a promise and queues a work item; `execute` runs on a
//!   system worker thread and blocks on the core future using this crate's
//!   own tokio runtime (fqapi_core expects the host to provide one, FRB did);
//!   `complete` runs on the JS thread and resolves the promise.
//! - Panics never unwind across the FFI boundary (fqapi_core contract): every
//!   core call is wrapped in catch_unwind.
//! - Worker-thread code never touches napi_env; only `complete` callbacks do.
//! - Bodies travel as Uint8Array (input) / ArrayBuffer (output) to avoid
//!   base64 overhead; the loopback HTTP adapter stays the path for resource
//!   URLs (/src/...).

// Type aliases intentionally mirror the lowercase C names of node_api.h.
#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use once_cell::sync::Lazy;

use fqapi_core::api::BridgeResponse;

// ---------------------------------------------------------------------------
// Node-API raw declarations (subset of the OHOS NDK node_api.h in use).
// ---------------------------------------------------------------------------

type napi_env = *mut c_void;
type napi_value = *mut c_void;
type napi_callback_info = *mut c_void;
// Handles stored in ctx structs cross threads; integer aliases keep those
// structs Send-friendly (raw pointers are not Send).
type napi_deferred = usize;
type napi_async_work = usize;
type napi_status = i32;

const NAPI_OK: napi_status = 0;

type napi_callback = Option<unsafe extern "C" fn(napi_env, napi_callback_info) -> napi_value>;
type napi_async_execute_callback = Option<unsafe extern "C" fn(napi_env, *mut c_void)>;
type napi_async_complete_callback = Option<unsafe extern "C" fn(napi_env, napi_status, *mut c_void)>;

#[repr(C)]
struct NapiModule {
    nm_version: i32,
    nm_flags: u32,
    nm_filename: *const c_char,
    nm_register_func: napi_callback,
    nm_modname: *const c_char,
    nm_priv: *mut c_void,
    reserved: [*mut c_void; 4],
}

extern "C" {
    fn napi_module_register(mod_: *mut NapiModule);
    fn napi_get_cb_info(
        env: napi_env,
        cbinfo: napi_callback_info,
        argc: *mut usize,
        argv: *mut napi_value,
        this_arg: *mut napi_value,
        data: *mut *mut c_void,
    ) -> napi_status;
    fn napi_create_string_utf8(
        env: napi_env,
        s: *const c_char,
        length: usize,
        result: *mut napi_value,
    ) -> napi_status;
    fn napi_get_value_string_utf8(
        env: napi_env,
        value: napi_value,
        buf: *mut c_char,
        bufsize: usize,
        result: *mut usize,
    ) -> napi_status;
    fn napi_get_value_uint32(env: napi_env, value: napi_value, result: *mut u32) -> napi_status;
    fn napi_get_value_int64(env: napi_env, value: napi_value, result: *mut i64) -> napi_status;
    fn napi_get_boolean(env: napi_env, value: bool, result: *mut napi_value) -> napi_status;
    fn napi_get_undefined(env: napi_env, result: *mut napi_value) -> napi_status;
    fn napi_create_object(env: napi_env, result: *mut napi_value) -> napi_status;
    fn napi_create_uint32(env: napi_env, value: u32, result: *mut napi_value) -> napi_status;
    fn napi_set_named_property(
        env: napi_env,
        object: napi_value,
        name: *const c_char,
        value: napi_value,
    ) -> napi_status;
    fn napi_create_function(
        env: napi_env,
        name: *const c_char,
        length: usize,
        cb: napi_callback,
        data: *mut c_void,
        result: *mut napi_value,
    ) -> napi_status;
    fn napi_create_promise(
        env: napi_env,
        deferred: *mut napi_deferred,
        promise: *mut napi_value,
    ) -> napi_status;
    fn napi_resolve_deferred(
        env: napi_env,
        deferred: napi_deferred,
        resolution: napi_value,
    ) -> napi_status;
    fn napi_reject_deferred(
        env: napi_env,
        deferred: napi_deferred,
        rejection: napi_value,
    ) -> napi_status;
    fn napi_create_error(
        env: napi_env,
        code: napi_value,
        msg: napi_value,
        result: *mut napi_value,
    ) -> napi_status;
    fn napi_create_async_work(
        env: napi_env,
        async_resource: napi_value,
        async_resource_name: napi_value,
        execute: napi_async_execute_callback,
        complete: napi_async_complete_callback,
        data: *mut c_void,
        result: *mut napi_async_work,
    ) -> napi_status;
    fn napi_queue_async_work(env: napi_env, work: napi_async_work) -> napi_status;
    fn napi_delete_async_work(env: napi_env, work: napi_async_work) -> napi_status;
    fn napi_get_typedarray_info(
        env: napi_env,
        typedarray: napi_value,
        ty: *mut i32,
        length: *mut usize,
        data: *mut *mut c_void,
        arraybuffer: *mut napi_value,
        byte_offset: *mut usize,
    ) -> napi_status;
    fn napi_create_arraybuffer(
        env: napi_env,
        byte_length: usize,
        data: *mut *mut c_void,
        result: *mut napi_value,
    ) -> napi_status;
}

// ---------------------------------------------------------------------------
// Tokio runtime driving fqapi_core futures off the JS thread.
// ---------------------------------------------------------------------------

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("failed to build tokio runtime for fqapi_core")
    });
    &RT
}

// ---------------------------------------------------------------------------
// napi value helpers. All are best-effort: on failure they produce null
// values / defaults rather than aborting, since the module must never crash
// the JS thread.
// ---------------------------------------------------------------------------

unsafe fn argv_of(env: napi_env, info: napi_callback_info, max: usize) -> Vec<napi_value> {
    let mut argc: usize = max;
    let mut argv: Vec<napi_value> = vec![ptr::null_mut(); max];
    napi_get_cb_info(
        env,
        info,
        &mut argc,
        argv.as_mut_ptr(),
        ptr::null_mut(),
        ptr::null_mut(),
    );
    argv.truncate(argc.min(max));
    argv
}

unsafe fn make_string(env: napi_env, s: &str) -> napi_value {
    let mut out = ptr::null_mut();
    if napi_create_string_utf8(env, s.as_ptr() as *const c_char, s.len(), &mut out) != NAPI_OK {
        return ptr::null_mut();
    }
    out
}

unsafe fn arg_string(env: napi_env, v: napi_value) -> String {
    if v.is_null() {
        return String::new();
    }
    let mut len: usize = 0;
    if napi_get_value_string_utf8(env, v, ptr::null_mut(), 0, &mut len) != NAPI_OK {
        return String::new();
    }
    let mut buf: Vec<u8> = vec![0; len + 1];
    if napi_get_value_string_utf8(env, v, buf.as_mut_ptr() as *mut c_char, buf.len(), &mut len)
        != NAPI_OK
    {
        return String::new();
    }
    String::from_utf8_lossy(&buf[..len]).into_owned()
}

unsafe fn arg_uint(env: napi_env, v: napi_value, default: u32) -> u32 {
    let mut out: u32 = 0;
    if !v.is_null() && napi_get_value_uint32(env, v, &mut out) == NAPI_OK {
        out
    } else {
        default
    }
}

unsafe fn arg_int64(env: napi_env, v: napi_value, default: i64) -> i64 {
    let mut out: i64 = 0;
    if !v.is_null() && napi_get_value_int64(env, v, &mut out) == NAPI_OK {
        out
    } else {
        default
    }
}

unsafe fn typedarray_bytes(env: napi_env, v: napi_value) -> Option<Vec<u8>> {
    if v.is_null() {
        return None;
    }
    let mut ty: i32 = 0;
    let mut len: usize = 0;
    let mut data: *mut c_void = ptr::null_mut();
    let mut ab: napi_value = ptr::null_mut();
    let mut off: usize = 0;
    if napi_get_typedarray_info(env, v, &mut ty, &mut len, &mut data, &mut ab, &mut off) != NAPI_OK {
        return None;
    }
    if data.is_null() {
        return Some(Vec::new());
    }
    Some(std::slice::from_raw_parts(data as *const u8, len).to_vec())
}

unsafe fn make_arraybuffer(env: napi_env, bytes: &[u8]) -> napi_value {
    let mut out = ptr::null_mut();
    let mut data: *mut c_void = ptr::null_mut();
    if napi_create_arraybuffer(env, bytes.len(), &mut data, &mut out) != NAPI_OK {
        return ptr::null_mut();
    }
    if !data.is_null() && !bytes.is_empty() {
        ptr::copy_nonoverlapping(bytes.as_ptr(), data as *mut u8, bytes.len());
    }
    out
}

unsafe fn set_string_named(env: napi_env, obj: napi_value, name: &[u8], value: &str) {
    // `name` must be a NUL-terminated byte string literal (b"xxx\0").
    napi_set_named_property(
        env,
        obj,
        name.as_ptr() as *const c_char,
        make_string(env, value),
    );
}

unsafe fn set_uint32_named(env: napi_env, obj: napi_value, name: &[u8], value: u32) {
    let mut out = ptr::null_mut();
    if napi_create_uint32(env, value, &mut out) == NAPI_OK {
        napi_set_named_property(env, obj, name.as_ptr() as *const c_char, out);
    }
}

unsafe fn resolve_string(env: napi_env, deferred: napi_deferred, s: &str) {
    napi_resolve_deferred(env, deferred, make_string(env, s));
}

unsafe fn resolve_undefined(env: napi_env, deferred: napi_deferred) {
    let mut v = ptr::null_mut();
    napi_get_undefined(env, &mut v);
    napi_resolve_deferred(env, deferred, v);
}

unsafe fn reject_string(env: napi_env, deferred: napi_deferred, msg: &str) {
    let mut err = ptr::null_mut();
    napi_create_error(env, ptr::null_mut(), make_string(env, msg), &mut err);
    napi_reject_deferred(env, deferred, err);
}

/// Creates and queues an async work item owning `ctx`. On any napi failure the
/// boxed ctx is reclaimed here (neither execute nor complete will run) and the
/// promise is rejected, so no path leaks or dangles.
unsafe fn queue_work<T>(
    env: napi_env,
    name: &str,
    ctx: Box<T>,
    execute: unsafe extern "C" fn(napi_env, *mut c_void),
    complete: unsafe extern "C" fn(napi_env, napi_status, *mut c_void),
    promise: napi_value,
    deferred: napi_deferred,
) -> napi_value {
    let raw = Box::into_raw(ctx);
    let mut work: napi_async_work = 0;
    if napi_create_async_work(
        env,
        ptr::null_mut(),
        make_string(env, name),
        Some(execute),
        Some(complete),
        raw as *mut c_void,
        &mut work,
    ) != NAPI_OK
    {
        drop(Box::from_raw(raw));
        reject_string(env, deferred, "napi_create_async_work failed");
        return promise;
    }
    if napi_queue_async_work(env, work) != NAPI_OK {
        napi_delete_async_work(env, work);
        drop(Box::from_raw(raw));
        reject_string(env, deferred, "napi_queue_async_work failed");
        return promise;
    }
    promise
}

// ---------------------------------------------------------------------------
// Synchronous exports.
// ---------------------------------------------------------------------------

unsafe extern "C" fn js_version(env: napi_env, _info: napi_callback_info) -> napi_value {
    let v = catch_unwind(fqapi_core::api::version).unwrap_or_default();
    make_string(env, &v)
}

unsafe extern "C" fn js_cancel(env: napi_env, info: napi_callback_info) -> napi_value {
    let argv = argv_of(env, info, 1);
    let id = if argv.len() == 1 { arg_string(env, argv[0]) } else { String::new() };
    let cancelled =
        catch_unwind(AssertUnwindSafe(|| fqapi_core::api::cancel(id))).unwrap_or(false);
    let mut out = ptr::null_mut();
    napi_get_boolean(env, cancelled, &mut out);
    out
}

unsafe extern "C" fn js_set_device_pool_key(
    env: napi_env,
    info: napi_callback_info,
) -> napi_value {
    let argv = argv_of(env, info, 1);
    let mut out = ptr::null_mut();
    let key = match argv.len() {
        1 => typedarray_bytes(env, argv[0]),
        _ => None,
    };
    let ok = match key {
        Some(key) => catch_unwind(AssertUnwindSafe(|| fqapi_core::api::set_device_pool_key(key)))
            .map(|r| r.is_ok())
            .unwrap_or(false),
        None => false,
    };
    napi_get_boolean(env, ok, &mut out);
    out
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

struct InitCtx {
    deferred: napi_deferred,
    config_path: String,
    pool_path: String,
    filter_path: String,
    runtime_dir: String,
    port: u16,
    mock_upstream_origin: String,
    result: Option<Result<String, String>>,
    panicked: bool,
}

unsafe extern "C" fn init_execute(_env: napi_env, data: *mut c_void) {
    let ctx = &mut *(data as *mut InitCtx);
    let config_path = std::mem::take(&mut ctx.config_path);
    let pool_path = std::mem::take(&mut ctx.pool_path);
    let filter_path = std::mem::take(&mut ctx.filter_path);
    let runtime_dir = std::mem::take(&mut ctx.runtime_dir);
    let mock = std::mem::take(&mut ctx.mock_upstream_origin);
    let port = ctx.port;
    let r = catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(fqapi_core::api::init(
            config_path,
            pool_path,
            filter_path,
            runtime_dir,
            port,
            mock,
        ))
    }));
    match r {
        Ok(res) => ctx.result = Some(res),
        Err(_) => ctx.panicked = true,
    }
}

unsafe extern "C" fn init_complete(env: napi_env, _status: napi_status, data: *mut c_void) {
    let mut ctx = Box::from_raw(data as *mut InitCtx);
    if ctx.panicked {
        reject_string(env, ctx.deferred, "fqapi_core panicked during init");
        return;
    }
    match ctx.result.take() {
        Some(Ok(s)) => resolve_string(env, ctx.deferred, &s),
        Some(Err(e)) => reject_string(env, ctx.deferred, &e),
        None => reject_string(env, ctx.deferred, "init produced no result"),
    }
}

unsafe extern "C" fn js_init(env: napi_env, info: napi_callback_info) -> napi_value {
    let argv = argv_of(env, info, 6);
    let mut deferred: napi_deferred = 0;
    let mut promise = ptr::null_mut();
    if napi_create_promise(env, &mut deferred, &mut promise) != NAPI_OK {
        let mut u = ptr::null_mut();
        napi_get_undefined(env, &mut u);
        return u;
    }
    if argv.len() != 6 {
        reject_string(env, deferred, "init expects 6 arguments");
        return promise;
    }
    let ctx = InitCtx {
        deferred,
        config_path: arg_string(env, argv[0]),
        pool_path: arg_string(env, argv[1]),
        filter_path: arg_string(env, argv[2]),
        runtime_dir: arg_string(env, argv[3]),
        port: arg_uint(env, argv[4], 8080) as u16,
        mock_upstream_origin: arg_string(env, argv[5]),
        result: None,
        panicked: false,
    };
    queue_work(env, "fqcore.init", Box::new(ctx), init_execute, init_complete, promise, deferred)
}

// ---------------------------------------------------------------------------
// request
// ---------------------------------------------------------------------------

struct RequestCtx {
    deferred: napi_deferred,
    request_id: String,
    method: String,
    path: String,
    query: String,
    body: Vec<u8>,
    timeout_ms: i64,
    result: Option<Result<BridgeResponse, String>>,
    panicked: bool,
}

unsafe extern "C" fn request_execute(_env: napi_env, data: *mut c_void) {
    let ctx = &mut *(data as *mut RequestCtx);
    let request_id = std::mem::take(&mut ctx.request_id);
    let method = std::mem::take(&mut ctx.method);
    let path = std::mem::take(&mut ctx.path);
    let query = std::mem::take(&mut ctx.query);
    let body = std::mem::take(&mut ctx.body);
    let timeout_ms = ctx.timeout_ms;
    let r = catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(fqapi_core::api::request(
            request_id,
            method,
            path,
            query,
            body,
            timeout_ms,
        ))
    }));
    match r {
        Ok(res) => ctx.result = Some(res),
        Err(_) => ctx.panicked = true,
    }
}

unsafe extern "C" fn request_complete(env: napi_env, _status: napi_status, data: *mut c_void) {
    let mut ctx = Box::from_raw(data as *mut RequestCtx);
    if ctx.panicked {
        reject_string(env, ctx.deferred, "fqapi_core panicked during request");
        return;
    }
    match ctx.result.take() {
        Some(Ok(resp)) => {
            let mut obj = ptr::null_mut();
            if napi_create_object(env, &mut obj) != NAPI_OK {
                reject_string(env, ctx.deferred, "napi_create_object failed");
                return;
            }
            set_uint32_named(env, obj, b"status\0", resp.status as u32);
            set_string_named(env, obj, b"contentType\0", &resp.content_type);
            napi_set_named_property(env, obj, b"body\0".as_ptr() as *const c_char, make_arraybuffer(env, &resp.body));
            napi_resolve_deferred(env, ctx.deferred, obj);
        }
        Some(Err(e)) => reject_string(env, ctx.deferred, &e),
        None => reject_string(env, ctx.deferred, "request produced no result"),
    }
}

unsafe extern "C" fn js_request(env: napi_env, info: napi_callback_info) -> napi_value {
    let argv = argv_of(env, info, 6);
    let mut deferred: napi_deferred = 0;
    let mut promise = ptr::null_mut();
    if napi_create_promise(env, &mut deferred, &mut promise) != NAPI_OK {
        let mut u = ptr::null_mut();
        napi_get_undefined(env, &mut u);
        return u;
    }
    if argv.len() != 6 {
        reject_string(env, deferred, "request expects 6 arguments");
        return promise;
    }
    let body = match typedarray_bytes(env, argv[4]) {
        Some(b) => b,
        None => {
            reject_string(env, deferred, "request body must be a Uint8Array");
            return promise;
        }
    };
    let ctx = RequestCtx {
        deferred,
        request_id: arg_string(env, argv[0]),
        method: arg_string(env, argv[1]),
        path: arg_string(env, argv[2]),
        query: arg_string(env, argv[3]),
        body,
        timeout_ms: arg_int64(env, argv[5], 0),
        result: None,
        panicked: false,
    };
    queue_work(
        env,
        "fqcore.request",
        Box::new(ctx),
        request_execute,
        request_complete,
        promise,
        deferred,
    )
}

// ---------------------------------------------------------------------------
// status / baseUrl / sessionCapability (plain String futures)
// ---------------------------------------------------------------------------

struct StringCtx {
    deferred: napi_deferred,
    result: Option<String>,
    panicked: bool,
}

unsafe extern "C" fn status_execute(_env: napi_env, data: *mut c_void) {
    let ctx = &mut *(data as *mut StringCtx);
    let r = catch_unwind(AssertUnwindSafe(|| runtime().block_on(fqapi_core::api::status())));
    match r {
        Ok(res) => ctx.result = Some(res),
        Err(_) => ctx.panicked = true,
    }
}

unsafe extern "C" fn base_url_execute(_env: napi_env, data: *mut c_void) {
    let ctx = &mut *(data as *mut StringCtx);
    let r = catch_unwind(AssertUnwindSafe(|| runtime().block_on(fqapi_core::api::base_url())));
    match r {
        Ok(res) => ctx.result = Some(res),
        Err(_) => ctx.panicked = true,
    }
}

unsafe extern "C" fn session_capability_execute(_env: napi_env, data: *mut c_void) {
    let ctx = &mut *(data as *mut StringCtx);
    let r =
        catch_unwind(AssertUnwindSafe(|| runtime().block_on(fqapi_core::api::session_capability())));
    match r {
        Ok(res) => ctx.result = Some(res),
        Err(_) => ctx.panicked = true,
    }
}

unsafe extern "C" fn string_complete(env: napi_env, _status: napi_status, data: *mut c_void) {
    let mut ctx = Box::from_raw(data as *mut StringCtx);
    if ctx.panicked {
        reject_string(env, ctx.deferred, "fqapi_core panicked");
        return;
    }
    match ctx.result.take() {
        Some(s) => resolve_string(env, ctx.deferred, &s),
        None => reject_string(env, ctx.deferred, "no result"),
    }
}

unsafe extern "C" fn js_status(env: napi_env, _info: napi_callback_info) -> napi_value {
    js_string_future(env, status_execute)
}

unsafe extern "C" fn js_base_url(env: napi_env, _info: napi_callback_info) -> napi_value {
    js_string_future(env, base_url_execute)
}

unsafe extern "C" fn js_session_capability(env: napi_env, _info: napi_callback_info) -> napi_value {
    js_string_future(env, session_capability_execute)
}

unsafe fn js_string_future(
    env: napi_env,
    execute: unsafe extern "C" fn(napi_env, *mut c_void),
) -> napi_value {
    let mut deferred: napi_deferred = 0;
    let mut promise = ptr::null_mut();
    if napi_create_promise(env, &mut deferred, &mut promise) != NAPI_OK {
        let mut u = ptr::null_mut();
        napi_get_undefined(env, &mut u);
        return u;
    }
    let ctx = StringCtx {
        deferred,
        result: None,
        panicked: false,
    };
    queue_work(
        env,
        "fqcore.string",
        Box::new(ctx),
        execute,
        string_complete,
        promise,
        deferred,
    )
}

// ---------------------------------------------------------------------------
// shutdown
// ---------------------------------------------------------------------------

struct ShutdownCtx {
    deferred: napi_deferred,
    result: Option<Result<(), String>>,
    panicked: bool,
}

unsafe extern "C" fn shutdown_execute(_env: napi_env, data: *mut c_void) {
    let ctx = &mut *(data as *mut ShutdownCtx);
    let r = catch_unwind(AssertUnwindSafe(|| runtime().block_on(fqapi_core::api::shutdown())));
    match r {
        Ok(res) => ctx.result = Some(res),
        Err(_) => ctx.panicked = true,
    }
}

unsafe extern "C" fn shutdown_complete(env: napi_env, _status: napi_status, data: *mut c_void) {
    let mut ctx = Box::from_raw(data as *mut ShutdownCtx);
    if ctx.panicked {
        reject_string(env, ctx.deferred, "fqapi_core panicked during shutdown");
        return;
    }
    match ctx.result.take() {
        Some(Ok(())) => resolve_undefined(env, ctx.deferred),
        Some(Err(e)) => reject_string(env, ctx.deferred, &e),
        None => reject_string(env, ctx.deferred, "shutdown produced no result"),
    }
}

unsafe extern "C" fn js_shutdown(env: napi_env, _info: napi_callback_info) -> napi_value {
    let mut deferred: napi_deferred = 0;
    let mut promise = ptr::null_mut();
    if napi_create_promise(env, &mut deferred, &mut promise) != NAPI_OK {
        let mut u = ptr::null_mut();
        napi_get_undefined(env, &mut u);
        return u;
    }
    let ctx = ShutdownCtx {
        deferred,
        result: None,
        panicked: false,
    };
    queue_work(
        env,
        "fqcore.shutdown",
        Box::new(ctx),
        shutdown_execute,
        shutdown_complete,
        promise,
        deferred,
    )
}

// ---------------------------------------------------------------------------
// Module registration.
// ---------------------------------------------------------------------------

unsafe extern "C" fn module_init(env: napi_env, exports: napi_value) -> napi_value {
    unsafe fn export(env: napi_env, exports: napi_value, name: &[u8], cb: napi_callback) {
        // `name` must be a NUL-terminated byte string literal (b"xxx\0").
        let mut f = ptr::null_mut();
        if napi_create_function(
            env,
            name.as_ptr() as *const c_char,
            name.len() - 1,
            cb,
            ptr::null_mut(),
            &mut f,
        ) == NAPI_OK
        {
            napi_set_named_property(env, exports, name.as_ptr() as *const c_char, f);
        }
    }
    export(env, exports, b"version\0", Some(js_version));
    export(env, exports, b"cancel\0", Some(js_cancel));
    export(env, exports, b"setDevicePoolKey\0", Some(js_set_device_pool_key));
    export(env, exports, b"init\0", Some(js_init));
    export(env, exports, b"request\0", Some(js_request));
    export(env, exports, b"status\0", Some(js_status));
    export(env, exports, b"baseUrl\0", Some(js_base_url));
    export(env, exports, b"sessionCapability\0", Some(js_session_capability));
    export(env, exports, b"shutdown\0", Some(js_shutdown));
    exports
}

static mut MODULE: NapiModule = NapiModule {
    nm_version: 1,
    nm_flags: 0,
    nm_filename: ptr::null(),
    nm_register_func: Some(module_init),
    nm_modname: b"fqapi_napi\0".as_ptr() as *const c_char,
    nm_priv: ptr::null_mut(),
    reserved: [ptr::null_mut(); 4],
};

fn register_module() {
    unsafe {
        napi_module_register(ptr::addr_of_mut!(MODULE));
    }
}

#[link_section = ".init_array"]
#[used]
static REGISTER_ENTRY: fn() = register_module;
