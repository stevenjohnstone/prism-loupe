#ifdef PRISM_WASM_SANITIZE

#include "wasm_san_rt.h"
#include "trace_runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * WebAssembly ASAN + UBSAN Runtime for Ruby Prism Loupe
 *
 * Linked with:
 *   -Wl,--no-stack-first -Wl,--global-base=33554432
 *
 * Linear memory layout:
 *   [0x00000000 .. 0x02000000)  32 MB 8:1 ASAN shadow table (covers 0 .. 256 MB)
 *   [0x02000000 .. __data_end)  Static globals (with compiler-emitted redzones)
 *   [__data_end .. __heap_base) 8 MB Wasm value stack (with ASAN frame redzones)
 *   [__heap_base .. mem_end)    dlmalloc heap (wrapped with 32B L/R redzones + quarantine)
 */

#define WASM_SAN_SHADOW_SIZE      0x02000000U /* 32 MB shadow */
#define WASM_SAN_LOW_SHADOW_SIZE  0x00400000U /* 4 MB shadow of [0 .. 32 MB) */
#define WASM_SAN_MAX_COVERED_ADDR 0x10000000U /* 256 MB covered address space */

#define SHADOW_STACK_LEFT   ((uint8_t) 0xf1U)
#define SHADOW_STACK_MID    ((uint8_t) 0xf2U)
#define SHADOW_STACK_RIGHT  ((uint8_t) 0xf3U)
#define SHADOW_LOW_ADDR     ((uint8_t) 0xf4U)
#define SHADOW_STACK_UAR    ((uint8_t) 0xf5U)
#define SHADOW_INPUT_LEFT   ((uint8_t) 0xf6U)
#define SHADOW_INPUT_RIGHT  ((uint8_t) 0xf7U)
#define SHADOW_STACK_SCOPE  ((uint8_t) 0xf8U)
#define SHADOW_GLOBAL_RZ    ((uint8_t) 0xf9U)
#define SHADOW_HEAP_LEFT    ((uint8_t) 0xfaU)
#define SHADOW_HEAP_RIGHT   ((uint8_t) 0xfbU)
#define SHADOW_HEAP_FREED   ((uint8_t) 0xfdU)

#define SAN_HDR_MAGIC_LIVE  0x53414e41U
#define SAN_HDR_MAGIC_FREED 0xdeadf4eeU

#define SAN_LEFT_RZ_BYTES   32U
#define SAN_RIGHT_RZ_BYTES  32U

#define SAN_QUARANTINE_CAP  4096U
#define SAN_QUARANTINE_MAX_BYTES (16U * 1024U * 1024U)
#define SAN_MAX_GLOBALS     2048U

typedef struct {
    void *raw_ptr;
    uintptr_t aligned_base;
    size_t aligned_span;
    size_t user_size;
    size_t tracked;
    uint32_t magic;
} san_heap_hdr_t;

typedef char san_hdr_size_check[(sizeof(san_heap_hdr_t) <= SAN_LEFT_RZ_BYTES) ? 1 : -1];

typedef struct {
    void *raw_ptr;
    uintptr_t aligned_base;
    size_t aligned_span;
} san_quarantine_entry_t;

typedef struct {
    uintptr_t beg;
    uintptr_t size;
    uintptr_t size_with_redzone;
    const char *name;
    const char *module_name;
    uintptr_t has_dynamic_init;
    uintptr_t location;
    uintptr_t odr_indicator;
} asan_global_t;

typedef struct {
    const char *filename;
    uint32_t line;
    uint32_t column;
} ubsan_source_location_t;

typedef struct {
    uint16_t type_kind;
    uint16_t type_info;
    char type_name[1];
} ubsan_type_descriptor_t;

typedef struct {
    ubsan_source_location_t loc;
    const ubsan_type_descriptor_t *type;
    uint8_t log_alignment;
    uint8_t type_check_kind;
} ubsan_type_mismatch_data_v1_t;

static int g_san_initialized = 0;
static int g_san_reporting = 0;

static uintptr_t g_input_user_addr = 0;
static size_t g_input_user_size = 0;
static void *g_input_raw_ptr = NULL;
static uintptr_t g_input_aligned_base = 0;
static size_t g_input_aligned_span = 0;

static san_quarantine_entry_t g_quarantine[SAN_QUARANTINE_CAP];
static size_t g_quarantine_head = 0;
static size_t g_quarantine_count = 0;
static size_t g_quarantine_bytes = 0;

