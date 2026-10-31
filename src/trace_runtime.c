#include "trace_runtime.h"
#include "prism.h"

pm_parser_t *g_trace_parser = NULL;
pm_buffer_t *g_trace_buf = NULL;
uint64_t g_trace_step = 0;
uint64_t g_trace_max_steps = 50000;
const pm_node_t *g_trace_nodes[PRISM_TRACE_MAX_NODES];
uint32_t g_trace_node_count = 0;
const char *g_trace_call_stack[PRISM_TRACE_MAX_CALL_STACK];
int g_trace_call_depth = 0;
int g_trace_in_hook = 0;
int g_trace_crashed = 0;
static uint64_t g_last_ast_hash = 0;
static prism_trace_crash_cb_t g_trace_crash_cb = NULL;

void
prism_trace_set_crash_cb(prism_trace_crash_cb_t cb) {
    g_trace_crash_cb = cb;
}

void
prism_trace_reset(pm_buffer_t *buf, uint64_t max_steps) {
    g_trace_parser = NULL;
    g_trace_buf = buf;
    g_trace_step = 0;
    g_trace_max_steps = max_steps;
    memset(g_trace_nodes, 0, sizeof(g_trace_nodes));
    g_trace_node_count = 0;
    g_trace_call_depth = 0;
    g_trace_in_hook = 0;
    g_trace_crashed = 0;
    g_last_ast_hash = 0;
}

