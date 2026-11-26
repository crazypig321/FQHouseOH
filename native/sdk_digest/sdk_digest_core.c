/* libmetasec_ml.so digest core, Unicorn 2.1.3 production build.
 *
 * C port of hongguo-drama's SdkDigestCore (phone_sdk_core_v5.py). The smoke
 * build (entry/src/main/cpp/unicorn_smoke/smoke_core.c) proved the semantics
 * on-device; this is the same logic restructured as a reusable context with
 * no napi/hilog/probe/one-shot scaffolding. Hook behavior is intentionally
 * byte-identical so the digest stays stable.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <unicorn/unicorn.h>
#include <unicorn/arm64.h>

#include "sdk_digest.h"

#define BASE 0x1000000ULL
#define HEAP 0x2000000ULL
#define STACK 0x3000000ULL
#define IMPORT 0x4000000ULL
#define STOP 0x5000000ULL

#define DIGEST_ENTRY (BASE + 0x2aac34)
#define DIGEST_BOUNDARY (BASE + 0x17dc48)
#define DIGEST_CORE (BASE + 0xecc40)
#define ARG_VTABLE (BASE + 0x3c8288)
#define VM_GLOBAL_SLOT (BASE + 0x3e8368)
#define JNI_STUB_A (IMPORT + 0xf100)
#define JNI_STUB_B (IMPORT + 0xf110)
#define ONCE_RETURN (IMPORT + 0xf000)

#define ALLOC_TABLE_MAX 8192
#define IMPORT_TABLE_MAX 512
#define MUTEX_TABLE_MAX 64
#define KEY_TABLE_MAX 16
#define ONCE_STACK_MAX 4
#define ONCE_DONE_MAX 32

struct sdk_digest_ctx {
    uc_engine *uc;
    uint8_t *image; /* owned copy of the ELF image */
    size_t image_size;
    uint64_t heap_ptr;
    uint64_t errno_address;

    /* run-scoped state, reset by each sdk_digest_run() */
    int failed;
    int core_returned;
    uint64_t env_reads;

    /* cross-run state, persists for the ctx lifetime (matches Python) */
    struct {
        uint64_t addr;
        uint64_t size;
    } alloc_table[ALLOC_TABLE_MAX];
    int alloc_count;

    struct {
        uint64_t addr;
        char name[64];
    } import_table[IMPORT_TABLE_MAX];
    int import_count;

    struct {
        uint64_t addr;
        int depth;
    } mutex_table[MUTEX_TABLE_MAX];
    int mutex_count;

    struct {
        uint64_t key;
        uint64_t value;
    } key_table[KEY_TABLE_MAX];
    int key_count;

    struct {
        uint64_t control;
        uint64_t lr;
    } once_pending[ONCE_STACK_MAX];
    int once_depth;
    uint64_t once_done[ONCE_DONE_MAX];
    int once_done_count;
};

/* OHOS musl does not export __clear_cache and the cargo link does not pull
 * in compiler-rt builtins (the hvigor/CMake path does, which is why the
 * unicorn_smoke module loads). Unicorn's TCG calls __clear_cache after
 * writing JIT code, so provide the aarch64 implementation here, mirroring
 * the OHOS NDK compiler-rt clear_cache.c byte-for-byte in behavior: DC CVAU
 * loop (unless CTR_EL0.IDC), DSB ISH, IC IVAU loop (unless CTR_EL0.DIC),
 * DSB ISH, ISB. EL0 permits only IC IVAU — IC IALLU is UNDEFINED at EL0 and
 * the first P1 build crashed with SIGILL on it. Weak: if a future toolchain
 * links builtins, that definition wins and no duplicate-symbol error. */