static asan_global_t g_registered_globals[SAN_MAX_GLOBALS];
static size_t g_registered_globals_count = 0;
static const asan_global_t *g_seen_global_tables[64];
static size_t g_seen_global_tables_count = 0;

int __asan_option_detect_stack_use_after_return = 0;

void __asan_init(void);

void *__real_memchr(const void *s, int c, size_t n);
int __real_memcmp(const void *s1, const void *s2, size_t n);
size_t __real_strlen(const char *s);
int __real_strncmp(const char *s1, const char *s2, size_t n);

static inline size_t
align_up_8(size_t n) {
    return (n + 7U) & ~(size_t) 7U;
}

static inline void
shadow_fill_aligned(uintptr_t aligned_addr, size_t aligned_len, uint8_t code) {
    if (aligned_len == 0 || aligned_addr >= WASM_SAN_MAX_COVERED_ADDR) return;
    if (aligned_len > WASM_SAN_MAX_COVERED_ADDR - aligned_addr) {
        aligned_len = WASM_SAN_MAX_COVERED_ADDR - aligned_addr;
    }
    __builtin_memset((void *) (aligned_addr >> 3), code, aligned_len >> 3);
}

static inline void
shadow_unpoison_with_right_rz(uintptr_t aligned_start, size_t exact_size, size_t total_aligned_span, uint8_t right_rz_code) {
    if (aligned_start >= WASM_SAN_MAX_COVERED_ADDR || total_aligned_span == 0) return;
    if (total_aligned_span > WASM_SAN_MAX_COVERED_ADDR - aligned_start) {
        total_aligned_span = WASM_SAN_MAX_COVERED_ADDR - aligned_start;
    }
    uint8_t *sh = (uint8_t *) (aligned_start >> 3);
    __builtin_memset(sh, right_rz_code, total_aligned_span >> 3);
    if (exact_size > 0) {
        size_t full = exact_size >> 3;
        size_t rem = exact_size & 7U;
        if (full > 0) {
            __builtin_memset(sh, 0x00, full);
        }
        if (rem != 0) {
            sh[full] = (uint8_t) rem;
        }
    }
}

static uint8_t
classify_shadow_code(uintptr_t addr) {
    if (addr >= WASM_SAN_MAX_COVERED_ADDR) return 0;
    uintptr_t sh_idx = addr >> 3;
    int8_t sv = *((const int8_t *) sh_idx);
    if (sv < 0) return (uint8_t) sv;
    if (sv > 0 && sh_idx + 1 < WASM_SAN_SHADOW_SIZE) {
        int8_t next_sv = *((const int8_t *) (sh_idx + 1));
        if (next_sv < 0) return (uint8_t) next_sv;
    }
    return SHADOW_HEAP_RIGHT;
}

static inline int
is_byte_poisoned(uintptr_t addr) {
    if (addr >= WASM_SAN_MAX_COVERED_ADDR) return 0;
    int8_t sv = *((const int8_t *) (addr >> 3));
    if (sv == 0) return 0;
    if (sv > 0 && (int8_t) (addr & 7U) < sv) return 0;
    return 1;
}

static const char *
find_global_for_addr(uintptr_t addr, ptrdiff_t *out_delta, size_t *out_size) {
    for (size_t i = 0; i < g_registered_globals_count; i++) {
        const asan_global_t *g = &g_registered_globals[i];
        if (addr >= g->beg && addr < g->beg + g->size_with_redzone) {
            if (out_delta != NULL) *out_delta = (ptrdiff_t) (addr - (g->beg + g->size));
            if (out_size != NULL) *out_size = (size_t) g->size;
            return g->name ? g->name : "<global>";
        }
    }
    return NULL;
}

static const char *
active_trace_func(void) {
    if (g_trace_last_func != NULL && g_trace_last_func[0] != '\0') {
        return g_trace_last_func;
    }
    if (g_trace_call_depth > 0 && g_trace_call_stack[g_trace_call_depth - 1] != NULL) {
        return g_trace_call_stack[g_trace_call_depth - 1];
    }
    return "pm_parse";
}

