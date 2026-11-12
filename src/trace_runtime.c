#include "trace_runtime.h"
#include "wasm_san_rt.h"
#include "prism.h"
#undef NDEBUG
#include <assert.h>
#include <limits.h>

pm_parser_t *g_trace_parser = NULL;
pm_buffer_t *g_trace_buf = NULL;
static pm_buffer_t *g_trace_crash_out_buf = NULL;
uint64_t g_trace_step = 0;
uint64_t g_trace_max_steps = 50000;
const pm_node_t *g_trace_nodes[PRISM_TRACE_MAX_NODES];
uint32_t g_trace_node_count = 0;
const char *g_trace_call_stack[PRISM_TRACE_MAX_CALL_STACK];
int g_trace_call_depth = 0;
int g_trace_in_hook = 0;
int g_trace_crashed = 0;
const char *g_trace_last_func = NULL;
const char *g_trace_last_file = NULL;
int g_trace_last_line = 0;
static uint64_t g_last_ast_hash = 0;
static uint64_t g_last_diags_hash = 0;
static uint64_t g_last_comments_hash = 0;
static const pm_list_node_t *g_last_emitted_error_tail = NULL;
static const pm_list_node_t *g_last_emitted_warning_tail = NULL;
static uint32_t g_trace_parse_pass = 0;
static uint64_t g_trace_input_size = 0;
static prism_trace_crash_cb_t g_trace_crash_cb = NULL;

static int g_trace_xalloc_tracking = 0;
static size_t g_trace_xalloc_raw_live_bytes = 0;
static size_t g_trace_xalloc_live_bytes = 0;
static size_t g_trace_xalloc_peak_bytes = 0;
static size_t g_trace_xalloc_total_bytes = 0;
static size_t g_trace_xalloc_alloc_count = 0;
static size_t g_trace_xalloc_free_count = 0;
static size_t g_trace_xalloc_live_blocks = 0;
static size_t g_trace_event_start_len = 0;

typedef struct {
    size_t size;
    size_t tracked;
} prism_trace_alloc_hdr_t;

static void *
alloc_with_tracking(size_t s, size_t tracked) {
    if (s > ((size_t)-1) - g_trace_xalloc_raw_live_bytes) {
        g_trace_xalloc_raw_live_bytes = (size_t)-1;
    } else {
        g_trace_xalloc_raw_live_bytes += s;
    }
    if (tracked) {
        if (s > ((size_t)-1) - g_trace_xalloc_live_bytes) {
            g_trace_xalloc_live_bytes = (size_t)-1;
        } else {
            g_trace_xalloc_live_bytes += s;
        }
        if (s > ((size_t)-1) - g_trace_xalloc_total_bytes) {
            g_trace_xalloc_total_bytes = (size_t)-1;
        } else {
            g_trace_xalloc_total_bytes += s;
        }
        g_trace_xalloc_alloc_count++;
        g_trace_xalloc_live_blocks++;
        if (g_trace_xalloc_live_bytes > g_trace_xalloc_peak_bytes) {
            g_trace_xalloc_peak_bytes = g_trace_xalloc_live_bytes;
        }
        if (!g_trace_crashed) {
            assert(g_trace_xalloc_live_bytes <= PRISM_TRACE_MAX_XALLOC_BYTES);
        }
    }
#ifdef PRISM_WASM_SANITIZE
    return wasm_san_heap_alloc(s, tracked);
#else
    prism_trace_alloc_hdr_t *hdr = (prism_trace_alloc_hdr_t *) malloc(sizeof(prism_trace_alloc_hdr_t) + (s > 0 ? s : 1));
    if (hdr == NULL) return NULL;
    hdr->size = s;
    hdr->tracked = tracked;
    return (void *)(hdr + 1);
#endif
}

static int
query_alloc_metadata(const void *ptr, size_t *out_size, size_t *out_tracked) {
    if (ptr == NULL) return 0;
#ifdef PRISM_WASM_SANITIZE
    return wasm_san_heap_query(ptr, out_size, out_tracked);
#else
    const prism_trace_alloc_hdr_t *hdr = ((const prism_trace_alloc_hdr_t *) ptr) - 1;
    if (out_size != NULL) *out_size = hdr->size;
    if (out_tracked != NULL) *out_tracked = hdr->tracked;
    return 1;
#endif
}

__attribute__((noinline)) void *
prism_trace_xmalloc(size_t s) {
    size_t tracked = (g_trace_xalloc_tracking && !g_trace_in_hook && !g_trace_crashed) ? 1 : 0;
    return alloc_with_tracking(s, tracked);
}

static void
prism_trace_xfree_impl(void *ptr, int has_expected_size, size_t expected_size) {
    if (ptr == NULL) return;
    if (g_trace_parser != NULL) {
        for (uint32_t i = 1; i <= g_trace_node_count; i++) {
            if (g_trace_nodes[i] == (const pm_node_t *) ptr) {
                g_trace_nodes[i] = NULL;
                break;
            }
        }
    }
    size_t alloc_size = 0;
    size_t alloc_tracked = 0;
#ifdef PRISM_WASM_SANITIZE
    wasm_san_heap_free(ptr, &alloc_size, &alloc_tracked, has_expected_size, expected_size);
#else
    (void) has_expected_size;
    (void) expected_size;
    prism_trace_alloc_hdr_t *hdr = ((prism_trace_alloc_hdr_t *) ptr) - 1;
    alloc_size = hdr->size;
    alloc_tracked = hdr->tracked;
    free(hdr);
#endif
    if (g_trace_xalloc_raw_live_bytes >= alloc_size) {
        g_trace_xalloc_raw_live_bytes -= alloc_size;
    } else {
        g_trace_xalloc_raw_live_bytes = 0;
    }
    if (alloc_tracked) {
        if (g_trace_xalloc_live_bytes >= alloc_size) {
            g_trace_xalloc_live_bytes -= alloc_size;
        } else {
            g_trace_xalloc_live_bytes = 0;
        }
        if (g_trace_xalloc_live_blocks > 0) {
            g_trace_xalloc_live_blocks--;
        }
        g_trace_xalloc_free_count++;
    }
}

__attribute__((noinline)) void
prism_trace_xfree(void *ptr) {
    prism_trace_xfree_impl(ptr, 0, 0);
}

__attribute__((noinline)) void
prism_trace_xfree_sized(void *ptr, size_t old_size) {
    prism_trace_xfree_impl(ptr, 1, old_size);
}

__attribute__((noinline)) void *
prism_trace_xcalloc(size_t n, size_t s) {
    size_t total = n * s;
    if (n != 0 && total / n != s) {
        total = (size_t)-1;
    }
    void *ptr = prism_trace_xmalloc(total);
    if (ptr != NULL && total > 0) {
        memset(ptr, 0, total);
    }
    return ptr;
}

static void *
prism_trace_xrealloc_impl(void *ptr, size_t s, int has_old_size, size_t expected_old_size) {
    if (ptr == NULL) {
#ifdef PRISM_WASM_SANITIZE
        if (has_old_size && expected_old_size != 0) {
            char msg[160];
            snprintf(msg, sizeof(msg), "xrealloc_sized(NULL, new=%zu, old=%zu) called with non-zero old_size", s, expected_old_size);
            prism_trace_emit_crash(
                "ASAN: sized-realloc-mismatch",
                msg,
                g_trace_last_file ? g_trace_last_file : "src/prism.c",
                g_trace_last_line,
                g_trace_last_func ? g_trace_last_func : "pm_parse"
            );
            __builtin_trap();
        }
#endif
        return prism_trace_xmalloc(s);
    }
    if (s == 0) {
        prism_trace_xfree_impl(ptr, has_old_size, expected_old_size);
        return NULL;
    }
    size_t old_size = 0;
    size_t old_tracked = 0;
    if (!query_alloc_metadata(ptr, &old_size, &old_tracked)) {
#ifdef PRISM_WASM_SANITIZE
        char msg[160];
        snprintf(msg, sizeof(msg), "attempting realloc on invalid or freed pointer 0x%08" PRIxPTR, (uintptr_t) ptr);
        prism_trace_emit_crash(
            "ASAN: bad-realloc",
            msg,
            g_trace_last_file ? g_trace_last_file : "src/prism.c",
            g_trace_last_line,
            g_trace_last_func ? g_trace_last_func : "pm_parse"
        );
        __builtin_trap();
#endif
    }
#ifdef PRISM_WASM_SANITIZE
    if (has_old_size && expected_old_size != old_size) {
        char msg[200];
        snprintf(
            msg,
            sizeof(msg),
            "sized-realloc mismatch on 0x%08" PRIxPTR ": allocated %zu byte(s), realloced with old_size %zu",
            (uintptr_t) ptr,
            old_size,
            expected_old_size
        );
        prism_trace_emit_crash(
            "ASAN: sized-realloc-mismatch",
            msg,
            g_trace_last_file ? g_trace_last_file : "src/prism.c",
            g_trace_last_line,
            g_trace_last_func ? g_trace_last_func : "pm_parse"
        );
        __builtin_trap();
    }
#endif
    size_t tracked = (old_tracked && !g_trace_in_hook && !g_trace_crashed) ? 1 : 0;
    void *new_ptr = alloc_with_tracking(s, tracked);
    if (new_ptr == NULL) return NULL;
    size_t copy_size = old_size < s ? old_size : s;
    if (copy_size > 0) {
        memcpy(new_ptr, ptr, copy_size);
    }
    prism_trace_xfree_impl(ptr, has_old_size, expected_old_size);
    return new_ptr;
}

__attribute__((noinline)) void *
prism_trace_xrealloc(void *ptr, size_t s) {
    return prism_trace_xrealloc_impl(ptr, s, 0, 0);
}

__attribute__((noinline)) void *
prism_trace_xrealloc_sized(void *ptr, size_t new_size, size_t old_size) {
    return prism_trace_xrealloc_impl(ptr, new_size, 1, old_size);
}

#if !PRISM_TRACE_HAS_BUFFER_NEW
#define pm_buffer_cleanup(buf_) pm_buffer_free(buf_)

PRISM_EXPORTED_FUNCTION pm_buffer_t *
pm_buffer_new(void) {
    pm_buffer_t *buf = (pm_buffer_t *) calloc(1, sizeof(pm_buffer_t));
    if (buf != NULL) {
        pm_buffer_init(buf);
    }
    return buf;
}
#endif

typedef struct {
    uint32_t start;
    uint32_t len;
    uint32_t end;
    int underflow;
    int oob;
} trace_loc_info_t;

static inline uint32_t
loc_start_offset(const pm_parser_t *parser, const pm_location_t *loc) {
#if PRISM_TRACE_LOCATION_IS_OFFSET
    (void) parser;
    return loc->start;
#else
    if (parser == NULL || parser->start == NULL || loc->start == NULL) return 0;
    return (uint32_t)((uintptr_t)loc->start - (uintptr_t)parser->start);
#endif
}

static inline uint32_t
loc_length_bytes(const pm_location_t *loc) {
#if PRISM_TRACE_LOCATION_IS_OFFSET
    return loc->length;
#else
    if (loc->start == NULL || loc->end == NULL) return 0;
    return (uint32_t)((uintptr_t)loc->end - (uintptr_t)loc->start);
#endif
}

static inline trace_loc_info_t
eval_loc_bounds(const pm_parser_t *parser, const pm_location_t *loc, uint64_t src_len) {
    trace_loc_info_t info = { 0, 0, 0, 0, 0 };
    if (loc == NULL) return info;
#if PRISM_TRACE_LOCATION_IS_OFFSET
    (void) parser;
    info.start = loc->start;
    info.len = loc->length;
    info.end = info.start + info.len;
    info.underflow = (
        info.end < info.start ||
        info.len >= 0x80000000U ||
        (src_len < 0x80000000ULL && info.start >= 0x80000000U)
    ) ? 1 : 0;
    info.oob = (
        !info.underflow &&
        ((uint64_t)info.start > src_len || (uint64_t)info.len > src_len - (uint64_t)info.start)
    ) ? 1 : 0;
#else
    uintptr_t p_base = (parser != NULL && parser->start != NULL) ? (uintptr_t)parser->start : 0;
    uintptr_t p_end = (parser != NULL && parser->end != NULL) ? (uintptr_t)parser->end : p_base;
    if (loc->start == NULL && loc->end == NULL) {
        return info;
    }
    if (loc->start == NULL || loc->end == NULL || p_base == 0) {
        info.underflow = 1;
        return info;
    }
    uintptr_t s = (uintptr_t)loc->start;
    uintptr_t e = (uintptr_t)loc->end;
    info.start = (uint32_t)(s - p_base);
    info.len = (uint32_t)(e - s);
    info.end = info.start + info.len;
    info.underflow = (
        s < p_base ||
        e < s ||
        info.len >= 0x80000000U ||
        info.end < info.start ||
        (src_len < 0x80000000ULL && info.start >= 0x80000000U)
    ) ? 1 : 0;
    info.oob = (!info.underflow && (s > p_end || e > p_end)) ? 1 : 0;
#endif
    return info;
}