#if defined(__aarch64__)
__attribute__((weak)) void __clear_cache(void *start, void *end)
{
    uintptr_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    uintptr_t d_line = (uintptr_t)4 << ((ctr >> 16) & 0xfu);
    if (!(ctr & (1u << 28))) { /* CTR_EL0.IDC: DC CVAU to PoU not required */
        for (uintptr_t p = (uintptr_t)start & ~(d_line - 1);
             p < (uintptr_t)end; p += d_line) {
            __asm__ volatile("dc cvau, %0" : : "r"(p) : "memory");
        }
    }
    __asm__ volatile("dsb ish" ::: "memory");
    uintptr_t i_line = (uintptr_t)4 << (ctr & 0xfu);
    if (!(ctr & (1u << 29))) { /* CTR_EL0.DIC: IC IVAU not required */
        for (uintptr_t p = (uintptr_t)start & ~(i_line - 1);
             p < (uintptr_t)end; p += i_line) {
            __asm__ volatile("ic ivau, %0" : : "r"(p) : "memory");
        }
        __asm__ volatile("dsb ish" ::: "memory");
    }
    __asm__ volatile("isb" ::: "memory");
}
#endif

/* ---- error bookkeeping ---- */

static void ctx_fail(sdk_digest_ctx *ctx)
{
    ctx->failed = 1;
    uc_emu_stop(ctx->uc);
}

static int report(char *err, size_t err_len, const char *fmt, ...)
{
    if (err != NULL && err_len > 0) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(err, err_len, fmt, ap);
        va_end(ap);
    }
    return -1;
}

/* ---- bump allocator with size tracking (heap region) ---- */

static uint64_t bump(sdk_digest_ctx *ctx, uint64_t size)
{
    uint64_t addr = ctx->heap_ptr;
    ctx->heap_ptr += (size + 31) / 16 * 16;
    if (ctx->heap_ptr >= HEAP + 0x800000) {
        ctx_fail(ctx);
        return 0;
    }
    return addr;
}

static void note_alloc(sdk_digest_ctx *ctx, uint64_t addr, uint64_t size)
{
    if (ctx->alloc_count < ALLOC_TABLE_MAX) {
        ctx->alloc_table[ctx->alloc_count].addr = addr;
        ctx->alloc_table[ctx->alloc_count].size = size;
    }
    ctx->alloc_count++;
}

static uint64_t alloc_size_of(const sdk_digest_ctx *ctx, uint64_t addr)
{
    for (int i = ctx->alloc_count - 1; i >= 0; i--) {
        if (ctx->alloc_table[i].addr == addr) {
            return ctx->alloc_table[i].size;
        }
    }
    return 0;
}

static uint64_t alloc_zero(sdk_digest_ctx *ctx, uint64_t size)
{
    if (size > 2u * 1024 * 1024) {
        ctx_fail(ctx);
        return 0;
    }
    uint64_t addr = bump(ctx, size);
    if (size) {
        uint8_t *zero = calloc(1, size);
        if (zero == NULL) {
            ctx_fail(ctx);
            return 0;
        }
        uc_mem_write(ctx->uc, addr, zero, size);
        free(zero);
    }
    note_alloc(ctx, addr, size);
    return addr;
}

static uint64_t alloc_bytes(sdk_digest_ctx *ctx, const uint8_t *data, uint64_t size)
{
    uint64_t addr = bump(ctx, size);
    if (size) {
        uc_mem_write(ctx->uc, addr, data, size);
    }
    note_alloc(ctx, addr, size);
    return addr;
}

/* ---- tiny register / memory helpers ---- */

static uint64_t xget(sdk_digest_ctx *ctx, int reg)
{
    uint64_t value = 0;
    uc_reg_read(ctx->uc, reg, &value);
    return value;
}

static void xset(sdk_digest_ctx *ctx, int reg, uint64_t value)
{
    uc_reg_write(ctx->uc, reg, &value);
}

static uint64_t read_u64(sdk_digest_ctx *ctx, uint64_t addr)
{
    uint64_t value = 0;
    uc_mem_read(ctx->uc, addr, &value, 8);
    return value;
}

static void write_u64(sdk_digest_ctx *ctx, uint64_t addr, uint64_t value)
{
    uc_mem_write(ctx->uc, addr, &value, 8);
}

static void write_u32(sdk_digest_ctx *ctx, uint64_t addr, uint32_t value)
{
    uc_mem_write(ctx->uc, addr, &value, 4);
}

/* ---- pthread modeling ---- */