static void
buf_append_json_escaped(pm_buffer_t *buf, const uint8_t *str, size_t len) {
    pm_buffer_append_byte(buf, '"');
    pm_buffer_append_source(buf, str, len, PM_BUFFER_ESCAPING_JSON);
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

static const char *
context_name(pm_context_t ctx) {
    switch (ctx) {
        case PM_CONTEXT_NONE: return "NONE";
        case PM_CONTEXT_BEGIN: return "BEGIN";
        case PM_CONTEXT_BEGIN_ENSURE: return "BEGIN_ENSURE";
        case PM_CONTEXT_BEGIN_ELSE: return "BEGIN_ELSE";
        case PM_CONTEXT_BEGIN_RESCUE: return "BEGIN_RESCUE";
        case PM_CONTEXT_BLOCK_BRACES: return "BLOCK_BRACES";
        case PM_CONTEXT_BLOCK_KEYWORDS: return "BLOCK_KEYWORDS";
        case PM_CONTEXT_BLOCK_ENSURE: return "BLOCK_ENSURE";
        case PM_CONTEXT_BLOCK_ELSE: return "BLOCK_ELSE";
        case PM_CONTEXT_BLOCK_PARAMETERS: return "BLOCK_PARAMETERS";
        case PM_CONTEXT_BLOCK_RESCUE: return "BLOCK_RESCUE";
        case PM_CONTEXT_CASE_WHEN: return "CASE_WHEN";
        case PM_CONTEXT_CASE_IN: return "CASE_IN";
        case PM_CONTEXT_CLASS: return "CLASS";
        case PM_CONTEXT_CLASS_ENSURE: return "CLASS_ENSURE";
        case PM_CONTEXT_CLASS_ELSE: return "CLASS_ELSE";
        case PM_CONTEXT_CLASS_RESCUE: return "CLASS_RESCUE";
        case PM_CONTEXT_DEF: return "DEF";
        case PM_CONTEXT_DEF_ENSURE: return "DEF_ENSURE";
        case PM_CONTEXT_DEF_ELSE: return "DEF_ELSE";
        case PM_CONTEXT_DEF_RESCUE: return "DEF_RESCUE";
        case PM_CONTEXT_DEF_PARAMS: return "DEF_PARAMS";
        case PM_CONTEXT_DEFINED: return "DEFINED";
        case PM_CONTEXT_DEFAULT_PARAMS: return "DEFAULT_PARAMS";
        case PM_CONTEXT_ELSE: return "ELSE";
        case PM_CONTEXT_ELSIF: return "ELSIF";
        case PM_CONTEXT_EMBEXPR: return "EMBEXPR";
        case PM_CONTEXT_FOR: return "FOR";
        case PM_CONTEXT_FOR_INDEX: return "FOR_INDEX";
        case PM_CONTEXT_IF: return "IF";
        case PM_CONTEXT_LAMBDA_BRACES: return "LAMBDA_BRACES";
        case PM_CONTEXT_LAMBDA_DO_END: return "LAMBDA_DO_END";
        case PM_CONTEXT_LAMBDA_ENSURE: return "LAMBDA_ENSURE";
        case PM_CONTEXT_LAMBDA_ELSE: return "LAMBDA_ELSE";
        case PM_CONTEXT_LAMBDA_RESCUE: return "LAMBDA_RESCUE";
        case PM_CONTEXT_LOOP_PREDICATE: return "LOOP_PREDICATE";
        case PM_CONTEXT_MAIN: return "MAIN";
        case PM_CONTEXT_MODULE: return "MODULE";
        case PM_CONTEXT_MODULE_ENSURE: return "MODULE_ENSURE";
        case PM_CONTEXT_MODULE_ELSE: return "MODULE_ELSE";
        case PM_CONTEXT_MODULE_RESCUE: return "MODULE_RESCUE";
        case PM_CONTEXT_MULTI_TARGET: return "MULTI_TARGET";
        case PM_CONTEXT_PARENS: return "PARENS";
        case PM_CONTEXT_POSTEXE: return "POSTEXE";
        case PM_CONTEXT_PREDICATE: return "PREDICATE";
        case PM_CONTEXT_PREEXE: return "PREEXE";
        case PM_CONTEXT_RESCUE_MODIFIER: return "RESCUE_MODIFIER";
        case PM_CONTEXT_SCLASS: return "SCLASS";
        case PM_CONTEXT_SCLASS_ENSURE: return "SCLASS_ENSURE";
        case PM_CONTEXT_SCLASS_ELSE: return "SCLASS_ELSE";
        case PM_CONTEXT_SCLASS_RESCUE: return "SCLASS_RESCUE";
        case PM_CONTEXT_TERNARY: return "TERNARY";
        case PM_CONTEXT_UNLESS: return "UNLESS";
        case PM_CONTEXT_UNTIL: return "UNTIL";
        case PM_CONTEXT_WHILE: return "WHILE";
        case PM_CONTEXT_MAXIMUM: return "MAX";
    }
    return "UNKNOWN";
}

typedef struct {
    uint32_t ids[256];
    size_t count;
} direct_children_t;

static pm_visit_result_t
collect_direct_child(const pm_node_t *child, void *data) {
    direct_children_t *dc = (direct_children_t *) data;
    if (child != NULL && dc->count < 256) {
        dc->ids[dc->count++] = child->node_id;
    }
    return PM_VISIT_SKIP;
}

static uint64_t
compute_ast_hash(void) {
    uint64_t h = 14695981039346656037ULL;
    for (uint32_t i = 1; i <= g_trace_node_count; i++) {
        const pm_node_t *n = g_trace_nodes[i];
        if (n == NULL) continue;
        h ^= (uint64_t)n->node_id; h *= 1099511628211ULL;
        h ^= (uint64_t)n->location.start; h *= 1099511628211ULL;
        h ^= (uint64_t)n->location.length; h *= 1099511628211ULL;
        direct_children_t dc = { .count = 0 };
        pm_visit_child_nodes(n, collect_direct_child, &dc);
        h ^= (uint64_t)dc.count; h *= 1099511628211ULL;
        for (size_t j = 0; j < dc.count; j++) {
            h ^= (uint64_t)dc.ids[j]; h *= 1099511628211ULL;
        }
    }
    return h;
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

    g_trace_in_hook = 1;
    pm_buffer_t *out = g_trace_buf;

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
        pm_buffer_append_format(out, "\"%s\"", context_name(cn->context));
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

    // Line offsets (up to 128)
    PM_BUFFER_APPEND_LITERAL(out, ",\"line_offsets\":[");
    size_t n_lines = parser->line_offsets.size;
    if (n_lines > 128) n_lines = 128;
    for (size_t i = 0; i < n_lines; i++) {
        if (i > 0) pm_buffer_append_byte(out, ',');
        pm_buffer_append_format(out, "%" PRIu32, parser->line_offsets.offsets[i]);
    }
    pm_buffer_append_byte(out, ']');

    pm_buffer_append_format(out, ",\"errors\":%zu", parser->error_list.size);

    size_t ast_u = 0, ast_c = 0, ast_b = 0;
    size_t meta_u = 0, meta_c = 0, meta_b = 0;
    size_t scr_u = 0, scr_c = 0, scr_b = 0;
    measure_arena(parser->arena, &ast_u, &ast_c, &ast_b);
    measure_arena(&parser->metadata_arena, &meta_u, &meta_c, &meta_b);
    measure_arena(&parser->scratch_arena, &scr_u, &scr_c, &scr_b);

    pm_buffer_append_format(
        out,
        ",\"mem\":{\"ast\":[%zu,%zu,%zu],\"meta\":[%zu,%zu,%zu],\"scratch\":[%zu,%zu,%zu],\"lo\":[%zu,%zu],\"cp\":[%" PRIu32 ",%" PRIu32 "]}",
        ast_u, ast_c, ast_b,
        meta_u, meta_c, meta_b,
        scr_u, scr_c, scr_b,
        parser->line_offsets.size, parser->line_offsets.capacity,
        parser->constant_pool.size, parser->constant_pool.capacity
    );

    if (detail_json != NULL) {
        pm_buffer_append_format(out, ",\"detail\":%s", detail_json);
    }

    if (include_ast) {
        g_last_ast_hash = compute_ast_hash();
        uint64_t src_len = (parser->end >= parser->start) ? (uint64_t)(parser->end - parser->start) : 0;
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

            uint32_t wrapped_end = n->location.start + n->location.length;
            int underflow = ((uint64_t)n->location.start + (uint64_t)n->location.length > src_len) ? 1 : 0;

            pm_buffer_append_format(out,
                    "{\"id\":%" PRIu32 ",\"type\":\"%s\",\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"len\":%" PRIu32 ",\"underflow\":%s,\"children\":[",
                    n->node_id, tname, n->location.start, wrapped_end, n->location.length,
                    underflow ? "true" : "false");
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

void
prism_trace_emit_crash(const char *reason, const char *expr, const char *file, int line, const char *func) {
    if (g_trace_crashed) return;
    g_trace_crashed = 1;
    g_trace_in_hook = 0;

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
    }

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
    uint64_t cur_hash = compute_ast_hash();
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
        char detail[320];
        const char *tname = pm_node_type(node->type);
        if (strncmp(tname, "PM_", 3) == 0) tname += 3;
        snprintf(detail, sizeof(detail),
                 "{\"node_id\":%" PRIu32 ",\"node_type\":\"%s\",\"start\":%" PRIu32 ",\"end\":%" PRIu32 ",\"len\":%" PRIu32 "}",
                 node->node_id, tname, node->location.start, node->location.start + node->location.length, node->location.length);
        prism_trace_emit_event(g_trace_parser, "NODE_NEW", func, line, detail, 1);
    }
    return node;
}

void
prism_trace_node_list_append(const pm_node_list_t *list, const pm_node_t *node, const char *func, int line) {
    if (node != NULL && g_trace_parser != NULL) {
        char detail[256];
        const char *tname = pm_node_type(node->type);
        if (strncmp(tname, "PM_", 3) == 0) tname += 3;
        snprintf(detail, sizeof(detail),
                 "{\"node_id\":%" PRIu32 ",\"node_type\":\"%s\",\"list_size\":%zu}",
                 node->node_id, tname, list ? list->size : 0);
        prism_trace_emit_event(g_trace_parser, "NODE_LIST_APPEND", func, line, detail, 1);
    }
}

PRISM_EXPORTED_FUNCTION void
prism_trace_run_to_buffer(
    pm_buffer_t *out_buf,
    const uint8_t *source,
    size_t size,
    uint32_t max_steps
) {
    prism_trace_reset(out_buf, max_steps > 0 ? (uint64_t) max_steps : 50000);

    PM_BUFFER_APPEND_LITERAL(out_buf, "{\"meta\":true,\"source\":");
    buf_append_json_escaped(out_buf, source, size);
    pm_buffer_append_format(out_buf, ",\"length\":%zu}\n", size);

    pm_arena_t arena = { 0 };
    pm_parser_t parser;
    pm_parser_init(&arena, &parser, source, size, NULL);
    g_trace_parser = &parser;

    pm_node_t *root = pm_parse(&parser);
    (void) root;

    g_trace_buf = NULL;
    g_trace_parser = NULL;

    pm_parser_cleanup(&parser);
    pm_arena_cleanup(&arena);
}
