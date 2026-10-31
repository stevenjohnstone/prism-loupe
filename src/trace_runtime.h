#ifndef PRISM_TRACE_RUNTIME_H
#define PRISM_TRACE_RUNTIME_H

#include "trace_compat.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#ifndef PM_BUFFER_APPEND_LITERAL
#define PM_BUFFER_APPEND_LITERAL(buffer, literal) pm_buffer_append_string((buffer), "" literal, sizeof(literal) - 1)
#endif

#define PRISM_TRACE_MAX_NODES 16384
#define PRISM_TRACE_MAX_CALL_STACK 512

typedef struct {
    const char *func;
    int line;
    int active;
} prism_trace_scope_t;

typedef void (*prism_trace_crash_cb_t)(void);

extern pm_parser_t *g_trace_parser;
extern pm_buffer_t *g_trace_buf;
extern uint64_t g_trace_step;
extern uint64_t g_trace_max_steps;
extern const pm_node_t *g_trace_nodes[PRISM_TRACE_MAX_NODES];
extern uint32_t g_trace_node_count;
extern const char *g_trace_call_stack[PRISM_TRACE_MAX_CALL_STACK];
extern int g_trace_call_depth;
extern int g_trace_in_hook;
extern int g_trace_crashed;

void prism_trace_reset(pm_buffer_t *buf, uint64_t max_steps);
void prism_trace_set_crash_cb(prism_trace_crash_cb_t cb);
void prism_trace_emit_crash(const char *reason, const char *expr, const char *file, int line, const char *func);

PRISM_EXPORTED_FUNCTION void prism_trace_run_to_buffer(
    pm_buffer_t *out_buf,
    const uint8_t *source,
    size_t size,
    uint32_t max_steps
);

void prism_trace_emit_event(
    const pm_parser_t *parser,
    const char *kind,
    const char *func,
    int line,
    const char *detail_json,
    int include_ast
);

void prism_trace_emit_last_error(const pm_parser_t *parser, const char *func, int line);

static inline bool
prism_trace_emit_bool(bool result, const pm_parser_t *parser, const char *kind, const char *func, int line) {
    prism_trace_emit_event(parser, kind, func, line, NULL, 0);
    return result;
}

prism_trace_scope_t prism_trace_scope_enter(const char *func, int line);
void prism_trace_scope_cleanup(prism_trace_scope_t *scope);

const pm_node_t *prism_trace_node_new(const pm_node_t *node, const char *func, int line);
void prism_trace_node_list_append(const pm_node_list_t *list, const pm_node_t *node, const char *func, int line);

#endif
