/* libmetasec_ml.so digest smoke, on-device napi build (Unicorn 2.1.3).
 *
 * C port of hongguo-drama's SdkDigestCore (phone_sdk_core_v5.py), adapted
 * for the app: hilog stage logging, anonymous exec-memory probes (W^X check),
 * image loaded from the HAP libs dir (entry/libs/arm64-v8a), result exposed
 * to ArkTS via a one-shot poll buffer.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <hilog/log.h>

#include <unicorn/unicorn.h>
#include <unicorn/arm64.h>

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

/* ---- one-shot state machine: 0 idle, 1 running, 2 done ---- */

#define RESULT_MAX 8192
static char result_buf[RESULT_MAX];
static size_t result_len;
static volatile int smoke_state = 0;

static void result_append(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static void result_append(const char *fmt, ...)
{
    if (result_len + 1 >= RESULT_MAX) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(result_buf + result_len, RESULT_MAX - result_len, fmt, ap);
    va_end(ap);
    result_len = strlen(result_buf);
}

static void slog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static void slog(const char *fmt, ...)
{
    char text[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof(text), fmt, ap);
    va_end(ap);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "UnicornSmoke", "%{public}s", text);
    result_append("%s\n", text);
}

int smoke_state_get(void)
{
    return __atomic_load_n(&smoke_state, __ATOMIC_SEQ_CST);
}

const char *smoke_result_get(void)
{
    return result_buf;
}