_Noreturn static void
wasm_san_report_asan(uintptr_t addr, size_t access_size, int is_write) {
    if (g_san_reporting) {
        __builtin_trap();
    }
    g_san_reporting = 1;

    uint8_t code = classify_shadow_code(addr);
    const char *bug_kind = "invalid-memory-access";
    char detail[320];
    const char *op = is_write ? "WRITE" : "READ";

    if (addr < 65536U) {
        bug_kind = "null-dereference";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) at NULL/low address 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_LOW_ADDR) {
        bug_kind = "wild-address";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) at wild/shadow address 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_INPUT_LEFT || code == SHADOW_INPUT_RIGHT ||
               (g_input_aligned_base != 0 && addr >= g_input_aligned_base && addr < g_input_aligned_base + g_input_aligned_span)) {
        bug_kind = "input-buffer-overflow";
        if (addr < g_input_user_addr) {
            size_t before = (size_t) (g_input_user_addr - addr);
            snprintf(
                detail,
                sizeof(detail),
                "%s of %zu byte(s) at 0x%08" PRIxPTR " (%zu byte(s) before start of %zu-byte source buffer)",
                op, access_size, addr, before, g_input_user_size
            );
        } else {
            size_t past = (size_t) (addr - (g_input_user_addr + g_input_user_size));
            snprintf(
                detail,
                sizeof(detail),
                "%s of %zu byte(s) at 0x%08" PRIxPTR " (%zu byte(s) past end of %zu-byte source buffer)",
                op, access_size, addr, past, g_input_user_size
            );
        }
    } else if (code == SHADOW_HEAP_FREED) {
        bug_kind = "heap-use-after-free";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) inside freed heap block at 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_HEAP_LEFT) {
        bug_kind = "heap-buffer-underflow";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) to the left of heap allocation at 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_HEAP_RIGHT) {
        bug_kind = "heap-buffer-overflow";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) past end of heap allocation at 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_STACK_LEFT || code == SHADOW_STACK_MID || code == SHADOW_STACK_RIGHT) {
        bug_kind = "stack-buffer-overflow";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) in stack frame redzone at 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_STACK_SCOPE || code == SHADOW_STACK_UAR) {
        bug_kind = "stack-use-after-scope";
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) of out-of-scope stack variable at 0x%08" PRIxPTR, op, access_size, addr);
    } else if (code == SHADOW_GLOBAL_RZ) {
        bug_kind = "global-buffer-overflow";
        ptrdiff_t g_delta = 0;
        size_t g_sz = 0;
        const char *g_name = find_global_for_addr(addr, &g_delta, &g_sz);
        if (g_name != NULL) {
            snprintf(
                detail,
                sizeof(detail),
                "%s of %zu byte(s) at 0x%08" PRIxPTR " (%td byte(s) past %zu-byte global '%s')",
                op, access_size, addr, g_delta, g_sz, g_name
            );
        } else {
            snprintf(detail, sizeof(detail), "%s of %zu byte(s) in global variable redzone at 0x%08" PRIxPTR, op, access_size, addr);
        }
    } else {
        snprintf(detail, sizeof(detail), "%s of %zu byte(s) at poisoned address 0x%08" PRIxPTR " (shadow=0x%02x)", op, access_size, addr, (unsigned) code);
    }

    char reason_buf[96];
    snprintf(reason_buf, sizeof(reason_buf), "ASAN: %s", bug_kind);
    prism_trace_emit_crash(
        reason_buf,
        detail,
        g_trace_last_file ? g_trace_last_file : "src/prism.c",
        g_trace_last_line,
        active_trace_func()
    );
    __builtin_trap();
}

static inline void
check_memory_range(const void *ptr, size_t n, int is_write) {
    if (g_san_reporting || n == 0) return;
    if (ptr == NULL) {
        wasm_san_report_asan(0, n, is_write);
    }
    uintptr_t a = (uintptr_t) ptr;
    uintptr_t end = a + n;
    if (end < a) {
        wasm_san_report_asan(a, n, is_write);
    }
    while (a < end && (a & 7U) != 0) {
        if (is_byte_poisoned(a)) wasm_san_report_asan(a, n, is_write);
        a++;
    }
    while (end - a >= 8U) {
        if (a < WASM_SAN_MAX_COVERED_ADDR && *((const int8_t *) (a >> 3)) != 0) {
            for (uintptr_t k = 0; k < 8U; k++) {
                if (is_byte_poisoned(a + k)) wasm_san_report_asan(a + k, n, is_write);
            }
        }
        a += 8U;
    }
    while (a < end) {
        if (is_byte_poisoned(a)) wasm_san_report_asan(a, n, is_write);
        a++;
    }
}