static int *mutex_depth(sdk_digest_ctx *ctx, uint64_t addr)
{
    for (int i = 0; i < ctx->mutex_count; i++) {
        if (ctx->mutex_table[i].addr == addr) {
            return &ctx->mutex_table[i].depth;
        }
    }
    if (ctx->mutex_count >= MUTEX_TABLE_MAX) {
        ctx_fail(ctx);
        return NULL;
    }
    ctx->mutex_table[ctx->mutex_count].addr = addr;
    ctx->mutex_table[ctx->mutex_count].depth = 0;
    return &ctx->mutex_table[ctx->mutex_count++].depth;
}

static int once_is_done(const sdk_digest_ctx *ctx, uint64_t control)
{
    for (int i = 0; i < ctx->once_done_count; i++) {
        if (ctx->once_done[i] == control) {
            return 1;
        }
    }
    return 0;
}

static const char *import_name(const sdk_digest_ctx *ctx, uint64_t addr)
{
    for (int i = 0; i < ctx->import_count; i++) {
        if (ctx->import_table[i].addr == addr) {
            return ctx->import_table[i].name;
        }
    }
    return NULL;
}

/* ---- hooks ---- */

static void hook_env_read(uc_engine *u, uc_mem_type type, uint64_t address,
                          int size, int64_t value, void *user)
{
    (void)u;
    (void)type;
    (void)address;
    (void)size;
    (void)value;
    sdk_digest_ctx *ctx = user;
    ctx->env_reads++;
    if (ctx->env_reads > 64) {
        ctx_fail(ctx);
    }
}

static bool hook_invalid(uc_engine *u, uc_mem_type type, uint64_t address,
                         int size, int64_t value, void *user)
{
    (void)u;
    (void)type;
    (void)address;
    (void)size;
    (void)value;
    sdk_digest_ctx *ctx = user;
    ctx->failed = 1;
    return false;
}

static void hook_interrupt(uc_engine *u, uint32_t intno, void *user)
{
    (void)u;
    sdk_digest_ctx *ctx = user;
    uint64_t call = xget(ctx, UC_ARM64_REG_X8);
    if (intno != 2) {
        ctx_fail(ctx);
        return;
    }
    if (call == 57) { /* close(fd) -> EBADF */
        xset(ctx, UC_ARM64_REG_X0, 0xfffffffffffffff7ULL);
        return;
    }
    if (call != 56) { /* openat */
        ctx_fail(ctx);
        return;
    }
    uint64_t pointer = xget(ctx, UC_ARM64_REG_X1);
    uint8_t byte;
    for (int i = 0; i < 256; i++) {
        uc_mem_read(ctx->uc, pointer + i, &byte, 1);
        if (byte == 0) {
            xset(ctx, UC_ARM64_REG_X0, 0xfffffffffffffffeULL); /* ENOENT */
            return;
        }
    }
    ctx_fail(ctx);
}

static void hook_digest_boundary(uc_engine *u, uint64_t address, uint32_t size,
                                 void *user)
{
    (void)address;
    (void)size;
    sdk_digest_ctx *ctx = user;
    uint64_t slot = xget(ctx, UC_ARM64_REG_X28);
    uint64_t instruction = read_u64(ctx, slot);
    if (instruction == DIGEST_CORE) {
        ctx->core_returned = 1;
        uc_emu_stop(u);
    }
}