/* Returns true when the caller won the 0 -> 1 transition. */
int smoke_state_try_begin(void)
{
    int expected = 0;
    return __atomic_compare_exchange_n(&smoke_state, &expected, 1, false,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

static uc_engine *uc;
static uint64_t heap_ptr = HEAP;
static int failed = 0;
static int core_returned = 0;
static int env_reads = 0;
static uint64_t errno_address;

static void die(const char *message)
{
    slog("die: %s", message);
    failed = 1;
    uc_emu_stop(uc);
}

/* ---- bump allocator with size tracking (heap region) ---- */

#define ALLOC_TABLE_MAX 8192
static struct { uint64_t addr; uint64_t size; } alloc_table[ALLOC_TABLE_MAX];
static int alloc_count;

static void note_alloc(uint64_t addr, uint64_t size)
{
    if (alloc_count < ALLOC_TABLE_MAX) {
        alloc_table[alloc_count].addr = addr;
        alloc_table[alloc_count].size = size;
    }
    alloc_count++;
}

static uint64_t alloc_size_of(uint64_t addr)
{
    for (int i = alloc_count - 1; i >= 0; i--) {
        if (alloc_table[i].addr == addr) {
            return alloc_table[i].size;
        }
    }
    return 0;
}

static uint64_t bump(uint64_t size)
{
    uint64_t addr = heap_ptr;
    heap_ptr += (size + 31) / 16 * 16;
    if (heap_ptr >= HEAP + 0x800000) {
        die("heap exhausted");
        return 0;
    }
    return addr;
}

static uint64_t alloc_zero(uint64_t size)
{
    if (size > 2u * 1024 * 1024) {
        die("alloc over 2MB");
        return 0;
    }
    uint64_t addr = bump(size);
    if (size) {
        uint8_t *zero = calloc(1, size);
        uc_mem_write(uc, addr, zero, size);
        free(zero);
    }
    note_alloc(addr, size);
    return addr;
}

static uint64_t alloc_bytes(const uint8_t *data, uint64_t size)
{
    uint64_t addr = bump(size);
    if (size) {
        uc_mem_write(uc, addr, data, size);
    }
    note_alloc(addr, size);
    return addr;
}

/* ---- tiny register / memory helpers ---- */

static uint64_t xget(int reg)
{
    uint64_t value = 0;
    uc_reg_read(uc, reg, &value);
    return value;
}

static void xset(int reg, uint64_t value)
{
    uc_reg_write(uc, reg, &value);
}

static uint64_t read_u64(uint64_t addr)
{
    uint8_t raw[8];
    uc_mem_read(uc, addr, raw, 8);
    uint64_t value;
    memcpy(&value, raw, 8);
    return value;
}

static void write_u64(uint64_t addr, uint64_t value)
{
    uc_mem_write(uc, addr, &value, 8);
}

static void write_u32(uint64_t addr, uint32_t value)
{
    uc_mem_write(uc, addr, &value, 4);
}

static uint64_t host_time_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- import bookkeeping ---- */

#define IMPORT_TABLE_MAX 512
static struct { uint64_t addr; char name[64]; } import_table[IMPORT_TABLE_MAX];
static int import_count;

static const char *import_name(uint64_t addr)
{
    for (int i = 0; i < import_count; i++) {
        if (import_table[i].addr == addr) {
            return import_table[i].name;
        }
    }
    return NULL;
}

/* ---- pthread modeling ---- */

#define MUTEX_TABLE_MAX 64
static struct { uint64_t addr; int depth; } mutex_table[MUTEX_TABLE_MAX];
static int mutex_count;

static int *mutex_depth(uint64_t addr)
{
    for (int i = 0; i < mutex_count; i++) {
        if (mutex_table[i].addr == addr) {
            return &mutex_table[i].depth;
        }
    }
    if (mutex_count >= MUTEX_TABLE_MAX) {
        die("mutex table full");
        return NULL;
    }
    mutex_table[mutex_count].addr = addr;
    mutex_table[mutex_count].depth = 0;
    return &mutex_table[mutex_count++].depth;
}

#define KEY_TABLE_MAX 16
static struct { uint64_t key; uint64_t value; } key_table[KEY_TABLE_MAX];
static int key_count;

#define ONCE_STACK_MAX 4
static struct { uint64_t control; uint64_t lr; } once_pending[ONCE_STACK_MAX];
static int once_depth;
static uint64_t once_done[32];
static int once_done_count;

static int once_is_done(uint64_t control)
{
    for (int i = 0; i < once_done_count; i++) {
        if (once_done[i] == control) {
            return 1;
        }
    }
    return 0;
}

/* ---- hooks ---- */

static void hook_env_read(uc_engine *u, uc_mem_type type, uint64_t address,
                          int size, int64_t value, void *user)
{
    (void)u; (void)type; (void)address; (void)size; (void)value; (void)user;
    env_reads++;
    if (env_reads > 64) {
        die("empty-environment read budget exceeded");
    }
}

static bool hook_invalid(uc_engine *u, uc_mem_type type, uint64_t address,
                         int size, int64_t value, void *user)
{
    (void)u; (void)user;
    uint64_t pc = xget(UC_ARM64_REG_PC);
    slog("invalid memory access type=%d address=0x%llx size=%d pc=0x%llx (base+0x%llx)",
         (int)type, (unsigned long long)address, size,
         (unsigned long long)pc, (unsigned long long)(pc - BASE));
    failed = 1;
    return false;
}

static void hook_interrupt(uc_engine *u, uint32_t intno, void *user)
{
    (void)u; (void)user;
    uint64_t call = xget(UC_ARM64_REG_X8);
    if (intno != 2) {
        die("unexpected interrupt");
        return;
    }
    if (call == 57) { /* close(fd) -> EBADF */
        xset(UC_ARM64_REG_X0, 0xfffffffffffffff7ULL);
        return;
    }
    if (call != 56) { /* openat */
        die("unsupported SDK syscall");
        return;
    }
    uint64_t pointer = xget(UC_ARM64_REG_X1);
    uint8_t byte;
    for (int i = 0; i < 256; i++) {
        uc_mem_read(uc, pointer + i, &byte, 1);
        if (byte == 0) {
            xset(UC_ARM64_REG_X0, 0xfffffffffffffffeULL); /* ENOENT */
            return;
        }
    }
    die("unbounded SDK path");
}

static void hook_digest_boundary(uc_engine *u, uint64_t address, uint32_t size,
                                 void *user)
{
    (void)address; (void)size; (void)user;
    uint64_t slot = xget(UC_ARM64_REG_X28);
    uint64_t instruction = read_u64(slot);
    if (instruction == DIGEST_CORE) {
        core_returned = 1;
        uc_emu_stop(u);
    }
}

/* Emulated libc imports; mirrors phone_sdk_core_v5.py hook(). */
static void hook_import(uc_engine *u, uint64_t address, uint32_t size, void *user)
{
    (void)size; (void)user;
    uint64_t a = xget(UC_ARM64_REG_X0);
    uint64_t b = xget(UC_ARM64_REG_X1);
    uint64_t c = xget(UC_ARM64_REG_X2);
    uint64_t d = xget(UC_ARM64_REG_X3);
    uint64_t value;

    if (address == JNI_STUB_A || address == JNI_STUB_B) {
        uint64_t zero = 0;
        uc_mem_write(u, b, &zero, 8);
        xset(UC_ARM64_REG_X0, 0xffffffff); /* JNI_ERR */
        xset(UC_ARM64_REG_PC, xget(UC_ARM64_REG_LR));
        return;
    }
    if (address == ONCE_RETURN) {
        if (once_depth <= 0) {
            die("pthread_once return without pending init");
            return;
        }
        once_depth--;
        uint64_t control = once_pending[once_depth].control;
        uint64_t previous_lr = once_pending[once_depth].lr;
        if (once_done_count < 32) {
            once_done[once_done_count++] = control;
        }
        write_u32(control, 2);
        xset(UC_ARM64_REG_X0, 0);
        xset(UC_ARM64_REG_LR, previous_lr);
        xset(UC_ARM64_REG_PC, previous_lr);
        return;
    }

    const char *name = import_name(address);
    if (name == NULL) {
        return; /* not a modeled import; execute the stub bytes */
    }

    if (strcmp(name, "malloc") == 0 || strcmp(name, "calloc") == 0) {
        value = alloc_zero(name[0] == 'm' ? a : a * b);
    } else if (strcmp(name, "free") == 0) {
        value = 0;
    } else if (strcmp(name, "realloc") == 0) {
        value = alloc_zero(b);
        if (a && value) {
            uint64_t old = alloc_size_of(a);
            uint64_t n = b < old ? b : old;
            if (n) {
                uint8_t *scratch = malloc(n);
                uc_mem_read(u, a, scratch, n);
                uc_mem_write(u, value, scratch, n);
                free(scratch);
            }
        }
    } else if (strcmp(name, "memcpy") == 0 || strcmp(name, "memmove") == 0 ||
               strcmp(name, "__memcpy_chk") == 0 || strcmp(name, "__memmove_chk") == 0) {
        if (name[0] == '_' && c > d) {
            die("checked copy over destination bound");
            return;
        }
        if (c > 8u * 1024 * 1024) {
            die("copy over scratch cap");
            return;
        }
        uint8_t *scratch = malloc(c ? c : 1);
        if (c) {
            uc_mem_read(u, b, scratch, c);
            uc_mem_write(u, a, scratch, c);
        }
        free(scratch);
        value = a;
    } else if (strcmp(name, "memset") == 0 || strcmp(name, "__memset_chk") == 0) {
        if (c > 2u * 1024 * 1024) {
            die("memset over 2MB");
            return;
        }
        if (name[0] == '_' && c > d) {
            die("checked set over destination bound");
            return;
        }
        uint8_t *scratch = malloc(c ? c : 1);
        memset(scratch, (int)(b & 255), c);
        if (c) {
            uc_mem_write(u, a, scratch, c);
        }
        free(scratch);
        value = a;
    } else if (strcmp(name, "memcmp") == 0) {
        uint8_t *left = malloc(c ? c : 1);
        uint8_t *right = malloc(c ? c : 1);
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
                die("strlen over 64KB");
                return;
            }
        }
    } else if (strcmp(name, "pthread_mutex_lock") == 0 ||
               strcmp(name, "pthread_mutex_unlock") == 0) {
        uint8_t raw[4];
        uc_mem_read(u, a, raw, 4);
        int *depth = mutex_depth(a);
        if (depth == NULL) {
            return;
        }
        if (name[strlen(name) - 6] == 'n') { /* unlock */
            if (*depth <= 0) {
                die("mutex unlock without lock");
                return;
            }
            (*depth)--;
        } else {
            (*depth)++;
        }
        value = 0;
    } else if (strcmp(name, "pthread_cond_broadcast") == 0) {
        uint8_t raw[4];
        uc_mem_read(u, a, raw, 4);
        value = 0;
    } else if (strcmp(name, "pthread_once") == 0) {
        uint8_t raw[4];
        uc_mem_read(u, a, raw, 4);
        if (!once_is_done(a)) {
            if (b < BASE || b >= BASE + 0x500000) {
                die("pthread_once routine outside image");
                return;
            }
            for (int i = 0; i < once_depth; i++) {
                if (once_pending[i].control == a) {
                    die("pthread_once re-entered for same control");
                    return;
                }
            }
            if (once_depth >= ONCE_STACK_MAX) {
                die("pthread_once nesting too deep");
                return;
            }
            once_pending[once_depth].control = a;
            once_pending[once_depth].lr = xget(UC_ARM64_REG_LR);
            once_depth++;
            xset(UC_ARM64_REG_LR, ONCE_RETURN);
            xset(UC_ARM64_REG_PC, b);
            return;
        }
        value = 0;
    } else if (strcmp(name, "pthread_key_create") == 0) {
        if (key_count >= KEY_TABLE_MAX) {
            die("thread key table full");
            return;
        }
        key_table[key_count].key = (uint64_t)key_count + 1;
        key_table[key_count].value = 0;
        write_u32(a, (uint32_t)(key_count + 1));
        key_count++;
        value = 0;
    } else if (strcmp(name, "pthread_setspecific") == 0) {
        int found = 0;
        for (int i = 0; i < key_count; i++) {
            if (key_table[i].key == a) {
                key_table[i].value = b;
                found = 1;
            }
        }
        if (!found) {
            die("pthread_setspecific for unknown key");
            return;
        }
        value = 0;
    } else if (strcmp(name, "pthread_getspecific") == 0) {
        value = 0;
        for (int i = 0; i < key_count; i++) {
            if (key_table[i].key == a) {
                value = key_table[i].value;
            }
        }
    } else if (strcmp(name, "gettid") == 0 || strcmp(name, "getpid") == 0) {
        value = 1;
    } else if (strcmp(name, "syscall") == 0) {
        if (a != 172 && a != 178) {
            die("unsupported libc syscall number");
            return;
        }
        value = 1;
    } else if (strcmp(name, "clock_gettime") == 0) {
        if (a != 0 && a != 1) {
            die("unsupported clock id");
            return;
        }
        int64_t seconds = a == 0 ? 1700000000 : 1;
        uc_mem_write(u, b, &(int64_t){seconds}, 8);
        uc_mem_write(u, b + 8, &(int64_t){0}, 8);
        value = 0;
    } else if (strcmp(name, "__system_property_find") == 0 ||
               strcmp(name, "getenv") == 0) {
        value = 0;
    } else if (strcmp(name, "__errno") == 0) {
        value = errno_address;
    } else if (strcmp(name, "__cxa_thread_atexit_impl") == 0) {
        value = 0;
    } else {
        slog("import unavailable in smoke: %s", name);
        die("unhandled import");
        return;
    }
    xset(UC_ARM64_REG_X0, value);
    xset(UC_ARM64_REG_PC, xget(UC_ARM64_REG_LR));
}

