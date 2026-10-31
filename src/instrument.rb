#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

def one_line(code)
  code.lines.map(&:strip).reject(&:empty?).join(" ")
end

def replace_once!(content, target, replacement, label)
  raise "Could not find #{label}" unless content.include?(target)

  content.sub!(target) { replacement }
end

def next_line_in_orig(orig_content, target, label)
  idx = orig_content.index(target)
  raise "Could not find #{label} in original source" unless idx

  extra = target.end_with?("\n") ? 1 : 2
  orig_content[0, idx + target.length].count("\n") + extra
end

def instrument_node_c(src_path, out_path)
  content = File.read(src_path, encoding: "UTF-8")
  orig_lines = content.count("\n")

  replace_once!(
    content,
    '#line 2 "prism/templates/src/node.c.erb"',
    '/* #line 2 "prism/templates/src/node.c.erb" */',
    "#line in src/node.c"
  )

  # 1. Make pm_visit_node NULL-safe on the same line
  replace_once!(
    content,
    "pm_visit_node(const pm_node_t *node, pm_visit_callback_t visitor, void *data) {",
    "pm_visit_node(const pm_node_t *node, pm_visit_callback_t visitor, void *data) { if ((uintptr_t)node == 0) return true;",
    "pm_visit_node"
  )

  # 2. Hook pm_node_list_append_slow on the same line
  replace_once!(
    content,
    "    list->nodes[list->size++] = node;\n}",
    "    list->nodes[list->size++] = node; prism_trace_node_list_append(list, node, __func__, __LINE__);\n}",
    "pm_node_list_append_slow"
  )

  # 3. In all pm_*_node_new functions at the bottom of src/node.c, wrap `return node;`
  marker = "pm_alias_global_variable_node_new("
  idx = content.index(marker)
  raise "Could not find #{marker} in #{src_path}" unless idx

  head = content[0...idx]
  tail = content[idx..].gsub(
    /^    return node;$/,
    "    return (void *) prism_trace_node_new((const pm_node_t *) node, __func__, __LINE__);"
  )
  content = head + tail

  raise "Line count changed in trace_node.c!" unless content.count("\n") == orig_lines

  header = %(#include "trace_runtime.h"\n#line 1 "src/node.c"\n)
  FileUtils.mkdir_p(File.dirname(out_path))
  File.write(out_path, header + content, encoding: "UTF-8")
end

def instrument_prism_c(src_path, out_path)
  orig_content = File.read(src_path, encoding: "UTF-8")
  content = orig_content.dup

  # 1. Hook pm_node_list_append_inline on the #define U32 line
  target_u32 = "#define U32(value_) ((uint32_t) (value_))\n"
  line_u32 = next_line_in_orig(orig_content, target_u32, "#define U32")
  inline_append_hook = one_line(<<~C)
    static PRISM_INLINE void prism_trace_node_list_append_inline(pm_arena_t *arena, pm_node_list_t *list, pm_node_t *node, const char *func, int line) {
        if (list->size < list->capacity) {
            list->nodes[list->size++] = node;
            prism_trace_node_list_append(list, node, func, line);
        } else {
            pm_node_list_append_slow(arena, list, node);
        }
    }
  C
  replace_once!(
    content,
    target_u32,
    "#{target_u32}#{inline_append_hook}\n#define pm_node_list_append_inline(arena_, list_, node_) prism_trace_node_list_append_inline((arena_), (list_), (node_), __func__, __LINE__)\n#line #{line_u32} \"src/prism.c\"\n",
    "#define U32"
  )

  # 2. Hook lex_mode_push and its wrappers right after lex_mode_push_string_eof
  target_lex_mode_eof = <<~C.chomp
    static PRISM_INLINE void
    lex_mode_push_string_eof(pm_parser_t *parser) {
        lex_mode_push_string(parser, false, false, '\\0', '\\0');
    }
  C
  line_lex_eof = next_line_in_orig(orig_content, target_lex_mode_eof, "lex_mode_push_string_eof")
  lex_push_hooks = one_line(<<~C)
    static PRISM_INLINE void prism_trace_lex_mode_push_hook(pm_parser_t *parser, pm_lex_mode_t lex_mode, const char *func, int line) { lex_mode_push(parser, lex_mode); prism_trace_emit_event(parser, "LEX_MODE_PUSH", func, line, NULL, 0); }
    static PRISM_INLINE void prism_trace_lex_mode_push_list_hook(pm_parser_t *parser, bool interpolation, uint8_t delimiter, const char *func, int line) { lex_mode_push_list(parser, interpolation, delimiter); prism_trace_emit_event(parser, "LEX_MODE_PUSH", func, line, NULL, 0); }
    static PRISM_INLINE void prism_trace_lex_mode_push_list_eof_hook(pm_parser_t *parser, const char *func, int line) { lex_mode_push_list_eof(parser); prism_trace_emit_event(parser, "LEX_MODE_PUSH", func, line, NULL, 0); }
    static PRISM_INLINE void prism_trace_lex_mode_push_regexp_hook(pm_parser_t *parser, uint8_t incrementor, uint8_t terminator, const char *func, int line) { lex_mode_push_regexp(parser, incrementor, terminator); prism_trace_emit_event(parser, "LEX_MODE_PUSH", func, line, NULL, 0); }
    static PRISM_INLINE void prism_trace_lex_mode_push_string_hook(pm_parser_t *parser, bool interpolation, bool label_allowed, uint8_t incrementor, uint8_t terminator, const char *func, int line) { lex_mode_push_string(parser, interpolation, label_allowed, incrementor, terminator); prism_trace_emit_event(parser, "LEX_MODE_PUSH", func, line, NULL, 0); }
    static PRISM_INLINE void prism_trace_lex_mode_push_string_eof_hook(pm_parser_t *parser, const char *func, int line) { lex_mode_push_string_eof(parser); prism_trace_emit_event(parser, "LEX_MODE_PUSH", func, line, NULL, 0); }
  C
  replacement_lex_mode_eof = [
    "#{target_lex_mode_eof} #{lex_push_hooks}",
    "#define lex_mode_push(p_, ...) prism_trace_lex_mode_push_hook((p_), (__VA_ARGS__), __func__, __LINE__)",
    "#define lex_mode_push_list(p_, i_, d_) prism_trace_lex_mode_push_list_hook((p_), (i_), (d_), __func__, __LINE__)",
    "#define lex_mode_push_list_eof(p_) prism_trace_lex_mode_push_list_eof_hook((p_), __func__, __LINE__)",
    "#define lex_mode_push_regexp(p_, inc_, term_) prism_trace_lex_mode_push_regexp_hook((p_), (inc_), (term_), __func__, __LINE__)",
    "#define lex_mode_push_string(p_, i_, l_, inc_, term_) prism_trace_lex_mode_push_string_hook((p_), (i_), (l_), (inc_), (term_), __func__, __LINE__)",
    "#define lex_mode_push_string_eof(p_) prism_trace_lex_mode_push_string_eof_hook((p_), __func__, __LINE__)",
    %(#line #{line_lex_eof} "src/prism.c")
  ].join("\n")
  replace_once!(content, target_lex_mode_eof, replacement_lex_mode_eof, "lex_mode_push_string_eof")

  # 3. Hook lex_mode_pop
  target_lex_mode_pop = <<~C.chomp
    static void
    lex_mode_pop(pm_parser_t *parser) {
        pm_lex_mode_t *popped = parser->lex_modes.current;

        if (popped == &parser->lex_modes.base) {
            popped->mode = PM_LEX_DEFAULT;
        } else {
            parser->lex_modes.current = popped->prev;
            popped->prev = parser->lex_modes.free;
            parser->lex_modes.free = popped;
        }
    }
  C
  line_lex_pop = next_line_in_orig(orig_content, target_lex_mode_pop, "lex_mode_pop")
  pop_hook = one_line(<<~C)
    static PRISM_INLINE void prism_trace_lex_mode_pop_hook(pm_parser_t *parser, const char *func, int line) {
        lex_mode_pop(parser);
        prism_trace_emit_event(parser, "LEX_MODE_POP", func, line, NULL, 0);
    }
  C
  replacement_lex_mode_pop = [
    "#{target_lex_mode_pop} #{pop_hook}",
    "#define lex_mode_pop(p_) prism_trace_lex_mode_pop_hook((p_), __func__, __LINE__)",
    %(#line #{line_lex_pop} "src/prism.c")
  ].join("\n")
  replace_once!(content, target_lex_mode_pop, replacement_lex_mode_pop, "lex_mode_pop")

  # 4. Hook lex_state_set
  target_lex_state_set = <<~C.chomp
    static PRISM_INLINE void
    lex_state_set(pm_parser_t *parser, pm_lex_state_t state) {
        parser->lex_state = state;
    }
  C
  line_lex_state = next_line_in_orig(orig_content, target_lex_state_set, "lex_state_set")
  state_hook = one_line(<<~C)
    static PRISM_INLINE void prism_trace_lex_state_set_hook(pm_parser_t *parser, pm_lex_state_t state, const char *func, int line) {
        lex_state_set(parser, state);
        prism_trace_emit_event(parser, "LEX_STATE", func, line, NULL, 0);
    }
  C
  replacement_lex_state_set = [
    "#{target_lex_state_set} #{state_hook}",
    "#define lex_state_set(p_, s_) prism_trace_lex_state_set_hook((p_), (s_), __func__, __LINE__)",
    %(#line #{line_lex_state} "src/prism.c")
  ].join("\n")
  replace_once!(content, target_lex_state_set, replacement_lex_state_set, "lex_state_set")

  # 5. Hook pm_parser_err*
  target_err = <<~C.chomp
    static PRISM_INLINE void
    pm_parser_err_node(pm_parser_t *parser, const pm_node_t *node, pm_diagnostic_id_t diag_id) {
        pm_parser_err(parser, PM_NODE_START(node), PM_NODE_LENGTH(node), diag_id);
    }
  C
  line_err = next_line_in_orig(orig_content, target_err, "pm_parser_err_node")
  err_hooks = one_line(<<~C)
    static PRISM_INLINE void prism_trace_emit_last_error(pm_parser_t *parser, const char *func, int line) {
        const pm_diagnostic_t *diag = (const pm_diagnostic_t *) parser->error_list.tail;
        char buf[512];
        if (diag != NULL) {
            snprintf(buf, sizeof(buf), "{\\"diag_type\\":\\"%s\\",\\"start\\":%u,\\"length\\":%u}", pm_diagnostic_type(diag), diag->location.start, diag->location.length);
            prism_trace_emit_event(parser, "ERROR", func, line, buf, 0);
        } else {
            prism_trace_emit_event(parser, "ERROR", func, line, NULL, 0);
        }
    }
    static PRISM_INLINE void prism_trace_err_hook(pm_parser_t *parser, uint32_t start, uint32_t length, pm_diagnostic_id_t diag_id, const char *func, int line) { pm_parser_err(parser, start, length, diag_id); prism_trace_emit_last_error(parser, func, line); }
    static PRISM_INLINE void prism_trace_err_token_hook(pm_parser_t *parser, const pm_token_t *token, pm_diagnostic_id_t diag_id, const char *func, int line) { pm_parser_err_token(parser, token, diag_id); prism_trace_emit_last_error(parser, func, line); }
    static PRISM_INLINE void prism_trace_err_current_hook(pm_parser_t *parser, pm_diagnostic_id_t diag_id, const char *func, int line) { pm_parser_err_current(parser, diag_id); prism_trace_emit_last_error(parser, func, line); }
    static PRISM_INLINE void prism_trace_err_previous_hook(pm_parser_t *parser, pm_diagnostic_id_t diag_id, const char *func, int line) { pm_parser_err_previous(parser, diag_id); prism_trace_emit_last_error(parser, func, line); }
    static PRISM_INLINE void prism_trace_err_node_hook(pm_parser_t *parser, const pm_node_t *node, pm_diagnostic_id_t diag_id, const char *func, int line) { pm_parser_err_node(parser, node, diag_id); prism_trace_emit_last_error(parser, func, line); }
  C
  replacement_err = [
    "#{target_err} #{err_hooks}",
    "#define pm_parser_err(p_, s_, l_, d_) prism_trace_err_hook((p_), (s_), (l_), (d_), __func__, __LINE__)",
    "#define pm_parser_err_token(p_, t_, d_) prism_trace_err_token_hook((p_), (t_), (d_), __func__, __LINE__)",
    "#define pm_parser_err_current(p_, d_) prism_trace_err_current_hook((p_), (d_), __func__, __LINE__)",
    "#define pm_parser_err_previous(p_, d_) prism_trace_err_previous_hook((p_), (d_), __func__, __LINE__)",
    "#define pm_parser_err_node(p_, n_, d_) prism_trace_err_node_hook((p_), (n_), (d_), __func__, __LINE__)",
    %(#line #{line_err} "src/prism.c")
  ].join("\n")
  replace_once!(content, target_err, replacement_err, "pm_parser_err_node")

  # 6. Hook parser_lex_callback
  target_lex_cb = <<~C.chomp
    static PRISM_INLINE void
    parser_lex_callback(pm_parser_t *parser) {
        if (parser->lex_callback.callback) {
            parser->lex_callback.callback(parser, &parser->current, parser->lex_callback.data);
        }
    }
  C
  line_lex_cb = next_line_in_orig(orig_content, target_lex_cb, "parser_lex_callback")
  lex_cb_hook = one_line(<<~C)
    static PRISM_INLINE void prism_trace_lex_callback_hook(pm_parser_t *parser, const char *func, int line) {
        parser_lex_callback(parser);
        prism_trace_emit_event(parser, "LEX_TOKEN", func, line, NULL, 0);
    }
  C
  replacement_lex_cb = [
    "#{target_lex_cb} #{lex_cb_hook}",
    "#define parser_lex_callback(p_) prism_trace_lex_callback_hook((p_), __func__, __LINE__)",
    %(#line #{line_lex_cb} "src/prism.c")
  ].join("\n")
  replace_once!(content, target_lex_cb, replacement_lex_cb, "parser_lex_callback")

  # 7. Hook parser_flush_heredoc_end
  target_flush_hd = <<~C.chomp
    static PRISM_INLINE void
    parser_flush_heredoc_end(pm_parser_t *parser) {
        assert(parser->heredoc_end <= parser->end);
        parser->next_start = parser->heredoc_end;
        parser->heredoc_end = NULL;
    }
  C
  line_flush_hd = next_line_in_orig(orig_content, target_flush_hd, "parser_flush_heredoc_end")
  flush_hd_hook = one_line(<<~C)
    static PRISM_INLINE void prism_trace_flush_heredoc_end_hook(pm_parser_t *parser, const char *func, int line) {
        const uint8_t *old_hd = parser->heredoc_end;
        parser_flush_heredoc_end(parser);
        if (old_hd != NULL) {
            prism_trace_emit_event(parser, "HEREDOC_FLUSH", func, line, NULL, 0);
        }
    }
  C
  replacement_flush_hd = [
    "#{target_flush_hd} #{flush_hd_hook}",
    "#define parser_flush_heredoc_end(p_) prism_trace_flush_heredoc_end_hook((p_), __func__, __LINE__)",
    %(#line #{line_flush_hd} "src/prism.c")
  ].join("\n")
  replace_once!(content, target_flush_hd, replacement_flush_hd, "parser_flush_heredoc_end")

  # 8. Set g_trace_parser at the start of pm_parse (same line)
  target_pm_parse = <<~C.chomp
    pm_node_t *
    pm_parse(pm_parser_t *parser) {
        pm_node_t *node = parse_program(parser);
  C
  replacement_pm_parse = <<~C.chomp
    pm_node_t *
    pm_parse(pm_parser_t *parser) { g_trace_parser = parser;
        pm_node_t *node = parse_program(parser);
  C
  replace_once!(content, target_pm_parse, replacement_pm_parse, "pm_parse")

  # 9. Inject PRISM_TRACE_PARSE_SCOPE on the same line as `{` in every parse_* function definition
  count = 0
  content.gsub!(/^(?:static\s+(?:PRISM_INLINE\s+)?[a-zA-Z0-9_*\s]+\n)(parse_[a-zA-Z0-9_]+)\([^;{]*\)\s*\{/) do |match|
    count += 1
    "#{match} prism_trace_scope_t _trace_scope __attribute__((cleanup(prism_trace_scope_cleanup))) = prism_trace_scope_enter(__func__, __LINE__); (void)_trace_scope;"
  end
  puts "Instrumented #{count} parse_* functions in #{out_path} (preserving exact src/prism.c line numbers)"

  header = %(#include "trace_runtime.h"\n#line 1 "src/prism.c"\n)
  FileUtils.mkdir_p(File.dirname(out_path))
  File.write(out_path, header + content, encoding: "UTF-8")
end

prism_dir = ARGV[0] || "vendor/prism"
build_dir = ARGV[1] || "build"

instrument_node_c(File.join(prism_dir, "src/node.c"), File.join(build_dir, "trace_node.c"))
instrument_prism_c(File.join(prism_dir, "src/prism.c"), File.join(build_dir, "trace_prism.c"))