static void
quarantine_evict_one(void) {
    if (g_quarantine_count == 0) return;
    size_t tail = (g_quarantine_head + SAN_QUARANTINE_CAP - g_quarantine_count) % SAN_QUARANTINE_CAP;
    san_quarantine_entry_t ev = g_quarantine[tail];
    g_quarantine_count--;
    if (g_quarantine_bytes >= ev.aligned_span) {
        g_quarantine_bytes -= ev.aligned_span;
    } else {
        g_quarantine_bytes = 0;
    }
    shadow_fill_aligned(ev.aligned_base, ev.aligned_span, 0x00);
    free(ev.raw_ptr);
}

static void
quarantine_flush_all(void) {
    while (g_quarantine_count > 0) {
        quarantine_evict_one();
    }
    g_quarantine_head = 0;
    g_quarantine_bytes = 0;
}

void
wasm_san_begin_run(void) {
    __asan_init();
    g_san_reporting = 0;
    quarantine_flush_all();
}

void
wasm_san_finish_run(void) {
    quarantine_flush_all();
}

uint8_t *
wasm_san_alloc_input(const uint8_t *src, size_t size) {
    size_t body_aligned = align_up_8(size);
    size_t aligned_span = SAN_LEFT_RZ_BYTES + body_aligned + SAN_RIGHT_RZ_BYTES;
    void *raw = malloc(aligned_span + 8U);
    if (raw == NULL) return NULL;

    uintptr_t base = ((uintptr_t) raw + 7U) & ~(uintptr_t) 7U;
    uintptr_t user_addr = base + SAN_LEFT_RZ_BYTES;

    shadow_fill_aligned(base, SAN_LEFT_RZ_BYTES, SHADOW_INPUT_LEFT);
    shadow_unpoison_with_right_rz(user_addr, size, body_aligned + SAN_RIGHT_RZ_BYTES, SHADOW_INPUT_RIGHT);

    if (size > 0 && src != NULL) {
        __builtin_memcpy((void *) user_addr, src, size);
    }

    g_input_raw_ptr = raw;
    g_input_aligned_base = base;
    g_input_aligned_span = aligned_span;
    g_input_user_addr = user_addr;
    g_input_user_size = size;
    return (uint8_t *) user_addr;
}

void
wasm_san_free_input(uint8_t *buf) {
    if (buf == NULL || g_input_raw_ptr == NULL) return;
    shadow_fill_aligned(g_input_aligned_base, g_input_aligned_span, 0x00);
    free(g_input_raw_ptr);
    g_input_raw_ptr = NULL;
    g_input_aligned_base = 0;
    g_input_aligned_span = 0;
    g_input_user_addr = 0;
    g_input_user_size = 0;
}

void *
wasm_san_heap_alloc(size_t size, size_t tracked) {
    size_t body_aligned = align_up_8(size > 0 ? size : 8U);
    size_t aligned_span = SAN_LEFT_RZ_BYTES + body_aligned + SAN_RIGHT_RZ_BYTES;
    if (aligned_span < size) return NULL;

    void *raw = malloc(aligned_span + 8U);
    if (raw == NULL) return NULL;

    uintptr_t base = ((uintptr_t) raw + 7U) & ~(uintptr_t) 7U;
    uintptr_t user_addr = base + SAN_LEFT_RZ_BYTES;
    san_heap_hdr_t *hdr = ((san_heap_hdr_t *) user_addr) - 1;

    hdr->raw_ptr = raw;
    hdr->aligned_base = base;
    hdr->aligned_span = aligned_span;
    hdr->user_size = size;
    hdr->tracked = tracked;
    hdr->magic = SAN_HDR_MAGIC_LIVE;

    shadow_fill_aligned(base, SAN_LEFT_RZ_BYTES, SHADOW_HEAP_LEFT);
    shadow_unpoison_with_right_rz(user_addr, size, body_aligned + SAN_RIGHT_RZ_BYTES, SHADOW_HEAP_RIGHT);
    return (void *) user_addr;
}

int
wasm_san_heap_query(const void *user_ptr, size_t *out_size, size_t *out_tracked) {
    if (user_ptr == NULL) return 0;
    const san_heap_hdr_t *hdr = ((const san_heap_hdr_t *) user_ptr) - 1;
    if (hdr->magic != SAN_HDR_MAGIC_LIVE) return 0;
    if (out_size != NULL) *out_size = hdr->user_size;
    if (out_tracked != NULL) *out_tracked = hdr->tracked;
    return 1;
}