/* Emulated libc imports; mirrors phone_sdk_core_v5.py hook(). */
static void hook_import(uc_engine *u, uint64_t address, uint32_t size, void *user)
{
    (void)size;
    sdk_digest_ctx *ctx = user;
    uint64_t a = xget(ctx, UC_ARM64_REG_X0);
    uint64_t b = xget(ctx, UC_ARM64_REG_X1);
    uint64_t c = xget(ctx, UC_ARM64_REG_X2);
    uint64_t d = xget(ctx, UC_ARM64_REG_X3);
    uint64_t value;

    if (address == JNI_STUB_A || address == JNI_STUB_B) {
        uint64_t zero = 0;
        uc_mem_write(u, b, &zero, 8);
        xset(ctx, UC_ARM64_REG_X0, 0xffffffff); /* JNI_ERR */
        xset(ctx, UC_ARM64_REG_PC, xget(ctx, UC_ARM64_REG_LR));
        return;
    }
    if (address == ONCE_RETURN) {
        if (ctx->once_depth <= 0) {
            ctx_fail(ctx);
            return;
        }
        ctx->once_depth--;
        uint64_t control = ctx->once_pending[ctx->once_depth].control;
        uint64_t previous_lr = ctx->once_pending[ctx->once_depth].lr;
        if (ctx->once_done_count < ONCE_DONE_MAX) {
            ctx->once_done[ctx->once_done_count++] = control;
        }
        write_u32(ctx, control, 2);
        xset(ctx, UC_ARM64_REG_X0, 0);
        xset(ctx, UC_ARM64_REG_LR, previous_lr);
        xset(ctx, UC_ARM64_REG_PC, previous_lr);
        return;
    }

    const char *name = import_name(ctx, address);
    if (name == NULL) {
        return; /* not a modeled import; execute the stub bytes */
    }

    if (strcmp(name, "malloc") == 0 || strcmp(name, "calloc") == 0) {
        value = alloc_zero(ctx, name[0] == 'm' ? a : a * b);
    } else if (strcmp(name, "free") == 0) {
        value = 0;
    } else if (strcmp(name, "realloc") == 0) {
        value = alloc_zero(ctx, b);
        if (a && value) {
            uint64_t old = alloc_size_of(ctx, a);
            uint64_t n = b < old ? b : old;
            if (n) {
                uint8_t *scratch = malloc(n);
                if (scratch == NULL) {
                    ctx_fail(ctx);
                    return;
                }
                uc_mem_read(u, a, scratch, n);
                uc_mem_write(u, value, scratch, n);
                free(scratch);
            }
        }
    } else if (strcmp(name, "memcpy") == 0 || strcmp(name, "memmove") == 0 ||
               strcmp(name, "__memcpy_chk") == 0 || strcmp(name, "__memmove_chk") == 0) {
        if (name[0] == '_' && c > d) {
            ctx_fail(ctx);
            return;
        }
        if (c > 8u * 1024 * 1024) {
            ctx_fail(ctx);
            return;
        }
        uint8_t *scratch = malloc(c ? c : 1);
        if (scratch == NULL) {
            ctx_fail(ctx);
            return;
        }
        if (c) {
            uc_mem_read(u, b, scratch, c);
            uc_mem_write(u, a, scratch, c);
        }
        free(scratch);
        value = a;
    } else if (strcmp(name, "memset") == 0 || strcmp(name, "__memset_chk") == 0) {
        if (c > 2u * 1024 * 1024) {
            ctx_fail(ctx);
            return;
        }
        if (name[0] == '_' && c > d) {
            ctx_fail(ctx);
            return;
        }
        uint8_t *scratch = malloc(c ? c : 1);
        if (scratch == NULL) {
            ctx_fail(ctx);
            return;
        }
        memset(scratch, (int)(b & 255), c);
        if (c) {
            uc_mem_write(u, a, scratch, c);
        }
        free(scratch);
        value = a;
    } else if (strcmp(name, "memcmp") == 0) {
        uint8_t *left = malloc(c ? c : 1);
        uint8_t *right = malloc(c ? c : 1);
        if (left == NULL || right == NULL) {
            free(left);
            free(right);
            ctx_fail(ctx);
            return;
        }
        if (c) {
            uc_mem_read(u, a, left, c);
            uc_mem_read(u, b, right, c);
        }
        value = c ? (uint64_t)memcmp(left, right, c) : 0;
        free(left);
        free(right);
    } else if (strcmp(name, "strlen") == 0 || strcmp(name, "__strlen_chk") == 0) {
        value = 0;
        uint8_t byte;
        for (;;) {
            uc_mem_read(u, a + value, &byte, 1);
            if (byte == 0) {
                break;
            }
            value++;
            if (value > 65536) {
                ctx_fail(ctx);
                return;
            }
        }
    } else if (strcmp(name, "pthread_mutex_lock") == 0 ||
               strcmp(name, "pthread_mutex_unlock") == 0) {
        int *depth = mutex_depth(ctx, a);
        if (depth == NULL) {
            return;
        }
        if (name[strlen(name) - 6] == 'n') { /* unlock */
            if (*depth <= 0) {
                ctx_fail(ctx);
                return;
            }
            (*depth)--;
        } else {
            (*depth)++;
        }
        value = 0;
    } else if (strcmp(name, "pthread_cond_broadcast") == 0) {
        value = 0;
    } else if (strcmp(name, "pthread_once") == 0) {
        if (!once_is_done(ctx, a)) {
            if (b < BASE || b >= BASE + 0x500000) {
                ctx_fail(ctx);
                return;
            }
            for (int i = 0; i < ctx->once_depth; i++) {
                if (ctx->once_pending[i].control == a) {
                    ctx_fail(ctx);
                    return;
                }
            }
            if (ctx->once_depth >= ONCE_STACK_MAX) {
                ctx_fail(ctx);
                return;
            }
            ctx->once_pending[ctx->once_depth].control = a;
            ctx->once_pending[ctx->once_depth].lr = xget(ctx, UC_ARM64_REG_LR);
            ctx->once_depth++;
            xset(ctx, UC_ARM64_REG_LR, ONCE_RETURN);
            xset(ctx, UC_ARM64_REG_PC, b);
            return;
        }
        value = 0;
    } else if (strcmp(name, "pthread_key_create") == 0) {
        if (ctx->key_count >= KEY_TABLE_MAX) {
            ctx_fail(ctx);
            return;
        }
        ctx->key_table[ctx->key_count].key = (uint64_t)ctx->key_count + 1;
        ctx->key_table[ctx->key_count].value = 0;
        write_u32(ctx, a, (uint32_t)(ctx->key_count + 1));
        ctx->key_count++;
        value = 0;
    } else if (strcmp(name, "pthread_setspecific") == 0) {
        int found = 0;
        for (int i = 0; i < ctx->key_count; i++) {
            if (ctx->key_table[i].key == a) {
                ctx->key_table[i].value = b;
                found = 1;
            }
        }
        if (!found) {
            ctx_fail(ctx);
            return;
        }
        value = 0;
    } else if (strcmp(name, "pthread_getspecific") == 0) {
        value = 0;
        for (int i = 0; i < ctx->key_count; i++) {
            if (ctx->key_table[i].key == a) {
                value = ctx->key_table[i].value;
            }
        }
    } else if (strcmp(name, "gettid") == 0 || strcmp(name, "getpid") == 0) {
        value = 1;
    } else if (strcmp(name, "syscall") == 0) {
        if (a != 172 && a != 178) {
            ctx_fail(ctx);
            return;
        }
        value = 1;
    } else if (strcmp(name, "clock_gettime") == 0) {
        if (a != 0 && a != 1) {
            ctx_fail(ctx);
            return;
        }
        int64_t seconds = a == 0 ? 1700000000 : 1;
        int64_t zero = 0;
        uc_mem_write(u, b, &seconds, 8);
        uc_mem_write(u, b + 8, &zero, 8);
        value = 0;
    } else if (strcmp(name, "__system_property_find") == 0 ||
               strcmp(name, "getenv") == 0) {
        value = 0;
    } else if (strcmp(name, "__errno") == 0) {
        value = ctx->errno_address;
    } else if (strcmp(name, "__cxa_thread_atexit_impl") == 0) {
        value = 0;
    } else {
        ctx_fail(ctx);
        return;
    }
    xset(ctx, UC_ARM64_REG_X0, value);
    xset(ctx, UC_ARM64_REG_PC, xget(ctx, UC_ARM64_REG_LR));
}