#if !PRISM_TRACE_MAGIC_COMMENT_HAS_LOC
static inline trace_loc_info_t
eval_ptr_len_bounds(const pm_parser_t *parser, const uint8_t *ptr, uint32_t length, uint64_t src_len) {
    trace_loc_info_t info = { 0, length, length, 0, 0 };
    uintptr_t p_base = (parser != NULL && parser->start != NULL) ? (uintptr_t)parser->start : 0;
    if (ptr == NULL) {
        info.underflow = (length >= 0x80000000U) ? 1 : 0;
        info.oob = (!info.underflow && length > 0) ? 1 : 0;
        return info;
    }
    if (p_base == 0) {
        info.underflow = 1;
        return info;
    }
    uintptr_t s = (uintptr_t)ptr;
    info.start = (uint32_t)(s - p_base);
    info.end = info.start + length;
    info.underflow = (
        s < p_base ||
        length >= 0x80000000U ||
        info.end < info.start ||
        (src_len < 0x80000000ULL && info.start >= 0x80000000U)
    ) ? 1 : 0;
    info.oob = (
        !info.underflow &&
        ((uint64_t)info.start > src_len || (uint64_t)length > src_len - (uint64_t)info.start)
    ) ? 1 : 0;
    return info;
}
#endif

void
prism_trace_set_crash_cb(prism_trace_crash_cb_t cb) {
    g_trace_crash_cb = cb;
}

void
prism_trace_reset(pm_buffer_t *buf, uint64_t max_steps) {
    size_t init_buf_sz = 0;
    if (buf != NULL && buf->value != NULL) {
        query_alloc_metadata(buf->value, &init_buf_sz, NULL);
    }
    g_trace_parser = NULL;
    g_trace_buf = buf;
    g_trace_crash_out_buf = buf;
    g_trace_step = 0;
    g_trace_max_steps = max_steps;
    memset(g_trace_nodes, 0, sizeof(g_trace_nodes));
    g_trace_node_count = 0;
    g_trace_call_depth = 0;
    g_trace_in_hook = 0;
    g_trace_crashed = 0;
    g_trace_last_func = NULL;
    g_trace_last_file = NULL;
    g_trace_last_line = 0;
    g_last_ast_hash = 0;
    g_last_diags_hash = 0;
    g_last_comments_hash = 0;
    g_last_emitted_error_tail = NULL;
    g_last_emitted_warning_tail = NULL;
    g_trace_parse_pass = 0;
    g_trace_input_size = 0;
    g_trace_xalloc_tracking = 0;
    g_trace_xalloc_raw_live_bytes = init_buf_sz;
    g_trace_xalloc_live_bytes = 0;
    g_trace_xalloc_peak_bytes = 0;
    g_trace_xalloc_total_bytes = 0;
    g_trace_xalloc_alloc_count = 0;
    g_trace_xalloc_free_count = 0;
    g_trace_xalloc_live_blocks = 0;
    g_trace_event_start_len = 0;
}

static void
json_escape_to_cstr(char *dst, size_t dst_cap, const char *src, size_t max_src_bytes) {
    if (dst_cap == 0) return;
    size_t pos = 0;
    if (pos + 1 < dst_cap) dst[pos++] = '"';
    if (src != NULL) {
        for (size_t i = 0; src[i] != '\0' && i < max_src_bytes; i++) {
            if (pos + 8 >= dst_cap) break;
            uint8_t c = (uint8_t)src[i];
            switch (c) {
                case '"':  dst[pos++] = '\\'; dst[pos++] = '"'; break;
                case '\\': dst[pos++] = '\\'; dst[pos++] = '\\'; break;
                case '\b': dst[pos++] = '\\'; dst[pos++] = 'b'; break;
                case '\f': dst[pos++] = '\\'; dst[pos++] = 'f'; break;
                case '\n': dst[pos++] = '\\'; dst[pos++] = 'n'; break;
                case '\r': dst[pos++] = '\\'; dst[pos++] = 'r'; break;
                case '\t': dst[pos++] = '\\'; dst[pos++] = 't'; break;
                default:
                    if (c < 0x20 || c >= 0x7f) {
                        pos += (size_t)snprintf(dst + pos, dst_cap - pos, "\\u%04x", (unsigned)c);
                    } else {
                        dst[pos++] = (char)c;
                    }
                    break;
            }
        }
    }
    if (pos + 1 < dst_cap) dst[pos++] = '"';
    dst[pos] = '\0';
}

static void
buf_append_json_escaped(pm_buffer_t *buf, const uint8_t *str, size_t len) {
    pm_buffer_append_byte(buf, '"');
    for (size_t i = 0; i < len; i++) {
        uint8_t c = str[i];
        switch (c) {
            case '"':  PM_BUFFER_APPEND_LITERAL(buf, "\\\""); break;
            case '\\': PM_BUFFER_APPEND_LITERAL(buf, "\\\\"); break;
            case '\b': PM_BUFFER_APPEND_LITERAL(buf, "\\b"); break;
            case '\f': PM_BUFFER_APPEND_LITERAL(buf, "\\f"); break;
            case '\n': PM_BUFFER_APPEND_LITERAL(buf, "\\n"); break;
            case '\r': PM_BUFFER_APPEND_LITERAL(buf, "\\r"); break;
            case '\t': PM_BUFFER_APPEND_LITERAL(buf, "\\t"); break;
            default:
                if (c < 0x20 || c >= 0x7f) {
                    pm_buffer_append_format(buf, "\\u%04x", (unsigned)c);
                } else {
                    pm_buffer_append_byte(buf, c);
                }
                break;
        }
    }
    pm_buffer_append_byte(buf, '"');
}

static void
buf_append_cstr_json_escaped(pm_buffer_t *buf, const char *str) {
    if (str == NULL) {
        PM_BUFFER_APPEND_LITERAL(buf, "\"\"");
        return;
    }
    buf_append_json_escaped(buf, (const uint8_t *) str, strlen(str));
}

static void
format_lex_state(pm_lex_state_t state, char *buf, size_t buf_size) {
    if (state == PM_LEX_STATE_NONE) {
        snprintf(buf, buf_size, "NONE");
        return;
    }
    buf[0] = '\0';
    size_t used = 0;
#define ADD_STATE(flag, label) \
    if (state & (flag)) { \
        used += (size_t)snprintf(buf + used, buf_size - used, "%s%s", used ? "|" : "", (label)); \
    }
    ADD_STATE(PM_LEX_STATE_BEG, "BEG")
    ADD_STATE(PM_LEX_STATE_END, "END")
    ADD_STATE(PM_LEX_STATE_ENDARG, "ENDARG")
    ADD_STATE(PM_LEX_STATE_ENDFN, "ENDFN")
    ADD_STATE(PM_LEX_STATE_ARG, "ARG")
    ADD_STATE(PM_LEX_STATE_CMDARG, "CMDARG")
    ADD_STATE(PM_LEX_STATE_MID, "MID")
    ADD_STATE(PM_LEX_STATE_FNAME, "FNAME")
    ADD_STATE(PM_LEX_STATE_DOT, "DOT")
    ADD_STATE(PM_LEX_STATE_CLASS, "CLASS")
    ADD_STATE(PM_LEX_STATE_LABEL, "LABEL")
    ADD_STATE(PM_LEX_STATE_LABELED, "LABELED")
    ADD_STATE(PM_LEX_STATE_FITEM, "FITEM")
#undef ADD_STATE
}

typedef struct {
    uint32_t ids[256];
    size_t count;
} direct_children_t;

#if PRISM_TRACE_VISIT_RETURNS_ENUM
static pm_visit_result_t
collect_direct_child(const pm_node_t *child, void *data) {
    direct_children_t *dc = (direct_children_t *) data;
    if (child != NULL && dc->count < 256) {
        dc->ids[dc->count++] = child->node_id;
    }
    return PM_VISIT_SKIP;
}
#else
static bool
collect_direct_child(const pm_node_t *child, void *data) {
    direct_children_t *dc = (direct_children_t *) data;
    if (child != NULL && dc->count < 256) {
        dc->ids[dc->count++] = child->node_id;
    }
    return false;
}
#endif

static const pm_string_t *
node_unescaped_string(const pm_node_t *n) {
    if (n == NULL) return NULL;
    switch (PM_NODE_TYPE(n)) {
        case PM_STRING_NODE:
            return &((const pm_string_node_t *) n)->unescaped;
        case PM_X_STRING_NODE:
            return &((const pm_x_string_node_t *) n)->unescaped;
        default:
            return NULL;
    }
}

static int
node_string_locs(
    const pm_node_t *n,
    const pm_location_t **open_loc,
    const pm_location_t **content_loc,
    const pm_location_t **close_loc
) {
    *open_loc = NULL;
    *content_loc = NULL;
    *close_loc = NULL;
    if (n == NULL) return 0;
    switch (PM_NODE_TYPE(n)) {
        case PM_STRING_NODE: {
            const pm_string_node_t *s = (const pm_string_node_t *) n;
            *open_loc = &s->opening_loc;
            *content_loc = &s->content_loc;
            *close_loc = &s->closing_loc;
            return 1;
        }
        case PM_X_STRING_NODE: {
            const pm_x_string_node_t *s = (const pm_x_string_node_t *) n;
            *open_loc = &s->opening_loc;
            *content_loc = &s->content_loc;
            *close_loc = &s->closing_loc;
            return 1;
        }
        case PM_INTERPOLATED_STRING_NODE: {
            const pm_interpolated_string_node_t *s = (const pm_interpolated_string_node_t *) n;
            *open_loc = &s->opening_loc;
            *close_loc = &s->closing_loc;
            return 1;
        }
        case PM_INTERPOLATED_X_STRING_NODE: {
            const pm_interpolated_x_string_node_t *s = (const pm_interpolated_x_string_node_t *) n;
            *open_loc = &s->opening_loc;
            *close_loc = &s->closing_loc;
            return 1;
        }
        default:
            return 0;
    }
}

static uint64_t
compute_ast_hash(const pm_parser_t *parser) {
    uint64_t h = 14695981039346656037ULL;
    for (uint32_t i = 1; i <= g_trace_node_count; i++) {
        const pm_node_t *n = g_trace_nodes[i];
        if (n == NULL) continue;
        uint32_t n_start = loc_start_offset(parser, &n->location);
        uint32_t n_len = loc_length_bytes(&n->location);
        h ^= (uint64_t)n->node_id; h *= 1099511628211ULL;
        h ^= (uint64_t)n_start; h *= 1099511628211ULL;
        h ^= (uint64_t)n_len; h *= 1099511628211ULL;
        const pm_location_t *oloc = NULL, *cloc = NULL, *clloc = NULL;
        if (node_string_locs(n, &oloc, &cloc, &clloc)) {
            if (oloc != NULL) {
                h ^= (uint64_t)loc_start_offset(parser, oloc); h *= 1099511628211ULL;
                h ^= (uint64_t)loc_length_bytes(oloc); h *= 1099511628211ULL;
            }
            if (cloc != NULL) {
                h ^= (uint64_t)loc_start_offset(parser, cloc); h *= 1099511628211ULL;
                h ^= (uint64_t)loc_length_bytes(cloc); h *= 1099511628211ULL;
            }
            if (clloc != NULL) {
                h ^= (uint64_t)loc_start_offset(parser, clloc); h *= 1099511628211ULL;
                h ^= (uint64_t)loc_length_bytes(clloc); h *= 1099511628211ULL;
            }
        }
        const pm_string_t *unesc = node_unescaped_string(n);
        if (unesc != NULL) {
            size_t ulen = pm_string_length(unesc);
            const uint8_t *usrc = pm_string_source(unesc);
            h ^= (uint64_t)ulen; h *= 1099511628211ULL;
            if (usrc != NULL) {
                size_t cap = ulen < 64 ? ulen : 64;
                for (size_t k = 0; k < cap; k++) {
                    h ^= (uint64_t)usrc[k]; h *= 1099511628211ULL;
                }
            }
        }
        direct_children_t dc = { .count = 0 };
        pm_visit_child_nodes(n, collect_direct_child, &dc);
        h ^= (uint64_t)dc.count; h *= 1099511628211ULL;
        for (size_t j = 0; j < dc.count; j++) {
            h ^= (uint64_t)dc.ids[j]; h *= 1099511628211ULL;
        }
    }
    return h;
}

