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

static int
cli_hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int
cli_b64_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}

static uint8_t *
decode_url_code_param(const char *query, size_t query_len, size_t *out_len, int *found_code) {
    *out_len = 0;
    *found_code = 0;
    const char *p = query;
    const char *end = query + query_len;
    if (p < end && *p == '?') p++;

    while (p < end) {
        const char *amp = (const char *) memchr(p, '&', (size_t) (end - p));
        const char *pair_end = amp != NULL ? amp : end;
        const char *eq = (const char *) memchr(p, '=', (size_t) (pair_end - p));
        if (eq != NULL && (size_t) (eq - p) == 4 && memcmp(p, "code", 4) == 0) {
            *found_code = 1;
            const char *v = eq + 1;
            size_t v_len = (size_t) (pair_end - v);
            uint8_t *vals = (uint8_t *) malloc(v_len + 1);
            if (!vals) return NULL;
            size_t n = 0;
            for (size_t i = 0; i < v_len; i++) {
                char c = v[i];
                if (c == '%' && i + 2 < v_len) {
                    int hi = cli_hex_val(v[i + 1]);
                    int lo = cli_hex_val(v[i + 2]);
                    if (hi >= 0 && lo >= 0) {
                        c = (char) ((hi << 4) | lo);
                        i += 2;
                    }
                } else if (c == ' ') {
                    c = '+';
                }
                if (c == '=') continue;
                int bv = cli_b64_val(c);
                if (bv >= 0) vals[n++] = (uint8_t) bv;
            }
            uint8_t *out = (uint8_t *) malloc((n * 3) / 4 + 2);
            if (!out) {
                free(vals);
                return NULL;
            }
            size_t w = 0, i = 0;
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
            out[w] = '\0';
            free(vals);
            *out_len = w;
            return out;
        }
        if (amp == NULL) break;
        p = amp + 1;
    }
    return NULL;
}

int
main(int argc, char **argv) {
    const char *inline_code = NULL;
    const char *input_file = NULL;
    const char *opts_query = NULL;
    const char *loupe_url = NULL;
    uint32_t max_steps = 50000;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            s_out_path = argv[++i];
        } else if (strcmp(argv[i], "-e") == 0 && i + 1 < argc) {
            inline_code = argv[++i];
        } else if (strcmp(argv[i], "--opts") == 0 && i + 1 < argc) {
            opts_query = argv[++i];
        } else if (strcmp(argv[i], "--loupe-url") == 0 && i + 1 < argc) {
            loupe_url = argv[++i];
        } else if (strcmp(argv[i], "--max-steps") == 0 && i + 1 < argc) {
            max_steps = (uint32_t) strtoul(argv[++i], NULL, 10);
        } else {
            input_file = argv[i];
        }
    }

    const char *effective_query = opts_query;
    size_t effective_query_len = opts_query ? strlen(opts_query) : 0;
    if (loupe_url != NULL) {
        const char *qmark = strchr(loupe_url, '?');
        const char *qstart = qmark != NULL ? (qmark + 1) : loupe_url;
        const char *hash = strchr(qstart, '#');
        size_t qlen = hash != NULL ? (size_t) (hash - qstart) : strlen(qstart);
        if (effective_query == NULL) {
            effective_query = qstart;
            effective_query_len = qlen;
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
    } else if (loupe_url != NULL) {
        const char *qmark = strchr(loupe_url, '?');
        const char *qstart = qmark != NULL ? (qmark + 1) : loupe_url;
        const char *hash = strchr(qstart, '#');
        size_t qlen = hash != NULL ? (size_t) (hash - qstart) : strlen(qstart);
        int found_code = 0;
        owned_buf = decode_url_code_param(qstart, qlen, &size, &found_code);
        if (found_code && owned_buf != NULL) {
            source = owned_buf;
        } else {
            source = (const uint8_t *) "";
            size = 0;
        }
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
    prism_trace_run_to_buffer_opts(&s_trace_buf, source, size, max_steps, effective_query, effective_query_len);

    flush_trace_to_disk(0);

#if PRISM_TRACE_HAS_BUFFER_NEW
    pm_buffer_cleanup(&s_trace_buf);
#else
    pm_buffer_free(&s_trace_buf);
#endif
    free(owned_buf);
    return 0;
}