/* ---- ELF loading (PT_LOAD map + dynamic relocations) ---- */

static uint16_t elf_u16(const sdk_digest_ctx *ctx, size_t offset)
{
    uint16_t value;
    memcpy(&value, ctx->image + offset, 2);
    return value;
}

static uint32_t elf_u32(const sdk_digest_ctx *ctx, size_t offset)
{
    uint32_t value;
    memcpy(&value, ctx->image + offset, 4);
    return value;
}

static uint64_t elf_u64(const sdk_digest_ctx *ctx, size_t offset)
{
    uint64_t value;
    memcpy(&value, ctx->image + offset, 8);
    return value;
}

static const char *elf_string(const uint8_t *table, size_t start)
{
    return (const char *)(table + start);
}

static int load_image(sdk_digest_ctx *ctx, char *err, size_t err_len)
{
    uc_engine *uc = ctx->uc;
    const uint8_t *image = ctx->image;

    /* Program headers: map PT_LOAD segments at BASE. */
    uint64_t phoff = elf_u64(ctx, 32);
    uint16_t phentsize = elf_u16(ctx, 54);
    uint16_t phnum = elf_u16(ctx, 56);
    for (uint16_t index = 0; index < phnum; index++) {
        size_t entry = (size_t)phoff + index * phentsize;
        uint32_t kind = elf_u32(ctx, entry);
        uint64_t offset = elf_u64(ctx, entry + 8);
        uint64_t address = elf_u64(ctx, entry + 16);
        uint64_t filesz = elf_u64(ctx, entry + 32);
        if (kind == 1) {
            uc_mem_write(uc, BASE + address, image + offset, filesz);
        }
    }

    /* Section headers: locate .dynsym / .rela.dyn / .rela.plt. */
    uint64_t shoff = elf_u64(ctx, 40);
    uint16_t shentsize = elf_u16(ctx, 58);
    uint16_t shnum = elf_u16(ctx, 60);
    uint16_t shstrndx = elf_u16(ctx, 62);

    size_t dynsym = 0, rela_dyn = 0, rela_plt = 0;
    const uint8_t *shstrtab = image + elf_u64(ctx, (size_t)shoff + shstrndx * shentsize + 24);

    for (uint16_t i = 0; i < shnum; i++) {
        size_t entry = (size_t)shoff + i * shentsize;
        const char *name = elf_string(shstrtab, elf_u32(ctx, entry));
        if (strcmp(name, ".dynsym") == 0) {
            dynsym = entry;
        } else if (strcmp(name, ".rela.dyn") == 0) {
            rela_dyn = entry;
        } else if (strcmp(name, ".rela.plt") == 0) {
            rela_plt = entry;
        }
    }
    if (!dynsym || !rela_dyn || !rela_plt) {
        return report(err, err_len, "required ELF sections missing");
    }

    size_t dynsym_offset = elf_u64(ctx, dynsym + 24);
    uint32_t dynsym_link = elf_u32(ctx, dynsym + 40);
    size_t dynsym_entsize = elf_u64(ctx, dynsym + 56);
    size_t dynstr = (size_t)shoff + dynsym_link * shentsize;
    const uint8_t *strtab = image + elf_u64(ctx, dynstr + 24);

    for (int which = 0; which < 2; which++) {
        size_t section = which == 0 ? rela_dyn : rela_plt;
        size_t offset = elf_u64(ctx, section + 24);
        size_t size = elf_u64(ctx, section + 32);
        for (size_t pos = offset; pos < offset + size; pos += 24) {
            uint64_t r_offset = elf_u64(ctx, pos);
            uint64_t r_info = elf_u64(ctx, pos + 8);
            int64_t r_addend = (int64_t)elf_u64(ctx, pos + 16);
            uint32_t symbol = (uint32_t)(r_info >> 32);
            uint32_t kind = (uint32_t)(r_info & 0xffffffffu);
            uint64_t value;
            if (kind == 1027) { /* R_AARCH64_RELATIVE */
                value = BASE + (uint64_t)r_addend;
            } else if (kind == 1025 || kind == 1026 || kind == 257) {
                size_t sym_entry = dynsym_offset + symbol * dynsym_entsize;
                uint32_t st_name = elf_u32(ctx, sym_entry);
                uint16_t st_shndx = elf_u16(ctx, sym_entry + 6);
                uint64_t st_value = elf_u64(ctx, sym_entry + 8);
                if (st_shndx) {
                    value = BASE + st_value + (uint64_t)r_addend;
                } else {
                    value = IMPORT + (uint64_t)symbol * 128;
                    if (ctx->import_count < IMPORT_TABLE_MAX) {
                        ctx->import_table[ctx->import_count].addr = value;
                        snprintf(ctx->import_table[ctx->import_count].name, 64, "%s",
                                 elf_string(strtab, st_name));
                        ctx->import_count++;
                    } else {
                        return report(err, err_len, "import table full");
                    }
                }
            } else {
                return report(err, err_len, "unsupported relocation %u", kind);
            }
            write_u64(ctx, BASE + r_offset, value);
        }
    }
    return 0;
}