static const char *
diag_type_name(const pm_diagnostic_t *diag) {
    if (diag == NULL) return "UNKNOWN";
#if PRISM_TRACE_HAS_DIAG_TYPE_FN
    const char *dtype = pm_diagnostic_type(diag);
#else
    const char *dtype = pm_diagnostic_id_human(diag->diag_id);
#endif
    return dtype != NULL ? dtype : "UNKNOWN";
}

static uint64_t
compute_diags_hash(const pm_parser_t *parser) {
    if (parser == NULL) return 0;
    if (parser->error_list.size == 0 && parser->warning_list.size == 0 &&
        parser->error_list.head == NULL && parser->warning_list.head == NULL) {
        return 0;
    }
    uint64_t src_len = (parser->end >= parser->start) ? (uint64_t)(parser->end - parser->start) : 0;
    uint64_t h = 14695981039346656037ULL;
    h ^= (uint64_t)parser->error_list.size; h *= 1099511628211ULL;
    h ^= (uint64_t)parser->warning_list.size; h *= 1099511628211ULL;

    const pm_list_node_t *lists[2] = { parser->error_list.head, parser->warning_list.head };
    for (int li = 0; li < 2; li++) {
        h ^= (uint64_t)(li + 1); h *= 1099511628211ULL;
        size_t guard = 0;
        for (const pm_list_node_t *cur = lists[li]; cur != NULL && guard++ < 512; cur = cur->next) {
            const pm_diagnostic_t *d = (const pm_diagnostic_t *)cur;
            trace_loc_info_t loc = eval_loc_bounds(parser, &d->location, src_len);
            h ^= (uint64_t)d->diag_id; h *= 1099511628211ULL;
            h ^= (uint64_t)d->level; h *= 1099511628211ULL;
            h ^= (uint64_t)loc.start; h *= 1099511628211ULL;
            h ^= (uint64_t)loc.len; h *= 1099511628211ULL;
            h ^= (uint64_t)((loc.underflow << 1) | loc.oob); h *= 1099511628211ULL;
            if (d->message != NULL) {
                for (size_t k = 0; d->message[k] != '\0' && k < 32; k++) {
                    h ^= (uint64_t)(uint8_t)d->message[k]; h *= 1099511628211ULL;
                }
            }
        }
    }
    return h == 0 ? 1ULL : h;
}

static uint64_t
compute_comments_hash(const pm_parser_t *parser) {
    if (parser == NULL) return 0;
    if (parser->comment_list.size == 0 && parser->magic_comment_list.size == 0 &&
        parser->comment_list.head == NULL && parser->magic_comment_list.head == NULL) {
        return 0;
    }
    uint64_t src_len = (parser->end >= parser->start) ? (uint64_t)(parser->end - parser->start) : 0;
    uint64_t h = 14695981039346656037ULL;
    h ^= (uint64_t)parser->comment_list.size; h *= 1099511628211ULL;
    h ^= (uint64_t)parser->magic_comment_list.size; h *= 1099511628211ULL;
#if PRISM_TRACE_HAS_ATTACH_COMMENTS
    int attached = (parser->attach_comments && parser->comment_attachments.comments != NULL) ? 1 : 0;
    h ^= (uint64_t)attached; h *= 1099511628211ULL;
#endif

    size_t guard = 0;
    for (const pm_list_node_t *cur = parser->comment_list.head; cur != NULL && guard++ < 512; cur = cur->next) {
        const pm_comment_t *c = (const pm_comment_t *)cur;
        trace_loc_info_t loc = eval_loc_bounds(parser, &c->location, src_len);
        h ^= (uint64_t)c->type; h *= 1099511628211ULL;
        h ^= (uint64_t)loc.start; h *= 1099511628211ULL;
        h ^= (uint64_t)loc.len; h *= 1099511628211ULL;
        h ^= (uint64_t)((loc.underflow << 1) | loc.oob); h *= 1099511628211ULL;
    }

    guard = 0;
    for (const pm_list_node_t *cur = parser->magic_comment_list.head; cur != NULL && guard++ < 256; cur = cur->next) {
        const pm_magic_comment_t *mc = (const pm_magic_comment_t *)cur;
#if PRISM_TRACE_MAGIC_COMMENT_HAS_LOC
        trace_loc_info_t kl = eval_loc_bounds(parser, &mc->key, src_len);
        trace_loc_info_t vl = eval_loc_bounds(parser, &mc->value, src_len);
#else
        trace_loc_info_t kl = eval_ptr_len_bounds(parser, mc->key_start, mc->key_length, src_len);
        trace_loc_info_t vl = eval_ptr_len_bounds(parser, mc->value_start, mc->value_length, src_len);
#endif
        h ^= (uint64_t)kl.start; h *= 1099511628211ULL;
        h ^= (uint64_t)kl.len; h *= 1099511628211ULL;
        h ^= (uint64_t)vl.start; h *= 1099511628211ULL;
        h ^= (uint64_t)vl.len; h *= 1099511628211ULL;
        h ^= (uint64_t)((kl.underflow << 3) | (kl.oob << 2) | (vl.underflow << 1) | vl.oob);
        h *= 1099511628211ULL;
    }
    return h == 0 ? 1ULL : h;
}

static ptrdiff_t
ptr_offset(const pm_parser_t *parser, const uint8_t *p) {
    if (p == NULL || parser == NULL || parser->start == NULL) return -1;
    return p - parser->start;
}

static const char *
safe_token_type_name(pm_token_type_t t) {
    if (t < PM_TOKEN_EOF || t >= PM_TOKEN_MAXIMUM) {
        return "NOT_PROVIDED";
    }
    return pm_token_type(t);
}

#if PRISM_TRACE_HAS_ARENA
static void
measure_arena(const pm_arena_t *arena, size_t *out_used, size_t *out_cap, size_t *out_blocks) {
    size_t used = 0;
    size_t cap = 0;
    size_t blocks = 0;
    if (arena != NULL) {
        const pm_arena_block_t *b = arena->current;
        while (b != NULL && blocks < 4096) {
            used += b->used;
            cap += b->capacity;
            blocks++;
            b = b->prev;
        }
    }
    *out_used = used;
    *out_cap = cap;
    *out_blocks = blocks;
}
#endif

static void
emit_diag_hook_event(
    const pm_parser_t *parser,
    const pm_list_t *list,
    const pm_list_node_t **last_tail_slot,
    const char *event_kind,
    const char *severity,
    const char *func,
    int line
) {
    if (parser == NULL || g_trace_buf == NULL || g_trace_in_hook) return;
    const pm_list_node_t *tail = list != NULL ? list->tail : NULL;
    if (tail != NULL && tail == *last_tail_slot) return;
    *last_tail_slot = tail;

    const pm_diagnostic_t *diag = (const pm_diagnostic_t *)tail;
    if (diag != NULL) {
        uint64_t src_len = (parser->end >= parser->start) ? (uint64_t)(parser->end - parser->start) : 0;
        trace_loc_info_t loc = eval_loc_bounds(parser, &diag->location, src_len);
        char esc_type[256];
        char esc_msg[1152];
        char detail[1600];
        json_escape_to_cstr(esc_type, sizeof(esc_type), diag_type_name(diag), 96);
        json_escape_to_cstr(esc_msg, sizeof(esc_msg), diag->message ? diag->message : "", 180);
        snprintf(
            detail,
            sizeof(detail),
            "{\"severity\":\"%s\",\"diag_type\":%s,\"message\":%s,\"level\":%u,"
            "\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"length\":%" PRIu32 ",\"len\":%" PRIu32 ","
            "\"underflow\":%s,\"oob\":%s}",
            severity,
            esc_type,
            esc_msg,
            (unsigned)diag->level,
            loc.start,
            loc.end,
            loc.len,
            loc.len,
            loc.underflow ? "true" : "false",
            loc.oob ? "true" : "false"
        );
        prism_trace_emit_event(parser, event_kind, func, line, detail, 0);
    } else {
        prism_trace_emit_event(parser, event_kind, func, line, NULL, 0);
    }
}

void
prism_trace_emit_last_error(const pm_parser_t *parser, const char *func, int line) {
    if (parser == NULL) return;
    emit_diag_hook_event(parser, &parser->error_list, &g_last_emitted_error_tail, "ERROR", "error", func, line);
}

void
prism_trace_emit_last_warning(const pm_parser_t *parser, const char *func, int line) {
    if (parser == NULL) return;
    emit_diag_hook_event(parser, &parser->warning_list, &g_last_emitted_warning_tail, "WARNING", "warning", func, line);
}

