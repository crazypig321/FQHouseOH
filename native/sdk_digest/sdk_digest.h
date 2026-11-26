/* libmetasec_ml.so digest core, Unicorn 2.1.3 production build.
 *
 * C port of hongguo-drama's SdkDigestCore (phone_sdk_core_v5.py): loads the
 * SDK shared object into an emulated ARM64 VM, models its emulated-libc /
 * pthread / JNI-failure imports, and runs the digest entry on demand.
 *
 * Lifecycle mirrors the Python reference: the VM is built once by
 * sdk_digest_open() and reused across sdk_digest_run() calls (heap and
 * one-time-init state persist between runs; run-scoped state is reset).
 *
 * The engine is NOT thread-safe: the caller serializes access (the Rust
 * wrapper holds a mutex). After sdk_digest_run() reports failure the ctx is
 * indeterminate and must be closed, not reused.
 */
#ifndef SDK_DIGEST_H
#define SDK_DIGEST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sdk_digest_ctx sdk_digest_ctx;

/* Builds the VM from `image` (ELF64 little-endian ARM64 shared object).
 * The buffer is copied; the caller retains ownership. Returns 0 on success,
 * -1 on failure with a human-readable reason in `err`. */
int sdk_digest_open(sdk_digest_ctx **out, const uint8_t *image, size_t image_size,
                    char *err, size_t err_len);

/* Runs one 52-byte payload through the digest entry.
 * `payload` is exactly 52 bytes, `selector` in 0..15, `seconds` in
 * 0..0xffffffff. Writes 20 raw digest bytes to `out`. Returns 0 on success,
 * -1 on failure (ctx must then be closed). */
int sdk_digest_run(sdk_digest_ctx *ctx, const uint8_t *payload, uint32_t selector,
                   uint64_t seconds, uint8_t out[20], char *err, size_t err_len);

/* Bytes consumed on the emulated heap since sdk_digest_open(). Used by the
 * caller to proactively rebuild the VM before the run-time guard band
 * (mirrors the Python reference's SdkDigestCore.heap attribute). 0 for NULL. */
size_t sdk_digest_heap_used(const sdk_digest_ctx *ctx);

/* Releases the VM and all ctx memory. NULL is a no-op. */
void sdk_digest_close(sdk_digest_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif /* SDK_DIGEST_H */