/* ---- public API ---- */

int sdk_digest_open(sdk_digest_ctx **out, const uint8_t *image, size_t image_size,
                    char *err, size_t err_len)
{
    *out = NULL;
    if (image == NULL || image_size < 1024 || image_size > 64u * 1024 * 1024) {
        return report(err, err_len, "image size out of bounds (%zu)", image_size);
    }
    uint64_t magic;
    memcpy(&magic, image, 8);
    if (magic != 0x00010102464c457fULL) {
        return report(err, err_len, "not an ELF64 LSB shared object");
    }

    /* TCG needs an RWX mapping for its translation buffer. Without the JIT
     * entitlement (ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY) mmap
     * denies it and QEMU's legacy alloc path exit(1)s the process instead of
     * returning an error (appspawn turns that into a CppCrash). Probe first
     * so the caller gets a clean error and the ladder fallback can engage. */
    {
        void *probe = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (probe == MAP_FAILED) {
            return report(err, err_len,
                          "RWX mapping unavailable (JIT permission missing), errno=%d",
                          errno);
        }
        munmap(probe, 4096);
    }

    sdk_digest_ctx *ctx = calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        return report(err, err_len, "host OOM");
    }
    ctx->heap_ptr = HEAP;
    ctx->image = malloc(image_size);
    if (ctx->image == NULL) {
        free(ctx);
        return report(err, err_len, "host OOM");
    }
    memcpy(ctx->image, image, image_size);
    ctx->image_size = image_size;

    uc_err err_code = uc_open(UC_ARCH_ARM64, UC_MODE_ARM, &ctx->uc);
    if (err_code != UC_ERR_OK) {
        report(err, err_len, "uc_open %s", uc_strerror(err_code));
        goto fail;
    }

    uc_hook hook;
    if (uc_mem_map(ctx->uc, 0, 0x1000, UC_PROT_READ) != UC_ERR_OK ||
        uc_mem_map(ctx->uc, BASE, 0x500000, UC_PROT_ALL) != UC_ERR_OK ||
        uc_mem_map(ctx->uc, HEAP, 0x800000, UC_PROT_ALL) != UC_ERR_OK ||
        uc_mem_map(ctx->uc, STACK, 0x200000, UC_PROT_ALL) != UC_ERR_OK ||
        uc_mem_map(ctx->uc, IMPORT, 0x10000, UC_PROT_ALL) != UC_ERR_OK ||
        uc_mem_map(ctx->uc, STOP, 0x1000, UC_PROT_ALL) != UC_ERR_OK) {
        report(err, err_len, "uc_mem_map failed");
        goto fail;
    }
    ctx->errno_address = alloc_zero(ctx, 4);
    if (ctx->failed) {
        report(err, err_len, "errno cell allocation failed");
        goto fail;
    }

    uc_hook_add(ctx->uc, &hook, UC_HOOK_MEM_READ, hook_env_read, ctx, 0, 0xfff);
    uc_hook_add(ctx->uc, &hook, UC_HOOK_MEM_INVALID, hook_invalid, ctx, 1, 0);
    uc_hook_add(ctx->uc, &hook, UC_HOOK_INTR, hook_interrupt, ctx, 1, 0);

    if (load_image(ctx, err, err_len) != 0) {
        goto fail;
    }

    /* Model the absent Java environment through the SDK's JavaVM error path. */
    uint64_t vm_table = alloc_zero(ctx, 64);
    write_u64(ctx, vm_table + 0x20, JNI_STUB_A);
    write_u64(ctx, vm_table + 0x30, JNI_STUB_B);
    uint8_t zero8[8] = {0};
    uint64_t vm_object = alloc_bytes(ctx, zero8, 8);
    write_u64(ctx, vm_object, vm_table);
    uint64_t vm_global = read_u64(ctx, VM_GLOBAL_SLOT);
    write_u64(ctx, vm_global, vm_object);
    xset(ctx, UC_ARM64_REG_TPIDR_EL0, STACK);

    uc_hook_add(ctx->uc, &hook, UC_HOOK_CODE, hook_import, ctx, IMPORT, IMPORT + 0xffff);
    uc_hook_add(ctx->uc, &hook, UC_HOOK_CODE, hook_digest_boundary, ctx,
                DIGEST_BOUNDARY, DIGEST_BOUNDARY);

    *out = ctx;
    return 0;