void
prism_trace_emit_event(
    const pm_parser_t *parser,
    const char *kind,
    const char *func,
    int line,
    const char *detail_json,
    int include_ast
) {
    if (g_trace_buf == NULL || parser == NULL || g_trace_in_hook) return;
    if (g_trace_step >= g_trace_max_steps) return;
    if (!g_trace_crashed && pm_buffer_length(g_trace_buf) >= PRISM_TRACE_MAX_BUF_BYTES) {
        g_trace_max_steps = g_trace_step;
        return;
    }

    g_trace_in_hook = 1;
    if (func != NULL && func[0] != '\0') {
        g_trace_last_func = func;
        g_trace_last_line = line;
        size_t flen = strlen(func);
        g_trace_last_file = (flen > 7 && strncmp(func, "pm_", 3) == 0 && strcmp(func + flen - 4, "_new") == 0)
            ? "src/node.c"
            : "src/prism.c";
    }
    pm_buffer_t *out = g_trace_buf;
    g_trace_event_start_len = pm_buffer_length(out);
    uint64_t src_len = (parser->end >= parser->start) ? (uint64_t)(parser->end - parser->start) : 0;
    int is_crash = (kind != NULL && strcmp(kind, "CRASH") == 0) ? 1 : 0;

    char state_buf[256];
    format_lex_state(parser->lex_state, state_buf, sizeof(state_buf));

    ptrdiff_t prev_s = ptr_offset(parser, parser->previous.start);
    ptrdiff_t prev_e = ptr_offset(parser, parser->previous.end);
    ptrdiff_t curr_s = ptr_offset(parser, parser->current.start);
    ptrdiff_t curr_e = ptr_offset(parser, parser->current.end);
    ptrdiff_t next_s = ptr_offset(parser, parser->next_start);
    ptrdiff_t hdoc_e = ptr_offset(parser, parser->heredoc_end);

    pm_buffer_append_format(out, "{\"step\":%" PRIu64 ",\"kind\":\"%s\",\"func\":\"%s\",\"line\":%d",
            g_trace_step++, kind, func ? func : "", line);
    if (src_len != g_trace_input_size) {
        pm_buffer_append_format(out, ",\"src_len\":%" PRIu64, src_len);
    }

    pm_buffer_append_format(out, ",\"prev\":[%td,%td,\"%s\"]",
            prev_s, prev_e, safe_token_type_name(parser->previous.type));
    pm_buffer_append_format(out, ",\"curr\":[%td,%td,\"%s\"]",
            curr_s, curr_e, safe_token_type_name(parser->current.type));
    pm_buffer_append_format(out, ",\"next_start\":%td,\"heredoc_end\":%td", next_s, hdoc_e);
    pm_buffer_append_format(out, ",\"lex_state\":\"%s\"", state_buf);

    // Lex modes stack (from current down to base)
    PM_BUFFER_APPEND_LITERAL(out, ",\"lex_modes\":[");
    const pm_lex_mode_t *lm = parser->lex_modes.current;
    int first_lm = 1;
    int guard = 0;
    while (lm != NULL && guard++ < 32) {
        if (!first_lm) pm_buffer_append_byte(out, ',');
        first_lm = 0;
        switch (lm->mode) {
            case PM_LEX_DEFAULT:
                PM_BUFFER_APPEND_LITERAL(out, "{\"mode\":\"DEFAULT\"}");
                break;
            case PM_LEX_EMBEXPR:
                PM_BUFFER_APPEND_LITERAL(out, "{\"mode\":\"EMBEXPR\"}");
                break;
            case PM_LEX_EMBVAR:
                PM_BUFFER_APPEND_LITERAL(out, "{\"mode\":\"EMBVAR\"}");
                break;
            case PM_LEX_LIST:
                pm_buffer_append_format(out, "{\"mode\":\"LIST\",\"nesting\":%zu,\"interp\":%s,\"term\":%u}",
                        lm->as.list.nesting, lm->as.list.interpolation ? "true" : "false",
                        (unsigned)lm->as.list.terminator);
                break;
            case PM_LEX_REGEXP:
                pm_buffer_append_format(out, "{\"mode\":\"REGEXP\",\"nesting\":%zu,\"term\":%u}",
                        lm->as.regexp.nesting, (unsigned)lm->as.regexp.terminator);
                break;
            case PM_LEX_STRING:
                pm_buffer_append_format(out, "{\"mode\":\"STRING\",\"nesting\":%zu,\"interp\":%s,\"term\":%u}",
                        lm->as.string.nesting, lm->as.string.interpolation ? "true" : "false",
                        (unsigned)lm->as.string.terminator);
                break;
            case PM_LEX_HEREDOC: {
                const char *indent_str =
                    lm->as.heredoc.base.indent == PM_HEREDOC_INDENT_DASH ? "DASH" :
                    lm->as.heredoc.base.indent == PM_HEREDOC_INDENT_TILDE ? "TILDE" : "NONE";
                PM_BUFFER_APPEND_LITERAL(out, "{\"mode\":\"HEREDOC\",\"ident\":");
                if (lm->as.heredoc.base.ident_start != NULL) {
                    buf_append_json_escaped(out, lm->as.heredoc.base.ident_start, lm->as.heredoc.base.ident_length);
                } else {
                    PM_BUFFER_APPEND_LITERAL(out, "\"\"");
                }
                pm_buffer_append_format(out, ",\"indent\":\"%s\",\"quote\":%d,\"next_start\":%td}",
                        indent_str, (int)lm->as.heredoc.base.quote,
                        ptr_offset(parser, lm->as.heredoc.next_start));
                break;
            }
        }
        lm = lm->prev;
    }
    pm_buffer_append_byte(out, ']');

    // Context stack
    PM_BUFFER_APPEND_LITERAL(out, ",\"contexts\":[");
    const pm_context_node_t *cn = parser->current_context;
    int first_cn = 1;
    guard = 0;
    while (cn != NULL && guard++ < 64) {
        if (!first_cn) pm_buffer_append_byte(out, ',');
        first_cn = 0;
        pm_buffer_append_format(out, "\"%s\"", prism_trace_context_name(cn->context));
        cn = cn->prev;
    }
    pm_buffer_append_byte(out, ']');

    // Parse call stack
    PM_BUFFER_APPEND_LITERAL(out, ",\"call_stack\":[");
    for (int i = 0; i < g_trace_call_depth; i++) {
        if (i > 0) pm_buffer_append_byte(out, ',');
        pm_buffer_append_format(out, "\"%s\"", g_trace_call_stack[i]);
    }
    pm_buffer_append_byte(out, ']');

    // Line offsets (up to 128) + full-list invariant scan
    PM_BUFFER_APPEND_LITERAL(out, ",\"line_offsets\":[");
#if PRISM_TRACE_HAS_LINE_OFFSETS
    size_t total_lines = parser->line_offsets.size;
    size_t lo_cap = parser->line_offsets.capacity;
    size_t n_lines = total_lines > 128 ? 128 : total_lines;
    for (size_t i = 0; i < n_lines; i++) {
        if (i > 0) pm_buffer_append_byte(out, ',');
        pm_buffer_append_format(out, "%" PRIu32, parser->line_offsets.offsets[i]);
    }
#else
    size_t total_lines = parser->newline_list.size;
    size_t lo_cap = parser->newline_list.capacity;
    size_t n_lines = total_lines > 128 ? 128 : total_lines;
    for (size_t i = 0; i < n_lines; i++) {
        if (i > 0) pm_buffer_append_byte(out, ',');
        pm_buffer_append_format(out, "%zu", parser->newline_list.offsets[i]);
    }
#endif
    pm_buffer_append_byte(out, ']');

    {
        int first_lo_anom = 1;
        size_t lo_anom_count = 0;
        if (total_lines == 0) {
            PM_BUFFER_APPEND_LITERAL(out, ",\"lo_anomalies\":[{\"line\":1,\"offset\":0,\"prev\":0,\"kind\":\"empty\"}]");
        } else {
            size_t scan_limit = total_lines < 65536 ? total_lines : 65536;
            for (size_t i = 0; i < scan_limit && lo_anom_count < 64; i++) {
#if PRISM_TRACE_HAS_LINE_OFFSETS
                uint64_t off = (parser->line_offsets.offsets != NULL) ? (uint64_t)parser->line_offsets.offsets[i] : 0;
                uint64_t prev_off = (i > 0 && parser->line_offsets.offsets != NULL) ? (uint64_t)parser->line_offsets.offsets[i - 1] : 0;
#else
                uint64_t off = (parser->newline_list.offsets != NULL) ? (uint64_t)parser->newline_list.offsets[i] : 0;
                uint64_t prev_off = (i > 0 && parser->newline_list.offsets != NULL) ? (uint64_t)parser->newline_list.offsets[i - 1] : 0;
#endif
                const char *anom_kind = NULL;
                if (src_len < 0x80000000ULL && off >= 0x80000000ULL) {
                    anom_kind = "underflow";
                } else if (off > src_len) {
                    anom_kind = "oob";
                } else if (i == 0 && off != 0) {
                    anom_kind = "nonzero_start";
                } else if (i > 0 && off <= prev_off) {
                    anom_kind = "order";
                }
                if (anom_kind != NULL) {
                    if (first_lo_anom) {
                        PM_BUFFER_APPEND_LITERAL(out, ",\"lo_anomalies\":[");
                        first_lo_anom = 0;
                    } else {
                        pm_buffer_append_byte(out, ',');
                    }
                    pm_buffer_append_format(
                        out,
                        "{\"line\":%zu,\"offset\":%" PRIu64 ",\"prev\":%" PRIu64 ",\"kind\":\"%s\"}",
                        i + 1, off, prev_off, anom_kind
                    );
                    lo_anom_count++;
                }
            }
            if (!first_lo_anom) {
                pm_buffer_append_byte(out, ']');
            }
        }
    }

    pm_buffer_append_format(
        out,
        ",\"errors\":%zu,\"warnings\":%zu,\"comments_count\":%zu",
        parser->error_list.size,
        parser->warning_list.size,
        parser->comment_list.size
    );

    size_t ast_u = 0, ast_c = 0, ast_b = 0;
    size_t meta_u = 0, meta_c = 0, meta_b = 0;
    size_t scr_u = 0, scr_c = 0, scr_b = 0;
#if PRISM_TRACE_HAS_ARENA
    measure_arena(parser->arena, &ast_u, &ast_c, &ast_b);
#endif
#if PRISM_TRACE_HAS_METADATA_ARENA
    measure_arena(&parser->metadata_arena, &meta_u, &meta_c, &meta_b);
#endif
#if PRISM_TRACE_HAS_SCRATCH_ARENA
    measure_arena(&parser->scratch_arena, &scr_u, &scr_c, &scr_b);
#endif

    pm_buffer_append_format(
        out,
        ",\"mem\":{\"ast\":[%zu,%zu,%zu],\"meta\":[%zu,%zu,%zu],\"scratch\":[%zu,%zu,%zu],\"lo\":[%zu,%zu],\"cp\":[%" PRIu32 ",%" PRIu32 "],\"xalloc\":[%zu,%zu,%zu,%zu]}",
        ast_u, ast_c, ast_b,
        meta_u, meta_c, meta_b,
        scr_u, scr_c, scr_b,
        total_lines, lo_cap,
        parser->constant_pool.size, parser->constant_pool.capacity,
        g_trace_xalloc_live_bytes, g_trace_xalloc_peak_bytes,
        g_trace_xalloc_alloc_count, g_trace_xalloc_free_count
    );

    if (detail_json != NULL) {
        pm_buffer_append_format(out, ",\"detail\":%s", detail_json);
    }

    // Emit diagnostics snapshot when error_list or warning_list changed (or on CRASH)
    {
        uint64_t diags_hash = compute_diags_hash(parser);
        if (diags_hash != g_last_diags_hash || (is_crash && diags_hash != 0)) {
            g_last_diags_hash = diags_hash;
            PM_BUFFER_APPEND_LITERAL(out, ",\"diagnostics\":[");
            int first_diag = 1;
            uint32_t diag_seq = 0;
            const pm_list_node_t *lists[2] = { parser->error_list.head, parser->warning_list.head };
            const char *severities[2] = { "error", "warning" };
            for (int li = 0; li < 2; li++) {
                size_t d_guard = 0;
                for (const pm_list_node_t *cur = lists[li]; cur != NULL && d_guard++ < 256; cur = cur->next) {
                    const pm_diagnostic_t *d = (const pm_diagnostic_t *)cur;
                    trace_loc_info_t d_loc = eval_loc_bounds(parser, &d->location, src_len);
                    if (!first_diag) pm_buffer_append_byte(out, ',');
                    first_diag = 0;
                    diag_seq++;
                    PM_BUFFER_APPEND_LITERAL(out, "{\"id\":");
                    pm_buffer_append_format(out, "%" PRIu32 ",\"severity\":\"%s\",\"type\":", diag_seq, severities[li]);
                    buf_append_cstr_json_escaped(out, diag_type_name(d));
                    PM_BUFFER_APPEND_LITERAL(out, ",\"message\":");
                    if (d->message != NULL) {
                        size_t mlen = strlen(d->message);
                        if (mlen > 160) mlen = 160;
                        buf_append_json_escaped(out, (const uint8_t *)d->message, mlen);
                    } else {
                        PM_BUFFER_APPEND_LITERAL(out, "\"\"");
                    }
                    pm_buffer_append_format(
                        out,
                        ",\"level\":%u,\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"len\":%" PRIu32 ",\"underflow\":%s%s}",
                        (unsigned)d->level,
                        d_loc.start,
                        d_loc.end,
                        d_loc.len,
                        d_loc.underflow ? "true" : "false",
                        d_loc.oob ? ",\"oob\":true" : ""
                    );
                }
            }
            pm_buffer_append_byte(out, ']');
        }
    }

    // Emit comments & magic_comments snapshot when comment_list or magic_comment_list changed (or on CRASH)
    {
        uint64_t comments_hash = compute_comments_hash(parser);
        if (comments_hash != g_last_comments_hash || (is_crash && comments_hash != 0)) {
            g_last_comments_hash = comments_hash;
            int comments_attached = 0;
#if PRISM_TRACE_HAS_ATTACH_COMMENTS
            comments_attached = (parser->attach_comments && parser->comment_attachments.comments != NULL) ? 1 : 0;
#endif
            PM_BUFFER_APPEND_LITERAL(out, ",\"comments\":[");
            int first_c = 1;
            uint32_t c_seq = 0;
            uint32_t seen_starts[256];
            uint32_t seen_ends[256];
            size_t seen_valid = 0;
            uint32_t prev_valid_start = 0;
            int has_prev_valid = 0;
            size_t c_guard = 0;
            for (const pm_list_node_t *cur = parser->comment_list.head; cur != NULL && c_guard++ < 256; cur = cur->next) {
                const pm_comment_t *c = (const pm_comment_t *)cur;
                trace_loc_info_t c_loc = eval_loc_bounds(parser, &c->location, src_len);
                const char *ctype =
                    c->type == PM_COMMENT_EMBDOC ? "EMBDOC" :
                    c->type == PM_COMMENT_INLINE ? "INLINE" : "OTHER";
                int overlap = 0;
                int lex_rewind = 0;
                int unsorted = 0;
                if (!c_loc.underflow && !c_loc.oob) {
                    for (size_t j = 0; j < seen_valid; j++) {
                        if (c_loc.start == seen_starts[j] ||
                            (c_loc.end > c_loc.start && seen_ends[j] > seen_starts[j] &&
                             c_loc.start < seen_ends[j] && seen_starts[j] < c_loc.end)) {
                            overlap = 1;
                            break;
                        }
                    }
                    if (has_prev_valid && c_loc.start < prev_valid_start) {
                        if (comments_attached) {
                            unsorted = 1;
                        } else if (!overlap) {
                            lex_rewind = 1;
                        }
                    }
                    if (seen_valid < 256) {
                        seen_starts[seen_valid] = c_loc.start;
                        seen_ends[seen_valid] = c_loc.end;
                        seen_valid++;
                    }
                    prev_valid_start = c_loc.start;
                    has_prev_valid = 1;
                }
                if (!first_c) pm_buffer_append_byte(out, ',');
                first_c = 0;
                c_seq++;
                pm_buffer_append_format(
                    out,
                    "{\"id\":%" PRIu32 ",\"type\":\"%s\",\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"len\":%" PRIu32 ",\"underflow\":%s%s%s%s%s}",
                    c_seq,
                    ctype,
                    c_loc.start,
                    c_loc.end,
                    c_loc.len,
                    c_loc.underflow ? "true" : "false",
                    c_loc.oob ? ",\"oob\":true" : "",
                    overlap ? ",\"overlap\":true" : "",
                    unsorted ? ",\"unsorted\":true" : "",
                    lex_rewind ? ",\"lex_rewind\":true" : ""
                );
            }
            pm_buffer_append_byte(out, ']');

            PM_BUFFER_APPEND_LITERAL(out, ",\"magic_comments\":[");
            int first_mc = 1;
            uint32_t mc_seq = 0;
            size_t mc_guard = 0;
            for (const pm_list_node_t *cur = parser->magic_comment_list.head; cur != NULL && mc_guard++ < 128; cur = cur->next) {
                const pm_magic_comment_t *mc = (const pm_magic_comment_t *)cur;
#if PRISM_TRACE_MAGIC_COMMENT_HAS_LOC
                trace_loc_info_t kl = eval_loc_bounds(parser, &mc->key, src_len);
                trace_loc_info_t vl = eval_loc_bounds(parser, &mc->value, src_len);
#else
                trace_loc_info_t kl = eval_ptr_len_bounds(parser, mc->key_start, mc->key_length, src_len);
                trace_loc_info_t vl = eval_ptr_len_bounds(parser, mc->value_start, mc->value_length, src_len);
#endif
                int mc_underflow = (kl.underflow || vl.underflow) ? 1 : 0;
                int mc_oob = (!mc_underflow && (kl.oob || vl.oob)) ? 1 : 0;
                if (!first_mc) pm_buffer_append_byte(out, ',');
                first_mc = 0;
                mc_seq++;
                pm_buffer_append_format(
                    out,
                    "{\"id\":%" PRIu32 ",\"key_start\":%" PRIu32 ",\"key_end\":%" PRIu32 ",\"key_len\":%" PRIu32
                    ",\"val_start\":%" PRIu32 ",\"val_end\":%" PRIu32 ",\"val_len\":%" PRIu32
                    ",\"key_underflow\":%s,\"key_oob\":%s,\"val_underflow\":%s,\"val_oob\":%s"
                    ",\"underflow\":%s%s}",
                    mc_seq,
                    kl.start, kl.end, kl.len,
                    vl.start, vl.end, vl.len,
                    kl.underflow ? "true" : "false",
                    kl.oob ? "true" : "false",
                    vl.underflow ? "true" : "false",
                    vl.oob ? "true" : "false",
                    mc_underflow ? "true" : "false",
                    mc_oob ? ",\"oob\":true" : ""
                );
            }
            pm_buffer_append_byte(out, ']');
        }
    }

    if (!include_ast && g_trace_node_count > 0) {
        if (compute_ast_hash(parser) != g_last_ast_hash) {
            include_ast = 1;
        }
    }

    if (include_ast) {
        g_last_ast_hash = compute_ast_hash(parser);
        PM_BUFFER_APPEND_LITERAL(out, ",\"ast\":[");
        int first_node = 1;
        for (uint32_t i = 1; i <= g_trace_node_count; i++) {
            const pm_node_t *n = g_trace_nodes[i];
            if (n == NULL) continue;
            if (!first_node) pm_buffer_append_byte(out, ',');
            first_node = 0;

            const char *tname = pm_node_type(n->type);
            if (strncmp(tname, "PM_", 3) == 0) tname += 3;

            direct_children_t dc = { .count = 0 };
            pm_visit_child_nodes(n, collect_direct_child, &dc);

            trace_loc_info_t n_loc = eval_loc_bounds(parser, &n->location, src_len);

            pm_buffer_append_format(out,
                    "{\"id\":%" PRIu32 ",\"type\":\"%s\",\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"len\":%" PRIu32 ",\"underflow\":%s%s",
                    n->node_id, tname, n_loc.start, n_loc.end, n_loc.len,
                    n_loc.underflow ? "true" : "false",
                    n_loc.oob ? ",\"oob\":true" : "");
            const pm_string_t *unesc = node_unescaped_string(n);
            if (unesc != NULL) {
                size_t ulen = pm_string_length(unesc);
                const uint8_t *usrc = pm_string_source(unesc);
                if (usrc != NULL) {
                    size_t cap = ulen < 48 ? ulen : 48;
                    PM_BUFFER_APPEND_LITERAL(out, ",\"val\":");
                    buf_append_json_escaped(out, usrc, cap);
                }
            }
            const pm_location_t *oloc = NULL, *cloc = NULL, *clloc = NULL;
            if (node_string_locs(n, &oloc, &cloc, &clloc)) {
                if (oloc != NULL) {
                    uint32_t o_start = loc_start_offset(parser, oloc);
                    uint32_t o_len = loc_length_bytes(oloc);
                    if (o_len > 0 && (uint64_t)o_start + (uint64_t)o_len <= src_len) {
                        pm_buffer_append_format(out, ",\"o_loc\":[%" PRIu32 ",%" PRIu32 "]", o_start, o_start + o_len);
                    }
                }
                if (cloc != NULL) {
                    uint32_t c_start = loc_start_offset(parser, cloc);
                    uint32_t c_len = loc_length_bytes(cloc);
                    if ((uint64_t)c_start + (uint64_t)c_len <= src_len) {
                        pm_buffer_append_format(out, ",\"c_loc\":[%" PRIu32 ",%" PRIu32 "]", c_start, c_start + c_len);
                    }
                }
                if (clloc != NULL) {
                    uint32_t cl_start = loc_start_offset(parser, clloc);
                    uint32_t cl_len = loc_length_bytes(clloc);
                    if (cl_len > 0 && (uint64_t)cl_start + (uint64_t)cl_len <= src_len) {
                        pm_buffer_append_format(out, ",\"cl_loc\":[%" PRIu32 ",%" PRIu32 "]", cl_start, cl_start + cl_len);
                    }
                }
            }
            PM_BUFFER_APPEND_LITERAL(out, ",\"children\":[");
            for (size_t j = 0; j < dc.count; j++) {
                if (j > 0) pm_buffer_append_byte(out, ',');
                pm_buffer_append_format(out, "%" PRIu32, dc.ids[j]);
            }
            PM_BUFFER_APPEND_LITERAL(out, "]}");
        }
        pm_buffer_append_byte(out, ']');
    }

    PM_BUFFER_APPEND_LITERAL(out, "}\n");
    g_trace_in_hook = 0;
}