void
wasm_san_heap_free(void *user_ptr, size_t *out_size, size_t *out_tracked, int has_expected_size, size_t expected_size) {
    if (user_ptr == NULL) return;
    san_heap_hdr_t *hdr = ((san_heap_hdr_t *) user_ptr) - 1;

    if (hdr->magic == SAN_HDR_MAGIC_FREED) {
        if (!g_san_reporting) {
            g_san_reporting = 1;
            char msg[160];
            snprintf(msg, sizeof(msg), "attempting double-free on pointer 0x%08" PRIxPTR, (uintptr_t) user_ptr);
            prism_trace_emit_crash(
                "ASAN: double-free",
                msg,
                g_trace_last_file ? g_trace_last_file : "src/prism.c",
                g_trace_last_line,
                active_trace_func()
            );
        }
        __builtin_trap();
    }

    if (hdr->magic != SAN_HDR_MAGIC_LIVE) {
        if (!g_san_reporting) {
            g_san_reporting = 1;
            char msg[160];
            snprintf(msg, sizeof(msg), "attempting free on non-heap or corrupted pointer 0x%08" PRIxPTR, (uintptr_t) user_ptr);
            prism_trace_emit_crash(
                "ASAN: bad-free",
                msg,
                g_trace_last_file ? g_trace_last_file : "src/prism.c",
                g_trace_last_line,
                active_trace_func()
            );
        }
        __builtin_trap();
    }

    if (has_expected_size && expected_size != hdr->user_size) {
        if (!g_san_reporting) {
            g_san_reporting = 1;
            char msg[200];
            snprintf(
                msg,
                sizeof(msg),
                "sized-free mismatch on 0x%08" PRIxPTR ": allocated %zu byte(s), freed with size %zu",
                (uintptr_t) user_ptr,
                hdr->user_size,
                expected_size
            );
            prism_trace_emit_crash(
                "ASAN: sized-free-mismatch",
                msg,
                g_trace_last_file ? g_trace_last_file : "src/prism.c",
                g_trace_last_line,
                active_trace_func()
            );
        }
        __builtin_trap();
    }

    size_t sz = hdr->user_size;
    size_t tr = hdr->tracked;
    void *raw_ptr = hdr->raw_ptr;
    uintptr_t base = hdr->aligned_base;
    size_t span = hdr->aligned_span;
    size_t body_aligned = align_up_8(sz > 0 ? sz : 8U);

    if (out_size != NULL) *out_size = sz;
    if (out_tracked != NULL) *out_tracked = tr;

    hdr->magic = SAN_HDR_MAGIC_FREED;
    shadow_fill_aligned((uintptr_t) user_ptr, body_aligned, SHADOW_HEAP_FREED);

    while (g_quarantine_count >= SAN_QUARANTINE_CAP ||
           (g_quarantine_count > 0 && g_quarantine_bytes + span > SAN_QUARANTINE_MAX_BYTES)) {
        quarantine_evict_one();
    }

    g_quarantine[g_quarantine_head].raw_ptr = raw_ptr;
    g_quarantine[g_quarantine_head].aligned_base = base;
    g_quarantine[g_quarantine_head].aligned_span = span;
    g_quarantine_head = (g_quarantine_head + 1U) % SAN_QUARANTINE_CAP;
    g_quarantine_count++;
    g_quarantine_bytes += span;
}

/* --- Compiler-emitted ASAN ABI entrypoints --- */

void
__asan_init(void) {
    if (g_san_initialized) return;
    g_san_initialized = 1;
    /* Poison [0 .. 32 MB) so NULL dereferences and stray writes into shadow memory trap */
    volatile uintptr_t shadow_zero = 0;
    uint8_t *low_shadow = (uint8_t *) shadow_zero;
    for (size_t i = 0; i < WASM_SAN_LOW_SHADOW_SIZE; i++) {
        low_shadow[i] = SHADOW_LOW_ADDR;
    }
}

void
__asan_version_mismatch_check_v8(void) {}

void
__asan_handle_no_return(void) {}