/* ---- ELF loading (PT_LOAD map + dynamic relocations) ---- */

static const uint8_t *image;
static size_t image_size;

static uint16_t elf_u16(size_t offset)
{
    uint16_t value;
    memcpy(&value, image + offset, 2);
    return value;
}

static uint32_t elf_u32(size_t offset)
{
    uint32_t value;
    memcpy(&value, image + offset, 4);
    return value;
}

static uint64_t elf_u64(size_t offset)
{
    uint64_t value;
    memcpy(&value, image + offset, 8);
    return value;
}

static const char *elf_string(const uint8_t *table, size_t start)
{
    return (const char *)(table + start);
}

static void load_image(void)
{
    /* Program headers: map PT_LOAD segments at BASE. */
    uint64_t phoff = elf_u64(32);
    uint16_t phentsize = elf_u16(54);
    uint16_t phnum = elf_u16(56);
    for (uint16_t index = 0; index < phnum; index++) {
        size_t entry = (size_t)phoff + index * phentsize;
        uint32_t kind = elf_u32(entry);
        uint64_t offset = elf_u64(entry + 8);
        uint64_t address = elf_u64(entry + 16);
        uint64_t filesz = elf_u64(entry + 32);
        if (kind == 1) {
            uc_mem_write(uc, BASE + address, image + offset, filesz);
        }
    }

    /* Section headers: locate .dynsym / .rela.dyn / .rela.plt. */
    uint64_t shoff = elf_u64(40);
    uint16_t shentsize = elf_u16(58);
    uint16_t shnum = elf_u16(60);
    uint16_t shstrndx = elf_u16(62);

    size_t dynsym = 0, dynstr = 0, rela_dyn = 0, rela_plt = 0;
    const uint8_t *shstrtab = image + elf_u64((size_t)shoff + shstrndx * shentsize + 24);

    for (uint16_t i = 0; i < shnum; i++) {
        size_t entry = (size_t)shoff + i * shentsize;
        const char *name = elf_string(shstrtab, elf_u32(entry));
        if (strcmp(name, ".dynsym") == 0) {
            dynsym = entry;
        } else if (strcmp(name, ".rela.dyn") == 0) {
            rela_dyn = entry;
        } else if (strcmp(name, ".rela.plt") == 0) {
            rela_plt = entry;
        }
    }
    if (!dynsym || !rela_dyn || !rela_plt) {
        die("required ELF sections missing");
        return;
    }

    size_t dynsym_offset = elf_u64(dynsym + 24);
    uint32_t dynsym_link = elf_u32(dynsym + 40);
    size_t dynsym_entsize = elf_u64(dynsym + 56);
    dynstr = (size_t)shoff + dynsym_link * shentsize;
    const uint8_t *strtab = image + elf_u64(dynstr + 24);

    for (int which = 0; which < 2; which++) {
        size_t section = which == 0 ? rela_dyn : rela_plt;
        size_t offset = elf_u64(section + 24);
        size_t size = elf_u64(section + 32);
        for (size_t pos = offset; pos < offset + size; pos += 24) {
            uint64_t r_offset = elf_u64(pos);
            uint64_t r_info = elf_u64(pos + 8);
            int64_t r_addend = (int64_t)elf_u64(pos + 16);
            uint32_t symbol = (uint32_t)(r_info >> 32);
            uint32_t kind = (uint32_t)(r_info & 0xffffffffu);
            uint64_t value;
            if (kind == 1027) { /* R_AARCH64_RELATIVE */
                value = BASE + (uint64_t)r_addend;
            } else if (kind == 1025 || kind == 1026 || kind == 257) {
                size_t sym_entry = dynsym_offset + symbol * dynsym_entsize;
                uint32_t st_name = elf_u32(sym_entry);
                uint16_t st_shndx = elf_u16(sym_entry + 6);
                uint64_t st_value = elf_u64(sym_entry + 8);
                if (st_shndx) {
                    value = BASE + st_value + (uint64_t)r_addend;
                } else {
                    value = IMPORT + (uint64_t)symbol * 128;
                    if (import_count < IMPORT_TABLE_MAX) {
                        import_table[import_count].addr = value;
                        snprintf(import_table[import_count].name, 64, "%s",
                                 elf_string(strtab, st_name));
                        import_count++;
                    } else {
                        die("import table full");
                        return;
                    }
                }
            } else {
                slog("unsupported relocation %u", kind);
                die("unsupported relocation");
                return;
            }
            write_u64(BASE + r_offset, value);
        }
    }
}