fail:
    sdk_digest_close(ctx);
    return -1;
}

int sdk_digest_run(sdk_digest_ctx *ctx, const uint8_t *payload, uint32_t selector,
                   uint64_t seconds, uint8_t out[20], char *err, size_t err_len)
{
    if (ctx == NULL || ctx->uc == NULL) {
        return report(err, err_len, "invalid ctx");
    }
    if (selector > 15) {
        return report(err, err_len, "selector out of range %u", selector);
    }
    if (seconds > 0xffffffffULL) {
        return report(err, err_len, "seconds out of range");
    }
    if (ctx->heap_ptr >= HEAP + 0x700000) {
        /* Leave headroom for the result objects of this run. */
        return report(err, err_len, "digest heap exhausted for ctx");
    }

    /* Run-scoped reset; heap / once-done / import state persists (Python parity). */
    ctx->failed = 0;
    ctx->core_returned = 0;
    ctx->env_reads = 0;

    uint8_t padded[53];
    memcpy(padded, payload, 52);
    padded[52] = 0;
    uint64_t pointer = alloc_bytes(ctx, padded, sizeof(padded));

    uint8_t argument[24];
    uint64_t vtable = ARG_VTABLE;
    uint32_t capacity = 53;
    uint32_t length = 52;
    memcpy(argument + 0, &vtable, 8);
    memcpy(argument + 8, &capacity, 4);
    memcpy(argument + 12, &length, 4);
    memcpy(argument + 16, &pointer, 8);
    uint64_t argument_address = alloc_bytes(ctx, argument, sizeof(argument));

    uint64_t result = alloc_zero(ctx, 24);
    if (ctx->failed) {
        return report(err, err_len, "argument allocation failed");
    }

    xset(ctx, UC_ARM64_REG_SP, STACK + 0x1f0000);
    xset(ctx, UC_ARM64_REG_X0, argument_address);
    xset(ctx, UC_ARM64_REG_X1, selector);
    xset(ctx, UC_ARM64_REG_X2, seconds);
    xset(ctx, UC_ARM64_REG_X8, result);
    xset(ctx, UC_ARM64_REG_LR, STOP);

    uc_err err_code = uc_emu_start(ctx->uc, DIGEST_ENTRY, STOP, 20u * 1000 * 1000,
                                   100000000u);
    if (ctx->failed) {
        return report(err, err_len, "digest run aborted (err=%d)", (int)err_code);
    }
    if (err_code != UC_ERR_OK) {
        return report(err, err_len, "emu error %s", uc_strerror(err_code));
    }
    uint64_t pc = xget(ctx, UC_ARM64_REG_PC);
    if (!ctx->core_returned && pc != STOP) {
        return report(err, err_len, "digest budget reached (pc=0x%llx)",
                      (unsigned long long)pc);
    }

    uint32_t out_capacity = 0;
    uint32_t out_length = 0;
    uc_mem_read(ctx->uc, result + 8, &out_capacity, 4);
    uc_mem_read(ctx->uc, result + 12, &out_length, 4);
    uint64_t out_pointer = read_u64(ctx, result + 16);

    if (out_length != 20 || out_capacity < out_length) {
        return report(err, err_len, "unexpected digest length %u", out_length);
    }
    uc_mem_read(ctx->uc, out_pointer, out, 20);
    return 0;
}

size_t sdk_digest_heap_used(const sdk_digest_ctx *ctx)
{
    if (ctx == NULL || ctx->heap_ptr < HEAP) {
        return 0;
    }
    return (size_t)(ctx->heap_ptr - HEAP);
}

void sdk_digest_close(sdk_digest_ctx *ctx)
{
    if (ctx == NULL) {
        return;
    }
    if (ctx->uc != NULL) {
        uc_close(ctx->uc);
    }
    free(ctx->image);
    free(ctx);
}