void
__asan_register_globals(asan_global_t *globals, uintptr_t n) {
    __asan_init();
    if (globals == NULL || n == 0) return;
    for (size_t t = 0; t < g_seen_global_tables_count; t++) {
        if (g_seen_global_tables[t] == globals) return;
    }
    if (g_seen_global_tables_count < 64) {
        g_seen_global_tables[g_seen_global_tables_count++] = globals;
    }
    for (uintptr_t i = 0; i < n; i++) {
        const asan_global_t *g = &globals[i];
        if (g->beg >= WASM_SAN_SHADOW_SIZE && g->size_with_redzone >= g->size) {
            shadow_unpoison_with_right_rz(g->beg, g->size, g->size_with_redzone, SHADOW_GLOBAL_RZ);
            if (g_registered_globals_count < SAN_MAX_GLOBALS) {
                g_registered_globals[g_registered_globals_count++] = *g;
            }
        }
    }
}

void
__asan_unregister_globals(asan_global_t *globals, uintptr_t n) {
    (void) globals;
    (void) n;
}

#define DEFINE_SET_SHADOW(hex, val) \
    void __asan_set_shadow_##hex(uintptr_t shadow_addr, uintptr_t shadow_size) { \
        if (shadow_size > 0 && shadow_addr < WASM_SAN_SHADOW_SIZE) { \
            uintptr_t max_len = WASM_SAN_SHADOW_SIZE - shadow_addr; \
            if (shadow_size > max_len) shadow_size = max_len; \
            __builtin_memset((void *) shadow_addr, (val), shadow_size); \
        } \
    }

DEFINE_SET_SHADOW(00, 0x00)
DEFINE_SET_SHADOW(f1, 0xf1)
DEFINE_SET_SHADOW(f2, 0xf2)
DEFINE_SET_SHADOW(f3, 0xf3)
DEFINE_SET_SHADOW(f5, 0xf5)
DEFINE_SET_SHADOW(f8, 0xf8)

#define DEFINE_ASAN_REPORT(name, sz, is_w) \
    _Noreturn void __asan_report_##name(uintptr_t addr) { \
        wasm_san_report_asan(addr, (sz), (is_w)); \
    }

DEFINE_ASAN_REPORT(load1,   1,  0)
DEFINE_ASAN_REPORT(load2,   2,  0)
DEFINE_ASAN_REPORT(load4,   4,  0)
DEFINE_ASAN_REPORT(load8,   8,  0)
DEFINE_ASAN_REPORT(load16,  16, 0)
DEFINE_ASAN_REPORT(store1,  1,  1)
DEFINE_ASAN_REPORT(store2,  2,  1)
DEFINE_ASAN_REPORT(store4,  4,  1)
DEFINE_ASAN_REPORT(store8,  8,  1)
DEFINE_ASAN_REPORT(store16, 16, 1)

_Noreturn void
__asan_report_load_n(uintptr_t addr, uintptr_t size) {
    wasm_san_report_asan(addr, (size_t) size, 0);
}

_Noreturn void
__asan_report_store_n(uintptr_t addr, uintptr_t size) {
    wasm_san_report_asan(addr, (size_t) size, 1);
}

void *
__asan_memcpy(void *dst, const void *src, size_t n) {
    if (n > 0) {
        check_memory_range(src, n, 0);
        check_memory_range(dst, n, 1);
        __builtin_memcpy(dst, src, n);
    }
    return dst;
}

void *
__asan_memmove(void *dst, const void *src, size_t n) {
    if (n > 0) {
        check_memory_range(src, n, 0);
        check_memory_range(dst, n, 1);
        __builtin_memmove(dst, src, n);
    }
    return dst;
}

void *
__asan_memset(void *dst, int c, size_t n) {
    if (n > 0) {
        check_memory_range(dst, n, 1);
        __builtin_memset(dst, c, n);
    }
    return dst;
}

/* --- Linker --wrap interceptors for libc memory/string scans --- */

void *
__wrap_memchr(const void *s, int c, size_t n) {
    if (n == 0) return NULL;
    if (s == NULL) wasm_san_report_asan(0, 1, 0);
    const unsigned char *p = (const unsigned char *) s;
    unsigned char target = (unsigned char) c;
    for (size_t i = 0; i < n; i++) {
        if (!g_san_reporting && is_byte_poisoned((uintptr_t) (p + i))) {
            wasm_san_report_asan((uintptr_t) (p + i), 1, 0);
        }
        if (p[i] == target) {
            return (void *) (p + i);
        }
    }
    return NULL;
}

int
__wrap_memcmp(const void *s1, const void *s2, size_t n) {
    if (n == 0) return 0;
    check_memory_range(s1, n, 0);
    check_memory_range(s2, n, 0);
    return __real_memcmp(s1, s2, n);
}