/* ---- exec-memory probes (W^X check) ---- */

static void probe_exec_mem(void)
{
    const size_t size = 4096;

    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != MAP_FAILED) {
        slog("probe mmap RWX: ALLOWED");
        munmap(p, size);
    } else {
        slog("probe mmap RWX: DENIED errno=%d", errno);
    }

    void *q = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (q == MAP_FAILED) {
        slog("probe mmap RW: DENIED errno=%d", errno);
        return;
    }
    if (mprotect(q, size, PROT_READ | PROT_EXEC) == 0) {
        slog("probe RW->mprotect RX: ALLOWED");
    } else {
        slog("probe RW->mprotect RX: DENIED errno=%d", errno);
    }
    munmap(q, size);
}

/* ---- digest ---- */

static void run_digest(void)
{
    /* 52-byte payload: 32 pattern bytes + 16 pattern bytes + u32 seconds. */
    uint8_t payload[52];
    for (int i = 0; i < 32; i++) {
        payload[i] = (uint8_t)(0xa0 + i);
    }
    for (int i = 0; i < 16; i++) {
        payload[32 + i] = (uint8_t)(0x50 + i);
    }
    uint32_t seconds = 1795000000u;
    memcpy(payload + 48, &seconds, 4);

    uint64_t pointer = alloc_bytes(payload, sizeof(payload) + 1);

    uint8_t argument[24];
    uint64_t vtable = ARG_VTABLE;
    uint32_t capacity = sizeof(payload) + 1;
    uint32_t length = sizeof(payload);
    memcpy(argument + 0, &vtable, 8);
    memcpy(argument + 8, &capacity, 4);
    memcpy(argument + 12, &length, 4);
    memcpy(argument + 16, &pointer, 8);
    uint64_t argument_address = alloc_bytes(argument, sizeof(argument));

    uint64_t result = alloc_zero(24);

    core_returned = 0;
    xset(UC_ARM64_REG_SP, STACK + 0x1f0000);
    xset(UC_ARM64_REG_X0, argument_address);
    xset(UC_ARM64_REG_X1, 3); /* selector, 0..15 */
    xset(UC_ARM64_REG_X2, seconds);
    xset(UC_ARM64_REG_X8, result);
    xset(UC_ARM64_REG_LR, STOP);

    slog("emu_start begin");
    uint64_t started = host_time_ms();
    uc_err err = uc_emu_start(uc, DIGEST_ENTRY, STOP, 20u * 1000 * 1000, 100000000u);
    uint64_t elapsed = host_time_ms() - started;
    slog("emu_start end elapsed=%llums err=%d", (unsigned long long)elapsed, (int)err);

    uint64_t pc = xget(UC_ARM64_REG_PC);
    if (failed) {
        return;
    }
    if (err != UC_ERR_OK) {
        slog("emu error %s (pc=0x%llx, %llu ms)", uc_strerror(err),
             (unsigned long long)pc, (unsigned long long)elapsed);
        failed = 1;
        return;
    }
    if (!core_returned && pc != STOP) {
        slog("digest budget reached (pc=0x%llx, %llu ms)",
             (unsigned long long)pc, (unsigned long long)elapsed);
        failed = 1;
        return;
    }

    uint32_t out_capacity = 0;
    uint32_t out_length = 0;
    uc_mem_read(uc, result + 8, &out_capacity, 4);
    uc_mem_read(uc, result + 12, &out_length, 4);
    uint64_t out_pointer = read_u64(result + 16);

    slog("core_returned=%d pc=0x%llx elapsed_ms=%llu env_reads=%d allocs=%d imports=%d",
         core_returned, (unsigned long long)pc, (unsigned long long)elapsed,
         env_reads, alloc_count, import_count);
    slog("result: capacity=%u length=%u", out_capacity, out_length);

    if (out_length != 20 || out_capacity < out_length) {
        slog("unexpected digest length %u", out_length);
        failed = 1;
        return;
    }
    uint8_t digest[20];
    uc_mem_read(uc, out_pointer, digest, 20);
    char hex[41];
    for (int i = 0; i < 20; i++) {
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    }
    slog("digest: %s", hex);
    slog("SMOKE OK");
}