#if defined(__wasm__)
__attribute__((import_module("env"), import_name("prism_host_debugger")))
extern void prism_host_debugger(const char *reason, const char *expr, const char *file, int line, const char *func);
#endif

void
prism_trace_emit_crash(const char *reason, const char *expr, const char *file, int line, const char *func) {
    if (g_trace_crashed) return;
    int was_in_hook = g_trace_in_hook;
    g_trace_crashed = 1;
    g_trace_in_hook = 0;

    if (was_in_hook && g_trace_buf != NULL && g_trace_buf->value != NULL) {
        size_t buf_alloc_sz = 0;
        if (query_alloc_metadata(g_trace_buf->value, &buf_alloc_sz, NULL)) {
            g_trace_buf->capacity = buf_alloc_sz;
            if (g_trace_event_start_len <= buf_alloc_sz) {
                g_trace_buf->length = g_trace_event_start_len;
            }
        }
        if (g_trace_step > 0) {
            g_trace_step--;
        }
    }

    if (file != NULL) {
        const char *trace_src_pos = strstr(file, "trace_src/");
        const char *slash_src_pos = strstr(file, "/src/");
        const char *slash_inc_pos = strstr(file, "/include/");
        if (trace_src_pos != NULL) {
            file = trace_src_pos;
        } else if (slash_src_pos != NULL) {
            file = slash_src_pos + 1;
        } else if (slash_inc_pos != NULL) {
            file = slash_inc_pos + 1;
        }
    }

    if (g_trace_buf != NULL && g_trace_parser != NULL) {
        if (g_trace_step >= g_trace_max_steps) {
            g_trace_max_steps = g_trace_step + 1;
        }
        pm_buffer_t detail_buf = { 0 };
        PM_BUFFER_APPEND_LITERAL(&detail_buf, "{\"reason\":");
        buf_append_cstr_json_escaped(&detail_buf, reason ? reason : "CRASH");
        PM_BUFFER_APPEND_LITERAL(&detail_buf, ",\"expr\":");
        buf_append_cstr_json_escaped(&detail_buf, expr ? expr : "");
        PM_BUFFER_APPEND_LITERAL(&detail_buf, ",\"file\":");
        buf_append_cstr_json_escaped(&detail_buf, file ? file : "");
        pm_buffer_append_format(&detail_buf, ",\"line\":%d,\"func\":", line);
        buf_append_cstr_json_escaped(&detail_buf, func ? func : "");
        pm_buffer_append_byte(&detail_buf, '}');
        pm_buffer_append_byte(&detail_buf, '\0');

        prism_trace_emit_event(
            g_trace_parser,
            "CRASH",
            func ? func : "unknown",
            line,
            pm_buffer_value(&detail_buf),
            1
        );
        pm_buffer_cleanup(&detail_buf);
    } else if (g_trace_crash_out_buf != NULL) {
        pm_buffer_t *out = g_trace_crash_out_buf;
        pm_buffer_append_format(
            out,
            "{\"step\":%" PRIu64 ",\"kind\":\"CRASH\",\"func\":",
            g_trace_step++
        );
        buf_append_cstr_json_escaped(out, func ? func : "pm_parse");
        pm_buffer_append_format(
            out,
            ",\"line\":%d,\"prev\":[-1,-1,\"NOT_PROVIDED\"],\"curr\":[-1,-1,\"NOT_PROVIDED\"],"
            "\"next_start\":-1,\"heredoc_end\":-1,\"lex_state\":\"NONE\","
            "\"lex_modes\":[],\"contexts\":[],\"call_stack\":[],\"line_offsets\":[0],"
            "\"errors\":0,\"warnings\":0,\"comments_count\":0,"
            "\"detail\":{\"reason\":",
            line
        );
        buf_append_cstr_json_escaped(out, reason ? reason : "CRASH");
        PM_BUFFER_APPEND_LITERAL(out, ",\"expr\":");
        buf_append_cstr_json_escaped(out, expr ? expr : "");
        PM_BUFFER_APPEND_LITERAL(out, ",\"file\":");
        buf_append_cstr_json_escaped(out, file ? file : "src/prism.c");
        pm_buffer_append_format(out, ",\"line\":%d,\"func\":", line);
        buf_append_cstr_json_escaped(out, func ? func : "pm_parse");
        PM_BUFFER_APPEND_LITERAL(out, "}}\n");
    }

#if defined(__wasm__)
    prism_host_debugger(
        reason ? reason : "CRASH",
        expr ? expr : "",
        file ? file : "",
        line,
        func ? func : ""
    );
#endif

    if (g_trace_crash_cb != NULL) {
        g_trace_crash_cb();
    }
}

#if defined(__APPLE__)
void
__assert_rtn(const char *func, const char *file, int line, const char *expr) {
    prism_trace_emit_crash("ASSERT_FAIL", expr, file, line, func);
    abort();
}
#elif defined(__wasm__)
_Noreturn void
__assert_fail(const char *expr, const char *file, int line, const char *func) {
    prism_trace_emit_crash("ASSERT_FAIL", expr, file, line, func);
    __builtin_trap();
}
#elif defined(__GLIBC__)
__attribute__((noreturn)) void
__assert_fail(const char *expr, const char *file, unsigned int line, const char *func) {
    prism_trace_emit_crash("ASSERT_FAIL", expr, file, (int) line, func);
    abort();
}
#else
_Noreturn void
__assert_fail(const char *expr, const char *file, int line, const char *func) {
    prism_trace_emit_crash("ASSERT_FAIL", expr, file, line, func);
    abort();
}
#endif