size_t
__wrap_strlen(const char *s) {
    if (s == NULL) wasm_san_report_asan(0, 1, 0);
    size_t i = 0;
    for (;;) {
        if (!g_san_reporting && is_byte_poisoned((uintptr_t) (s + i))) {
            wasm_san_report_asan((uintptr_t) (s + i), 1, 0);
        }
        if (s[i] == '\0') return i;
        i++;
    }
}

int
__wrap_strncmp(const char *s1, const char *s2, size_t n) {
    if (n == 0) return 0;
    if (s1 == NULL || s2 == NULL) wasm_san_report_asan(0, 1, 0);
    for (size_t i = 0; i < n; i++) {
        if (!g_san_reporting) {
            if (is_byte_poisoned((uintptr_t) (s1 + i))) wasm_san_report_asan((uintptr_t) (s1 + i), 1, 0);
            if (is_byte_poisoned((uintptr_t) (s2 + i))) wasm_san_report_asan((uintptr_t) (s2 + i), 1, 0);
        }
        unsigned char c1 = (unsigned char) s1[i];
        unsigned char c2 = (unsigned char) s2[i];
        if (c1 != c2 || c1 == '\0') {
            return (int) c1 - (int) c2;
        }
    }
    return 0;
}

/* --- Compiler-emitted UBSAN ABI entrypoints --- */

_Noreturn static void
wasm_san_report_ubsan(const ubsan_source_location_t *loc, const char *kind, const char *detail) {
    if (g_san_reporting) {
        __builtin_trap();
    }
    g_san_reporting = 1;

    char reason_buf[96];
    char expr_buf[256];
    snprintf(reason_buf, sizeof(reason_buf), "UBSAN: %s", kind);

    const char *file = (loc != NULL && loc->filename != NULL) ? loc->filename : (g_trace_last_file ? g_trace_last_file : "src/prism.c");
    int line = (loc != NULL && loc->line > 0) ? (int) loc->line : g_trace_last_line;
    uint32_t col = (loc != NULL) ? loc->column : 0;

    if (col > 0) {
        snprintf(expr_buf, sizeof(expr_buf), "%s (col %u)", detail, (unsigned) col);
    } else {
        snprintf(expr_buf, sizeof(expr_buf), "%s", detail);
    }

    prism_trace_emit_crash(reason_buf, expr_buf, file, line, active_trace_func());
    __builtin_trap();
}

#define DEFINE_UBSAN_2(name, kind, desc) \
    _Noreturn void __ubsan_handle_##name##_abort(const void *data, uintptr_t lhs, uintptr_t rhs) { \
        (void) lhs; (void) rhs; \
        wasm_san_report_ubsan((const ubsan_source_location_t *) data, (kind), (desc)); \
    } \
    void __ubsan_handle_##name(const void *data, uintptr_t lhs, uintptr_t rhs) { \
        __ubsan_handle_##name##_abort(data, lhs, rhs); \
    }

#define DEFINE_UBSAN_1(name, kind, desc) \
    _Noreturn void __ubsan_handle_##name##_abort(const void *data, uintptr_t val) { \
        (void) val; \
        wasm_san_report_ubsan((const ubsan_source_location_t *) data, (kind), (desc)); \
    } \
    void __ubsan_handle_##name(const void *data, uintptr_t val) { \
        __ubsan_handle_##name##_abort(data, val); \
    }

#define DEFINE_UBSAN_0(name, kind, desc) \
    _Noreturn void __ubsan_handle_##name##_abort(const void *data) { \
        wasm_san_report_ubsan((const ubsan_source_location_t *) data, (kind), (desc)); \
    } \
    void __ubsan_handle_##name(const void *data) { \
        __ubsan_handle_##name##_abort(data); \
    }