/* ---- entry ---- */

static int open_image(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file) {
        return -1;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return -1;
    }
    long size = ftell(file);
    if (size < 1024 || size > 64 * 1024 * 1024) {
        fclose(file);
        return -1;
    }
    rewind(file);
    uint8_t *data = malloc((size_t)size);
    if (!data) {
        fclose(file);
        return -1;
    }
    if (fread(data, 1, (size_t)size, file) != (size_t)size) {
        free(data);
        fclose(file);
        return -1;
    }
    fclose(file);
    image = data;
    image_size = (size_t)size;
    return 0;
}

void smoke_start(const char *path)
{
    slog("smoke_run: %s", path);
    probe_exec_mem();

    if (open_image(path) != 0) {
        /* Alternate layout: libs/arm64-v8a <-> libs/arm64. */
        char alt[1024];
        const char *needle = strstr(path, "/libs/arm64/");
        if (needle) {
            snprintf(alt, sizeof(alt), "%.*s/libs/arm64-v8a/%s",
                     (int)(needle - path), path, needle + strlen("/libs/arm64/"));
        } else {
            needle = strstr(path, "/libs/arm64-v8a/");
            if (!needle) {
                slog("FAIL: cannot open %s (errno=%d)", path, errno);
                goto out;
            }
            snprintf(alt, sizeof(alt), "%.*s/libs/arm64/%s",
                     (int)(needle - path), path, needle + strlen("/libs/arm64-v8a/"));
        }
        if (open_image(alt) != 0) {
            slog("FAIL: cannot open %s nor fallback (errno=%d)", path, errno);
            goto out;
        }
    }
    slog("image %zu bytes", image_size);

    if (elf_u64(0) != 0x00010102464c457fULL) {
        slog("FAIL: not an ELF64 LSB shared object");
        goto out_free;
    }

    uc_err err = uc_open(UC_ARCH_ARM64, UC_MODE_ARM, &uc);
    if (err != UC_ERR_OK) {
        slog("FAIL: uc_open %s", uc_strerror(err));
        goto out_free;
    }
    slog("uc_open ok");

    uc_hook hook;
    slog("map1 begin (0..0x1000)");
    uc_mem_map(uc, 0, 0x1000, UC_PROT_READ);
    slog("map2 begin (BASE)");
    uc_mem_map(uc, BASE, 0x500000, UC_PROT_ALL);
    slog("map3 begin (HEAP)");
    uc_mem_map(uc, HEAP, 0x800000, UC_PROT_ALL);
    slog("map4 begin (STACK)");
    uc_mem_map(uc, STACK, 0x200000, UC_PROT_ALL);
    slog("map5 begin (IMPORT)");
    uc_mem_map(uc, IMPORT, 0x10000, UC_PROT_ALL);
    slog("map6 begin (STOP)");
    uc_mem_map(uc, STOP, 0x1000, UC_PROT_ALL);
    errno_address = alloc_zero(4);

    uc_hook_add(uc, &hook, UC_HOOK_MEM_READ, hook_env_read, NULL, 0, 0xfff);
    uc_hook_add(uc, &hook, UC_HOOK_MEM_INVALID, hook_invalid, NULL, 1, 0);
    uc_hook_add(uc, &hook, UC_HOOK_INTR, hook_interrupt, NULL, 1, 0);

    load_image();
    if (failed) {
        slog("FAIL: image load failed");
        goto out_free;
    }
    slog("load_image ok");

    /* Model the absent Java environment through the SDK's JavaVM error path. */
    uint64_t vm_table = alloc_zero(64);
    write_u64(vm_table + 0x20, JNI_STUB_A);
    write_u64(vm_table + 0x30, JNI_STUB_B);
    uint64_t vm_object = alloc_bytes((uint8_t[8]){0}, 8);
    write_u64(vm_object, vm_table);
    uint64_t vm_global = read_u64(VM_GLOBAL_SLOT);
    write_u64(vm_global, vm_object);
    xset(UC_ARM64_REG_TPIDR_EL0, STACK);

    uc_hook_add(uc, &hook, UC_HOOK_CODE, hook_import, NULL, IMPORT, IMPORT + 0xffff);
    uc_hook_add(uc, &hook, UC_HOOK_CODE, hook_digest_boundary, NULL,
                DIGEST_BOUNDARY, DIGEST_BOUNDARY);

    run_digest();

out_free:
    if (uc) {
        uc_close(uc);
        uc = NULL;
    }
    free((void *)image);
    image = NULL;
out:
    if (failed) {
        slog("SMOKE FAIL");
    }
    __atomic_store_n(&smoke_state, 2, __ATOMIC_SEQ_CST);
}