prism_trace_scope_t
prism_trace_scope_enter(const char *func, int line) {
    prism_trace_scope_t s = { .func = func, .line = line, .active = 1 };
    if (func != NULL && func[0] != '\0') {
        g_trace_last_func = func;
        g_trace_last_file = "src/prism.c";
        g_trace_last_line = line;
    }
    if (g_trace_call_depth < PRISM_TRACE_MAX_CALL_STACK) {
        g_trace_call_stack[g_trace_call_depth++] = func;
    }
    prism_trace_emit_event(g_trace_parser, "PARSE_ENTER", func, line, NULL, 0);
    return s;
}

void
prism_trace_scope_cleanup(prism_trace_scope_t *scope) {
    if (!scope || !scope->active) return;
    if (g_trace_call_depth > 0) {
        g_trace_call_depth--;
    }
    if (g_trace_buf == NULL || g_trace_parser == NULL || g_trace_in_hook || g_trace_step >= g_trace_max_steps) {
        return;
    }
    uint64_t cur_hash = compute_ast_hash(g_trace_parser);
    int ast_changed = (cur_hash != g_last_ast_hash) ? 1 : 0;
    prism_trace_emit_event(g_trace_parser, "PARSE_EXIT", scope->func, scope->line, NULL, ast_changed);
}

const pm_node_t *
prism_trace_node_new(const pm_node_t *node, const char *func, int line) {
    if (node != NULL && node->node_id > 0 && node->node_id < PRISM_TRACE_MAX_NODES) {
        g_trace_nodes[node->node_id] = node;
        if (node->node_id > g_trace_node_count) {
            g_trace_node_count = node->node_id;
        }
        if (g_trace_step < g_trace_max_steps) {
            char detail[320];
            const char *tname = pm_node_type(node->type);
            if (strncmp(tname, "PM_", 3) == 0) tname += 3;
            uint32_t n_start = loc_start_offset(g_trace_parser, &node->location);
            uint32_t n_len = loc_length_bytes(&node->location);
            snprintf(detail, sizeof(detail),
                     "{\"node_id\":%" PRIu32 ",\"node_type\":\"%s\",\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"len\":%" PRIu32 "}",
                     node->node_id, tname, n_start, n_start + n_len, n_len);
            prism_trace_emit_event(g_trace_parser, "NODE_NEW", func, line, detail, 1);
        }
    }
    return node;
}

void
prism_trace_node_list_append(const pm_node_list_t *list, const pm_node_t *node, const char *func, int line) {
    if (node != NULL && g_trace_parser != NULL && g_trace_step < g_trace_max_steps) {
        char detail[256];
        const char *tname = pm_node_type(node->type);
        if (strncmp(tname, "PM_", 3) == 0) tname += 3;
        snprintf(detail, sizeof(detail),
                 "{\"node_id\":%" PRIu32 ",\"node_type\":\"%s\",\"list_size\":%zu}",
                 node->node_id, tname, list ? list->size : 0);
        prism_trace_emit_event(g_trace_parser, "NODE_LIST_APPEND", func, line, detail, 1);
    }
}

void
prism_trace_on_parse_pass(pm_parser_t *parser) {
    g_trace_parser = parser;
    g_trace_parse_pass++;
    if (g_trace_parse_pass > 1) {
        if (g_trace_node_count > 0) {
            uint32_t limit = g_trace_node_count < PRISM_TRACE_MAX_NODES ? (g_trace_node_count + 1) : PRISM_TRACE_MAX_NODES;
            memset(g_trace_nodes, 0, limit * sizeof(g_trace_nodes[0]));
            g_trace_node_count = 0;
        }
        g_trace_call_depth = 0;
        g_last_ast_hash = UINT64_MAX;
        g_last_diags_hash = UINT64_MAX;
        g_last_comments_hash = UINT64_MAX;
        g_last_emitted_error_tail = NULL;
        g_last_emitted_warning_tail = NULL;
        char detail[96];
        uint64_t pass_len = (parser != NULL && parser->end >= parser->start) ? (uint64_t)(parser->end - parser->start) : 0;
        snprintf(detail, sizeof(detail), "{\"pass\":%u,\"src_len\":%" PRIu64 "}", g_trace_parse_pass, pass_len);
        prism_trace_emit_event(parser, "STREAM_PASS", "pm_parse_stream", 0, detail, 1);
    }
}

#define PRISM_TRACE_MAX_SCOPES 16
#define PRISM_TRACE_MAX_SCOPE_LOCALS 64

typedef struct {
    uint8_t *bytes;
    size_t len;
} prism_trace_bytes_t;

typedef struct {
    uint8_t forwarding;
    size_t locals_count;
    prism_trace_bytes_t locals[PRISM_TRACE_MAX_SCOPE_LOCALS];
} prism_trace_scope_opt_t;

typedef struct {
    int any_active;
    char encoding[64];
    char ruby_ver[32];
    char filepath[256];
    int32_t line;
    int has_line;
    uint8_t cmd_flags;
    int main_script;
    int partial_script;
    int freeze;
    int attach_comments;
    int encoding_locked;
    int has_frozen_string_literal;
    int frozen_string_literal;
    int stream_mode;
    int shebang_cb;
    int has_stack_budget;
    size_t stack_budget;
    size_t scopes_count;
    prism_trace_scope_opt_t scopes[PRISM_TRACE_MAX_SCOPES];
} prism_trace_options_t;

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t pos;
    bool eof;
} prism_trace_stream_t;

static char *
trace_stream_fgets(char *buf, int n, void *vp) {
    prism_trace_stream_t *s = (prism_trace_stream_t *) vp;
    if (n <= 0) return NULL;
    if (s->pos >= s->size) {
        s->eof = true;
        return NULL;
    }
    size_t count = 0;
    size_t limit = (size_t) (n - 1);
    while (count < limit && s->pos < s->size) {
        uint8_t ch = s->data[s->pos++];
        buf[count++] = (char) ch;
        if (ch == '\n') break;
    }
    if (count < limit && (count == 0 || buf[count - 1] != '\n') && s->pos >= s->size) {
        s->eof = true;
    }
    buf[count] = '\0';
    return buf;
}

static int
trace_stream_feof(void *vp) {
    return ((const prism_trace_stream_t *) vp)->eof ? 1 : 0;
}

static void
trace_shebang_cb(pm_options_t *options, const uint8_t *source, size_t length, void *shebang_data) {
    (void) options;
    (void) source;
    (void) length;
    (void) shebang_data;
}

static int
hex_nibble_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static char *
percent_decode_slice(const char *src, size_t src_len, size_t *out_len) {
    char *dst = (char *) malloc(src_len + 1);
    if (dst == NULL) {
        *out_len = 0;
        return NULL;
    }
    size_t w = 0;
    for (size_t i = 0; i < src_len; i++) {
        char c = src[i];
        if (c == '+') {
            dst[w++] = ' ';
        } else if (c == '%' && i + 2 < src_len) {
            int hi = hex_nibble_val(src[i + 1]);
            int lo = hex_nibble_val(src[i + 2]);
            if (hi >= 0 && lo >= 0) {
                dst[w++] = (char) ((hi << 4) | lo);
                i += 2;
            } else {
                dst[w++] = c;
            }
        } else {
            dst[w++] = c;
        }
    }
    dst[w] = '\0';
    *out_len = w;
    return dst;
}

static int
b64url_char_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}