DEFINE_UBSAN_2(add_overflow,          "signed-integer-overflow", "signed integer addition overflow")
DEFINE_UBSAN_2(sub_overflow,          "signed-integer-overflow", "signed integer subtraction overflow")
DEFINE_UBSAN_2(mul_overflow,          "signed-integer-overflow", "signed integer multiplication overflow")
DEFINE_UBSAN_2(divrem_overflow,       "integer-divide-overflow", "division by zero or INT_MIN / -1 overflow")
DEFINE_UBSAN_1(negate_overflow,       "signed-integer-overflow", "signed integer negation overflow")
DEFINE_UBSAN_2(pointer_overflow,      "pointer-overflow",        "pointer arithmetic overflow or nullptr offset")
DEFINE_UBSAN_2(shift_out_of_bounds,   "shift-out-of-bounds",     "shift exponent is negative, too large, or overflows")
DEFINE_UBSAN_1(out_of_bounds,         "array-bounds",            "array index out of bounds")
DEFINE_UBSAN_1(load_invalid_value,    "invalid-bool-or-enum",    "load of invalid value for bool or enum type")
DEFINE_UBSAN_1(vla_bound_not_positive,"vla-bound",               "variable-length array bound is not positive")
DEFINE_UBSAN_1(float_cast_overflow,   "float-cast-overflow",     "floating-point to integer conversion overflow")
DEFINE_UBSAN_0(nonnull_arg,           "nonnull-argument",        "null pointer passed to nonnull parameter")
DEFINE_UBSAN_0(invalid_builtin,       "invalid-builtin",         "invalid argument to compiler builtin (ctz/clz)")

_Noreturn void
__ubsan_handle_type_mismatch_v1_abort(const void *raw_data, uintptr_t ptr) {
    const ubsan_type_mismatch_data_v1_t *d = (const ubsan_type_mismatch_data_v1_t *) raw_data;
    const char *tname = (d != NULL && d->type != NULL) ? d->type->type_name : "<type>";
    uint32_t align = (d != NULL && d->log_alignment < 31) ? (1U << d->log_alignment) : 1U;
    char detail[200];

    if (ptr == 0) {
        snprintf(detail, sizeof(detail), "null pointer access of type %s", tname);
        wasm_san_report_ubsan(d ? &d->loc : NULL, "null-pointer-use", detail);
    } else if (align > 1U && (ptr & (align - 1U)) != 0) {
        snprintf(detail, sizeof(detail), "misaligned address 0x%08" PRIxPTR " for type %s (requires %u-byte alignment)", ptr, tname, (unsigned) align);
        wasm_san_report_ubsan(d ? &d->loc : NULL, "misaligned-pointer", detail);
    } else {
        snprintf(detail, sizeof(detail), "type mismatch / insufficient space at 0x%08" PRIxPTR " for type %s", ptr, tname);
        wasm_san_report_ubsan(d ? &d->loc : NULL, "type-mismatch", detail);
    }
}

void
__ubsan_handle_type_mismatch_v1(const void *raw_data, uintptr_t ptr) {
    __ubsan_handle_type_mismatch_v1_abort(raw_data, ptr);
}

_Noreturn void
__ubsan_handle_builtin_unreachable(const void *data) {
    wasm_san_report_ubsan((const ubsan_source_location_t *) data, "unreachable", "execution reached __builtin_unreachable()");
}

_Noreturn void
__ubsan_handle_missing_return(const void *data) {
    wasm_san_report_ubsan((const ubsan_source_location_t *) data, "missing-return", "execution reached end of value-returning function");
}

_Noreturn void
__ubsan_handle_alignment_assumption_abort(const void *data, uintptr_t ptr, uintptr_t align, uintptr_t offset) {
    (void) ptr; (void) align; (void) offset;
    wasm_san_report_ubsan((const ubsan_source_location_t *) data, "alignment-assumption", "violated pointer alignment assumption");
}

void
__ubsan_handle_alignment_assumption(const void *data, uintptr_t ptr, uintptr_t align, uintptr_t offset) {
    __ubsan_handle_alignment_assumption_abort(data, ptr, align, offset);
}

_Noreturn void
__ubsan_handle_nonnull_return_v1_abort(const void *data, const void *loc_ptr) {
    (void) data;
    wasm_san_report_ubsan((const ubsan_source_location_t *) loc_ptr, "nonnull-return", "null pointer returned from returns_nonnull function");
}

void
__ubsan_handle_nonnull_return_v1(const void *data, const void *loc_ptr) {
    __ubsan_handle_nonnull_return_v1_abort(data, loc_ptr);
}

_Noreturn void
__ubsan_handle_function_type_mismatch_abort(const void *data, uintptr_t fn) {
    (void) fn;
    wasm_san_report_ubsan((const ubsan_source_location_t *) data, "function-type-mismatch", "indirect call through mismatched function pointer type");
}

void
__ubsan_handle_function_type_mismatch(const void *data, uintptr_t fn) {
    __ubsan_handle_function_type_mismatch_abort(data, fn);
}

#endif /* PRISM_WASM_SANITIZE */
