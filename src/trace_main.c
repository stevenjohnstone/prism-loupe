#include "trace_runtime.h"
#include "prism.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *s_out_path = "build/trace.jsonl";
static pm_buffer_t s_trace_buf = { 0 };

static void
flush_trace_to_disk(int is_crash) {
    FILE *out = fopen(s_out_path, "wb");
    if (!out) {
        fprintf(stderr, "Failed to open trace output: %s\n", s_out_path);
        return;
    }
    fwrite(pm_buffer_value(&s_trace_buf), 1, pm_buffer_length(&s_trace_buf), out);
    fclose(out);

    if (is_crash) {
        fprintf(stderr, "⚠ CRASH intercepted at step %" PRIu64 " (%u AST nodes) — partial trace saved to %s\n",
                g_trace_step, g_trace_node_count, s_out_path);
    } else {
        fprintf(stderr, "Recorded %" PRIu64 " trace steps (%u AST nodes) to %s\n",
                g_trace_step, g_trace_node_count, s_out_path);
    }
}

static void
on_prism_crash(void) {
    flush_trace_to_disk(1);
    _Exit(0);
}

static void
on_fatal_signal(int sig) {
    const char *sig_name =
        sig == SIGSEGV ? "SIGSEGV" :
        sig == SIGBUS  ? "SIGBUS"  :
        sig == SIGABRT ? "SIGABRT" :
        sig == SIGILL  ? "SIGILL"  :
        sig == SIGFPE  ? "SIGFPE"  : "SIGNAL";

    if (!g_trace_crashed) {
        const char *top_fn = g_trace_call_depth > 0 ? g_trace_call_stack[g_trace_call_depth - 1] : "pm_parse";
        prism_trace_emit_crash(sig_name, sig_name, "src/prism.c", 0, top_fn);
    }
    flush_trace_to_disk(1);
    _Exit(0);
}

static uint8_t *
read_file_bytes(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) {
        fclose(f);
        return NULL;
    }
    uint8_t *buf = (uint8_t *) malloc((size_t)sz + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t n = fread(buf, 1, (size_t)sz, f);
    buf[n] = '\0';
    fclose(f);
    *out_len = n;
    return buf;
}

int
main(int argc, char **argv) {
    const char *inline_code = NULL;
    const char *input_file = NULL;
    uint32_t max_steps = 50000;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            s_out_path = argv[++i];
        } else if (strcmp(argv[i], "-e") == 0 && i + 1 < argc) {
            inline_code = argv[++i];
        } else if (strcmp(argv[i], "--max-steps") == 0 && i + 1 < argc) {
            max_steps = (uint32_t) strtoul(argv[++i], NULL, 10);
        } else {
            input_file = argv[i];
        }
    }

    const uint8_t *source = NULL;
    size_t size = 0;
    uint8_t *owned_buf = NULL;

    const char *default_code =
        "x = <<~OUTER + 42\n"
        "  hello #{<<-INNER.strip}\n"
        "    world\n"
        "  INNER\n"
        "  done\n"
        "OUTER\n"
        "puts x\n";

    if (inline_code != NULL) {
        source = (const uint8_t *) inline_code;
        size = strlen(inline_code);
    } else if (input_file != NULL) {
        owned_buf = read_file_bytes(input_file, &size);
        if (!owned_buf) {
            fprintf(stderr, "Failed to read input file: %s\n", input_file);
            return 1;
        }
        source = owned_buf;
    } else {
        source = (const uint8_t *) default_code;
        size = strlen(default_code);
    }

    prism_trace_set_crash_cb(on_prism_crash);
    signal(SIGABRT, on_fatal_signal);
    signal(SIGSEGV, on_fatal_signal);
    signal(SIGBUS, on_fatal_signal);
    signal(SIGILL, on_fatal_signal);
    signal(SIGFPE, on_fatal_signal);

    memset(&s_trace_buf, 0, sizeof(s_trace_buf));
    prism_trace_run_to_buffer(&s_trace_buf, source, size, max_steps);

    flush_trace_to_disk(0);

    pm_buffer_cleanup(&s_trace_buf);
    free(owned_buf);
    return 0;
}