static uint8_t *
b64url_decode_slice(const char *src, size_t src_len, size_t *out_len) {
    uint8_t *vals = (uint8_t *) malloc(src_len + 1);
    if (vals == NULL) {
        *out_len = 0;
        return NULL;
    }
    size_t n = 0;
    for (size_t i = 0; i < src_len; i++) {
        char c = src[i];
        if (c == '=' || c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        int v = b64url_char_val(c);
        if (v >= 0) vals[n++] = (uint8_t) v;
    }
    size_t cap = (n * 3) / 4 + 2;
    uint8_t *out = (uint8_t *) malloc(cap);
    if (out == NULL) {
        free(vals);
        *out_len = 0;
        return NULL;
    }
    size_t w = 0;
    size_t i = 0;
    while (i + 4 <= n) {
        out[w++] = (uint8_t) ((vals[i] << 2) | (vals[i + 1] >> 4));
        out[w++] = (uint8_t) (((vals[i + 1] & 0x0f) << 4) | (vals[i + 2] >> 2));
        out[w++] = (uint8_t) (((vals[i + 2] & 0x03) << 6) | vals[i + 3]);
        i += 4;
    }
    size_t rem = n - i;
    if (rem == 2) {
        out[w++] = (uint8_t) ((vals[i] << 2) | (vals[i + 1] >> 4));
    } else if (rem == 3) {
        out[w++] = (uint8_t) ((vals[i] << 2) | (vals[i + 1] >> 4));
        out[w++] = (uint8_t) (((vals[i + 1] & 0x0f) << 4) | (vals[i + 2] >> 2));
    }
    free(vals);
    *out_len = w;
    return out;
}

static int
opt_val_is_truthy(const char *v) {
    return (v != NULL && (strcmp(v, "1") == 0 || strcmp(v, "true") == 0 || strcmp(v, "yes") == 0 || strcmp(v, "on") == 0));
}

static void
parse_scopes_param(prism_trace_options_t *opts, const char *val, size_t val_len) {
    if (val == NULL || val_len == 0) return;
    const char *p = val;
    const char *end = val + val_len;
    while (opts->scopes_count < PRISM_TRACE_MAX_SCOPES) {
        const char *semi = (const char *) memchr(p, ';', (size_t) (end - p));
        const char *seg_end = semi != NULL ? semi : end;

        prism_trace_scope_opt_t *sc = &opts->scopes[opts->scopes_count++];
        memset(sc, 0, sizeof(*sc));
        opts->any_active = 1;

        const char *colon = (const char *) memchr(p, ':', (size_t) (seg_end - p));
        const char *locals_p = p;
        if (colon != NULL) {
            for (const char *f = p; f < colon; f++) {
                switch (*f) {
                    case 'p': case '*': sc->forwarding |= PM_OPTIONS_SCOPE_FORWARDING_POSITIONALS; break;
                    case 'k':           sc->forwarding |= PM_OPTIONS_SCOPE_FORWARDING_KEYWORDS; break;
                    case 'b': case '&': sc->forwarding |= PM_OPTIONS_SCOPE_FORWARDING_BLOCK; break;
                    case 'a': case '.': sc->forwarding |= PM_OPTIONS_SCOPE_FORWARDING_ALL; break;
                    default: break;
                }
            }
            locals_p = colon + 1;
        }

        if (locals_p < seg_end) {
            const char *lp = locals_p;
            while (sc->locals_count < PRISM_TRACE_MAX_SCOPE_LOCALS) {
                const char *comma = (const char *) memchr(lp, ',', (size_t) (seg_end - lp));
                const char *tok_end = comma != NULL ? comma : seg_end;
                size_t tok_len = (size_t) (tok_end - lp);

                uint8_t *dec_bytes = NULL;
                size_t dec_len = 0;
                if (tok_len >= 1 && lp[0] == '~') {
                    dec_bytes = b64url_decode_slice(lp + 1, tok_len - 1, &dec_len);
                } else {
                    dec_bytes = (uint8_t *) malloc(tok_len > 0 ? tok_len : 1);
                    if (dec_bytes != NULL && tok_len > 0) {
                        memcpy(dec_bytes, lp, tok_len);
                    }
                    dec_len = tok_len;
                }
                if (dec_bytes != NULL) {
                    sc->locals[sc->locals_count].bytes = dec_bytes;
                    sc->locals[sc->locals_count].len = dec_len;
                    sc->locals_count++;
                }

                if (comma == NULL) break;
                lp = comma + 1;
            }
        }

        if (semi == NULL) break;
        p = semi + 1;
    }
}

static void
prism_trace_options_parse(prism_trace_options_t *opts, const char *query, size_t query_len) {
    memset(opts, 0, sizeof(*opts));
    opts->line = 1;
    if (query == NULL || query_len == 0) return;

    const char *p = query;
    const char *end = query + query_len;
    if (p < end && *p == '?') p++;

    while (p < end) {
        const char *amp = (const char *) memchr(p, '&', (size_t) (end - p));
        const char *pair_end = amp != NULL ? amp : end;
        if (pair_end > p) {
            const char *eq = (const char *) memchr(p, '=', (size_t) (pair_end - p));
            const char *k_raw = p;
            size_t k_raw_len = eq != NULL ? (size_t) (eq - p) : (size_t) (pair_end - p);
            const char *v_raw = eq != NULL ? (eq + 1) : "";
            size_t v_raw_len = eq != NULL ? (size_t) (pair_end - (eq + 1)) : 0;

            size_t k_len = 0, v_len = 0;
            char *k = percent_decode_slice(k_raw, k_raw_len, &k_len);
            char *v = percent_decode_slice(v_raw, v_raw_len, &v_len);

            if (k != NULL && v != NULL) {
                if ((strcmp(k, "enc") == 0 || strcmp(k, "encoding") == 0) && v_len > 0) {
                    snprintf(opts->encoding, sizeof(opts->encoding), "%s", v);
                    opts->any_active = 1;
                } else if (strcmp(k, "ruby_ver") == 0 && v_len > 0) {
                    snprintf(opts->ruby_ver, sizeof(opts->ruby_ver), "%s", v);
                    opts->any_active = 1;
                } else if (strcmp(k, "filepath") == 0 && v_len > 0) {
                    snprintf(opts->filepath, sizeof(opts->filepath), "%s", v);
                    opts->any_active = 1;
                } else if (strcmp(k, "line") == 0 && v_len > 0) {
                    char *endptr = NULL;
                    long long parsed_line = strtoll(v, &endptr, 10);
                    if (endptr != v) {
                        if (parsed_line < (long long) INT32_MIN) parsed_line = (long long) INT32_MIN;
                        if (parsed_line > (long long) INT32_MAX) parsed_line = (long long) INT32_MAX;
                        opts->line = (int32_t) parsed_line;
                        opts->has_line = 1;
                        if (opts->line != 1) opts->any_active = 1;
                    }
                } else if (strcmp(k, "cmd") == 0 && v_len > 0) {
                    for (size_t ci = 0; ci < v_len; ci++) {
                        switch (v[ci]) {
                            case 'a': opts->cmd_flags |= PM_OPTIONS_COMMAND_LINE_A; break;
                            case 'e': opts->cmd_flags |= PM_OPTIONS_COMMAND_LINE_E; break;
                            case 'l': opts->cmd_flags |= PM_OPTIONS_COMMAND_LINE_L; break;
                            case 'n': opts->cmd_flags |= PM_OPTIONS_COMMAND_LINE_N; break;
                            case 'p': opts->cmd_flags |= PM_OPTIONS_COMMAND_LINE_P; break;
                            case 'x': opts->cmd_flags |= PM_OPTIONS_COMMAND_LINE_X; break;
                            default: break;
                        }
                    }
                    if (opts->cmd_flags != 0) opts->any_active = 1;
                } else if (strcmp(k, "main") == 0) {
                    if (opt_val_is_truthy(v)) { opts->main_script = 1; opts->any_active = 1; }
                } else if (strcmp(k, "partial") == 0) {
                    if (opt_val_is_truthy(v)) { opts->partial_script = 1; opts->any_active = 1; }
                } else if (strcmp(k, "freeze") == 0) {
                    if (opt_val_is_truthy(v)) { opts->freeze = 1; opts->any_active = 1; }
                } else if (strcmp(k, "comments") == 0) {
                    if (opt_val_is_truthy(v)) { opts->attach_comments = 1; opts->any_active = 1; }
                } else if (strcmp(k, "enc_lock") == 0) {
                    if (opt_val_is_truthy(v)) { opts->encoding_locked = 1; opts->any_active = 1; }
                } else if (strcmp(k, "frozen_lit") == 0 && v_len > 0) {
                    if (opt_val_is_truthy(v)) {
                        opts->has_frozen_string_literal = 1;
                        opts->frozen_string_literal = 1;
                        opts->any_active = 1;
                    } else if (strcmp(v, "0") == 0 || strcmp(v, "false") == 0 || strcmp(v, "no") == 0 || strcmp(v, "off") == 0) {
                        opts->has_frozen_string_literal = 1;
                        opts->frozen_string_literal = 0;
                        opts->any_active = 1;
                    }
                } else if (strcmp(k, "stream") == 0) {
                    if (opt_val_is_truthy(v)) { opts->stream_mode = 1; opts->any_active = 1; }
                } else if (strcmp(k, "shebang_cb") == 0) {
                    if (opt_val_is_truthy(v)) { opts->shebang_cb = 1; opts->any_active = 1; }
                } else if (strcmp(k, "budget") == 0 && v_len > 0) {
                    if (strcmp(v, "SIZE_MAX") == 0 || strcmp(v, "max") == 0 || strcmp(v, "-1") == 0) {
                        opts->has_stack_budget = 1;
                        opts->stack_budget = SIZE_MAX;
                        opts->any_active = 1;
                    } else {
                        char *endptr = NULL;
                        unsigned long long bval = strtoull(v, &endptr, 10);
                        if (endptr != v) {
                            opts->has_stack_budget = 1;
                            opts->stack_budget = (size_t) bval;
                            opts->any_active = 1;
                        }
                    }
                } else if (strcmp(k, "scopes") == 0 && v_len > 0) {
                    opts->scopes_count = 0;
                    parse_scopes_param(opts, v, v_len);
                }
            }
            free(k);
            free(v);
        }
        if (amp == NULL) break;
        p = amp + 1;
    }
}

static void
prism_trace_options_free(prism_trace_options_t *opts) {
    if (opts == NULL) return;
    for (size_t i = 0; i < opts->scopes_count; i++) {
        for (size_t j = 0; j < opts->scopes[i].locals_count; j++) {
            free(opts->scopes[i].locals[j].bytes);
            opts->scopes[i].locals[j].bytes = NULL;
        }
    }
}

static void
emit_meta_options_json(pm_buffer_t *out, const prism_trace_options_t *opts, const char *raw_query, size_t raw_query_len) {
    if (opts == NULL || !opts->any_active) return;
    if (raw_query != NULL && raw_query_len > 0) {
        PM_BUFFER_APPEND_LITERAL(out, ",\"options_query\":");
        buf_append_json_escaped(out, (const uint8_t *) raw_query, raw_query_len);
    }
    PM_BUFFER_APPEND_LITERAL(out, ",\"options\":{");
    int first = 1;
    #define META_OPT_SEP() do { if (!first) pm_buffer_append_byte(out, ','); first = 0; } while (0)

    if (opts->encoding[0] != '\0') {
        META_OPT_SEP();
        PM_BUFFER_APPEND_LITERAL(out, "\"enc\":");
        buf_append_cstr_json_escaped(out, opts->encoding);
    }
    if (opts->ruby_ver[0] != '\0') {
        META_OPT_SEP();
        PM_BUFFER_APPEND_LITERAL(out, "\"ruby_ver\":");
        buf_append_cstr_json_escaped(out, opts->ruby_ver);
    }
    if (opts->line != 1 || opts->has_line) {
        META_OPT_SEP();
        pm_buffer_append_format(out, "\"line\":%" PRId32, opts->line);
    }
    if (opts->cmd_flags != 0) {
        char cmd_str[8];
        size_t ci = 0;
        if (opts->cmd_flags & PM_OPTIONS_COMMAND_LINE_A) cmd_str[ci++] = 'a';
        if (opts->cmd_flags & PM_OPTIONS_COMMAND_LINE_E) cmd_str[ci++] = 'e';
        if (opts->cmd_flags & PM_OPTIONS_COMMAND_LINE_L) cmd_str[ci++] = 'l';
        if (opts->cmd_flags & PM_OPTIONS_COMMAND_LINE_N) cmd_str[ci++] = 'n';
        if (opts->cmd_flags & PM_OPTIONS_COMMAND_LINE_P) cmd_str[ci++] = 'p';
        if (opts->cmd_flags & PM_OPTIONS_COMMAND_LINE_X) cmd_str[ci++] = 'x';
        cmd_str[ci] = '\0';
        META_OPT_SEP();
        pm_buffer_append_format(out, "\"cmd\":\"%s\"", cmd_str);
    }
    if (opts->main_script)     { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"main\":true"); }
    if (opts->partial_script)  { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"partial\":true"); }
    if (opts->freeze)          { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"freeze\":true"); }
    if (opts->attach_comments) { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"comments\":true"); }
    if (opts->encoding_locked) { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"enc_lock\":true"); }
    if (opts->has_frozen_string_literal) {
        META_OPT_SEP();
        pm_buffer_append_format(out, "\"frozen_lit\":%s", opts->frozen_string_literal ? "true" : "false");
    }
    if (opts->stream_mode)     { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"stream\":true"); }
    if (opts->filepath[0] != '\0') {
        META_OPT_SEP();
        PM_BUFFER_APPEND_LITERAL(out, "\"filepath\":");
        buf_append_cstr_json_escaped(out, opts->filepath);
    }
    if (opts->shebang_cb)      { META_OPT_SEP(); PM_BUFFER_APPEND_LITERAL(out, "\"shebang_cb\":true"); }
    if (opts->has_stack_budget) {
        META_OPT_SEP();
        if (opts->stack_budget == SIZE_MAX) {
            PM_BUFFER_APPEND_LITERAL(out, "\"budget\":\"SIZE_MAX\"");
        } else {
            pm_buffer_append_format(out, "\"budget\":\"%zu\"", opts->stack_budget);
        }
    }
    if (opts->scopes_count > 0) {
        META_OPT_SEP();
        PM_BUFFER_APPEND_LITERAL(out, "\"scopes\":[");
        for (size_t i = 0; i < opts->scopes_count; i++) {
            if (i > 0) pm_buffer_append_byte(out, ',');
            char fwd_str[8];
            size_t fi = 0;
            uint8_t fw = opts->scopes[i].forwarding;
            if (fw & PM_OPTIONS_SCOPE_FORWARDING_POSITIONALS) fwd_str[fi++] = 'p';
            if (fw & PM_OPTIONS_SCOPE_FORWARDING_KEYWORDS)    fwd_str[fi++] = 'k';
            if (fw & PM_OPTIONS_SCOPE_FORWARDING_BLOCK)       fwd_str[fi++] = 'b';
            if (fw & PM_OPTIONS_SCOPE_FORWARDING_ALL)         fwd_str[fi++] = 'a';
            fwd_str[fi] = '\0';
            pm_buffer_append_format(out, "{\"forwarding\":\"%s\",\"locals\":[", fwd_str);
            for (size_t j = 0; j < opts->scopes[i].locals_count; j++) {
                if (j > 0) pm_buffer_append_byte(out, ',');
                buf_append_json_escaped(out, opts->scopes[i].locals[j].bytes, opts->scopes[i].locals[j].len);
            }
            PM_BUFFER_APPEND_LITERAL(out, "]}");
        }
        pm_buffer_append_byte(out, ']');
    }
    #undef META_OPT_SEP
    pm_buffer_append_byte(out, '}');
}

PRISM_EXPORTED_FUNCTION void
prism_trace_run_to_buffer_opts(
    pm_buffer_t *out_buf,
    const uint8_t *source,
    size_t size,
    uint32_t max_steps,
    const char *opts_query,
    size_t opts_query_len
) {
    const uint8_t *safe_source = (source != NULL) ? source : (const uint8_t *) "";
#ifdef PRISM_WASM_SANITIZE
    wasm_san_begin_run();
    uint8_t *san_source = wasm_san_alloc_input(safe_source, size);
    if (san_source != NULL) {
        safe_source = san_source;
    }
#endif

    prism_trace_options_t parsed_opts;
    prism_trace_options_parse(&parsed_opts, opts_query, opts_query_len);

    prism_trace_reset(out_buf, max_steps > 0 ? (uint64_t) max_steps : 50000);
    g_trace_input_size = (uint64_t) size;

    PM_BUFFER_APPEND_LITERAL(out_buf, "{\"meta\":true,\"prism_version\":\"" PRISM_VERSION "\",");
#ifdef PRISM_WASM_SANITIZE
    PM_BUFFER_APPEND_LITERAL(out_buf, "\"sanitized\":true,");
#endif
    PM_BUFFER_APPEND_LITERAL(out_buf, "\"source\":");
    buf_append_json_escaped(out_buf, safe_source, size);
    pm_buffer_append_format(out_buf, ",\"length\":%zu", size);
    emit_meta_options_json(out_buf, &parsed_opts, opts_query, opts_query_len);
    PM_BUFFER_APPEND_LITERAL(out_buf, "}\n");

    g_trace_xalloc_tracking = 1;

    pm_options_t *options_ptr = NULL;
#if !PRISM_TRACE_HAS_OPTIONS_NEW
    pm_options_t options_storage = { 0 };
#endif

    if (parsed_opts.any_active) {
#if PRISM_TRACE_HAS_OPTIONS_NEW
        options_ptr = pm_options_new();
#else
        options_ptr = &options_storage;
#endif
        pm_options_line_set(options_ptr, parsed_opts.line);
        pm_options_command_line_set(options_ptr, parsed_opts.cmd_flags);
        pm_options_main_script_set(options_ptr, parsed_opts.main_script != 0);
        pm_options_partial_script_set(options_ptr, parsed_opts.partial_script != 0);
        pm_options_freeze_set(options_ptr, parsed_opts.freeze != 0);
#if PRISM_TRACE_HAS_OPTIONS_ATTACH_COMMENTS
        pm_options_attach_comments_set(options_ptr, parsed_opts.attach_comments != 0);
#endif
        pm_options_encoding_locked_set(options_ptr, parsed_opts.encoding_locked != 0);

        if (parsed_opts.ruby_ver[0] != '\0') {
            pm_options_version_set(options_ptr, parsed_opts.ruby_ver, strlen(parsed_opts.ruby_ver));
        }
        if (parsed_opts.has_frozen_string_literal) {
            pm_options_frozen_string_literal_set(options_ptr, parsed_opts.frozen_string_literal != 0);
        }
        if (parsed_opts.encoding[0] != '\0') {
            pm_options_encoding_set(options_ptr, parsed_opts.encoding);
        }
        if (parsed_opts.filepath[0] != '\0') {
            pm_options_filepath_set(options_ptr, parsed_opts.filepath);
        }
        if (parsed_opts.shebang_cb) {
            pm_options_shebang_callback_set(options_ptr, trace_shebang_cb, NULL);
        }
#if PRISM_TRACE_HAS_OPTIONS_STACK_BUDGET
        if (parsed_opts.has_stack_budget) {
            pm_options_stack_budget_set(options_ptr, parsed_opts.stack_budget);
        }
#endif
        if (parsed_opts.scopes_count > 0 && pm_options_scopes_init(options_ptr, parsed_opts.scopes_count)) {
            for (size_t i = 0; i < parsed_opts.scopes_count; i++) {
#if PRISM_TRACE_HAS_OPTIONS_SCOPE_MUT
                pm_options_scope_t *scope = pm_options_scope_mut(options_ptr, i);
                pm_options_scope_init(scope, parsed_opts.scopes[i].locals_count);
                pm_options_scope_forwarding_set(scope, parsed_opts.scopes[i].forwarding);
                for (size_t j = 0; j < parsed_opts.scopes[i].locals_count; j++) {
                    pm_string_init(
                        pm_options_scope_local_mut(scope, j),
                        parsed_opts.scopes[i].locals[j].bytes,
                        parsed_opts.scopes[i].locals[j].len
                    );
                }
#else
                pm_options_scope_t *scope = &options_ptr->scopes[i];
                if (pm_options_scope_init(scope, parsed_opts.scopes[i].locals_count)) {
                    pm_options_scope_forwarding_set(scope, parsed_opts.scopes[i].forwarding);
                    for (size_t j = 0; j < parsed_opts.scopes[i].locals_count; j++) {
                        pm_string_constant_init(
                            &scope->locals[j],
                            (const char *) parsed_opts.scopes[i].locals[j].bytes,
                            parsed_opts.scopes[i].locals[j].len
                        );
                    }
                }
#endif
            }
        }
    }

    uint32_t saved_line_offsets[128];
    size_t saved_n_lines = 0;
    size_t saved_errors = 0;
    size_t saved_warnings = 0;
    size_t saved_comments = 0;
    size_t final_parsed_size = size;

#if PRISM_TRACE_HAS_ARENA
    pm_arena_t arena = { 0 };
    if (parsed_opts.stream_mode) {
#if PRISM_TRACE_HAS_SOURCE_STREAM
        prism_trace_stream_t stream_state = {
            .data = safe_source,
            .size = size,
            .pos = 0,
            .eof = false
        };
        pm_source_t *stream_src = pm_source_stream_new(&stream_state, trace_stream_fgets, trace_stream_feof);
        pm_parser_t *stream_parser = NULL;
        pm_node_t *root = pm_parse_stream(&stream_parser, &arena, stream_src, options_ptr);
        (void) root;
        final_parsed_size = pm_source_length(stream_src);

        if (!g_trace_crashed && stream_parser != NULL &&
            (compute_diags_hash(stream_parser) != g_last_diags_hash ||
             compute_comments_hash(stream_parser) != g_last_comments_hash ||
             (g_trace_node_count > 0 && compute_ast_hash(stream_parser) != g_last_ast_hash))) {
            int ast_changed = (g_trace_node_count > 0 && compute_ast_hash(stream_parser) != g_last_ast_hash) ? 1 : 0;
            prism_trace_emit_event(stream_parser, "POST_PARSE", "pm_parse_stream", 0, NULL, ast_changed);
        }

        if (stream_parser != NULL) {
            saved_errors = stream_parser->error_list.size;
            saved_warnings = stream_parser->warning_list.size;
            saved_comments = stream_parser->comment_list.size;
            saved_n_lines = stream_parser->line_offsets.size > 128 ? 128 : stream_parser->line_offsets.size;
            for (size_t i = 0; i < saved_n_lines; i++) {
                saved_line_offsets[i] = stream_parser->line_offsets.offsets[i];
            }
        }

        g_trace_buf = NULL;
        g_trace_parser = NULL;

        if (stream_parser != NULL) {
            pm_parser_free(stream_parser);
        }
        pm_arena_cleanup(&arena);
        pm_source_free(stream_src);
#endif
    } else {
        pm_parser_t parser;
        pm_parser_init(&arena, &parser, safe_source, size, options_ptr);
        g_trace_parser = &parser;

        pm_node_t *root = pm_parse(&parser);
        (void) root;

        if (!g_trace_crashed &&
            (compute_diags_hash(&parser) != g_last_diags_hash ||
             compute_comments_hash(&parser) != g_last_comments_hash ||
             (g_trace_node_count > 0 && compute_ast_hash(&parser) != g_last_ast_hash))) {
            int ast_changed = (g_trace_node_count > 0 && compute_ast_hash(&parser) != g_last_ast_hash) ? 1 : 0;
            prism_trace_emit_event(&parser, "POST_PARSE", "pm_parse", 0, NULL, ast_changed);
        }

        saved_errors = parser.error_list.size;
        saved_warnings = parser.warning_list.size;
        saved_comments = parser.comment_list.size;
        saved_n_lines = parser.line_offsets.size > 128 ? 128 : parser.line_offsets.size;
        for (size_t i = 0; i < saved_n_lines; i++) {
            saved_line_offsets[i] = parser.line_offsets.offsets[i];
        }

        g_trace_buf = NULL;
        g_trace_parser = NULL;

        pm_parser_cleanup(&parser);
        pm_arena_cleanup(&arena);
    }
#else
    pm_parser_t parser;
    pm_buffer_t stream_buf = { 0 };
    pm_node_t *root = NULL;

    if (parsed_opts.stream_mode) {
        prism_trace_stream_t stream_state = {
            .data = safe_source,
            .size = size,
            .pos = 0,
            .eof = false
        };
        root = pm_parse_stream(&parser, &stream_buf, &stream_state, trace_stream_fgets, trace_stream_feof, options_ptr);
        final_parsed_size = pm_buffer_length(&stream_buf);
    } else {
        pm_parser_init(&parser, safe_source, size, options_ptr);
        g_trace_parser = &parser;
        root = pm_parse(&parser);
    }

    if (!g_trace_crashed &&
        (compute_diags_hash(&parser) != g_last_diags_hash ||
         compute_comments_hash(&parser) != g_last_comments_hash ||
         (g_trace_node_count > 0 && compute_ast_hash(&parser) != g_last_ast_hash))) {
        int ast_changed = (g_trace_node_count > 0 && compute_ast_hash(&parser) != g_last_ast_hash) ? 1 : 0;
        prism_trace_emit_event(&parser, "POST_PARSE", parsed_opts.stream_mode ? "pm_parse_stream" : "pm_parse", 0, NULL, ast_changed);
    }

    saved_errors = parser.error_list.size;
    saved_warnings = parser.warning_list.size;
    saved_comments = parser.comment_list.size;
#if PRISM_TRACE_HAS_LINE_OFFSETS
    saved_n_lines = parser.line_offsets.size > 128 ? 128 : parser.line_offsets.size;
    for (size_t i = 0; i < saved_n_lines; i++) {
        saved_line_offsets[i] = parser.line_offsets.offsets[i];
    }
#else
    saved_n_lines = parser.newline_list.size > 128 ? 128 : parser.newline_list.size;
    for (size_t i = 0; i < saved_n_lines; i++) {
        saved_line_offsets[i] = (uint32_t) parser.newline_list.offsets[i];
    }
#endif

    g_trace_buf = NULL;
    g_trace_parser = NULL;

    if (root != NULL) {
        pm_node_destroy(&parser, root);
    }
    pm_parser_free(&parser);
    if (parsed_opts.stream_mode) {
        pm_buffer_free(&stream_buf);
    }
#endif

    if (options_ptr != NULL) {
        pm_options_free(options_ptr);
    }

    g_trace_xalloc_tracking = 0;
    g_trace_crash_out_buf = NULL;
    prism_trace_options_free(&parsed_opts);
#ifdef PRISM_WASM_SANITIZE
    wasm_san_free_input(san_source);
    wasm_san_finish_run();
#endif

    if (!g_trace_crashed) {
        pm_buffer_append_format(
            out_buf,
            "{\"step\":%" PRIu64 ",\"kind\":\"TEARDOWN\",\"func\":\"%s\",\"line\":0,"
            "\"prev\":[%zu,%zu,\"PM_TOKEN_EOF\"],\"curr\":[%zu,%zu,\"PM_TOKEN_EOF\"],"
            "\"next_start\":-1,\"heredoc_end\":-1,\"lex_state\":\"NONE\","
            "\"lex_modes\":[],\"contexts\":[],\"call_stack\":[],\"line_offsets\":[",
            g_trace_step++,
#if PRISM_TRACE_HAS_ARENA
            parsed_opts.stream_mode
                ? "pm_parser_free + pm_arena_cleanup + pm_source_free"
                : "pm_parser_cleanup + pm_arena_cleanup",
#else
            "pm_node_destroy + pm_parser_free",
#endif
            final_parsed_size, final_parsed_size, final_parsed_size, final_parsed_size
        );
        for (size_t i = 0; i < saved_n_lines; i++) {
            if (i > 0) pm_buffer_append_byte(out_buf, ',');
            pm_buffer_append_format(out_buf, "%" PRIu32, saved_line_offsets[i]);
        }
        pm_buffer_append_format(
            out_buf,
            "],\"errors\":%zu,\"warnings\":%zu,\"comments_count\":%zu,"
            "\"mem\":{\"ast\":[0,0,0],\"meta\":[0,0,0],\"scratch\":[0,0,0],\"lo\":[0,0],\"cp\":[0,0],"
            "\"xalloc\":[%zu,%zu,%zu,%zu]},"
            "\"detail\":{\"leaked_bytes\":%zu,\"leaked_blocks\":%zu,\"peak_bytes\":%zu,\"total_bytes\":%zu,\"alloc_count\":%zu,\"free_count\":%zu},"
            "\"ast\":[]}\n",
            saved_errors,
            saved_warnings,
            saved_comments,
            g_trace_xalloc_live_bytes, g_trace_xalloc_peak_bytes,
            g_trace_xalloc_alloc_count, g_trace_xalloc_free_count,
            g_trace_xalloc_live_bytes, g_trace_xalloc_live_blocks,
            g_trace_xalloc_peak_bytes, g_trace_xalloc_total_bytes,
            g_trace_xalloc_alloc_count, g_trace_xalloc_free_count
        );
    }

    pm_buffer_append_format(
        out_buf,
        "{\"summary\":true,\"leaked_bytes\":%zu,\"leaked_blocks\":%zu,\"peak_bytes\":%zu,\"total_bytes\":%zu,\"alloc_count\":%zu,\"free_count\":%zu}\n",
        g_trace_xalloc_live_bytes,
        g_trace_xalloc_live_blocks,
        g_trace_xalloc_peak_bytes,
        g_trace_xalloc_total_bytes,
        g_trace_xalloc_alloc_count,
        g_trace_xalloc_free_count
    );
}

PRISM_EXPORTED_FUNCTION void
prism_trace_run_to_buffer(
    pm_buffer_t *out_buf,
    const uint8_t *source,
    size_t size,
    uint32_t max_steps
) {
    prism_trace_run_to_buffer_opts(out_buf, source, size, max_steps, NULL, 0);
}
