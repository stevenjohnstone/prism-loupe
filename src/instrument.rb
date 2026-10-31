#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

def one_line(code)
  code.lines.map(&:strip).reject(&:empty?).join(" ")
end

def replace_regex_once!(content, pattern, label)
  matched = false
  content.sub!(pattern) do |m|
    matched = true
    yield(m, Regexp.last_match)
  end
  raise "Could not find #{label}" unless matched
end

def function_signature_info(orig_content, func_name)
  pattern = /^(static\s+(?:PRISM_INLINE\s+|PRISM_FORCE_INLINE\s+)?([a-zA-Z0-9_*\s]+?))\n#{Regexp.escape(func_name)}\(([^;{]*)\)\s*\{/m
  m = orig_content.match(pattern)
  return nil unless m

  ret_type = m[2].strip
  params = m[3].split(",").map(&:strip).reject(&:empty?)
  {
    ret_type: ret_type,
    returns_bool: ret_type == "bool",
    arity: params.size
  }
end

def inject_after_function!(content, orig_content, func_name, injected_lines)
  pattern = /^(?:static\s+(?:PRISM_INLINE\s+|PRISM_FORCE_INLINE\s+)?[a-zA-Z0-9_*\s]+\n)?#{Regexp.escape(func_name)}\([^;{]*\)\s*\{.*?\n\}/m
  orig_match = orig_content.match(pattern)
  raise "Could not find function #{func_name} in original source" unless orig_match

  next_line = orig_content[0, orig_match.end(0)].count("\n") + 2
  replace_regex_once!(content, pattern, "function #{func_name}") do |match_str, _|
    [
      match_str,
      *injected_lines,
      %(#line #{next_line} "src/prism.c")
    ].join("\n")
  end
end

def write_compat_header(prism_dir, build_dir)
  has_internal_parser = File.exist?(File.join(prism_dir, "include/prism/internal/parser.h"))
  parser_h_path = File.join(prism_dir, has_internal_parser ? "include/prism/internal/parser.h" : "include/prism/parser.h")
  parser_h = File.read(parser_h_path, encoding: "UTF-8")
  ast_h = File.read(File.join(prism_dir, "include/prism/ast.h"), encoding: "UTF-8")
  node_h = File.read(File.join(prism_dir, "include/prism/node.h"), encoding: "UTF-8")

  diag_h_path = File.join(prism_dir, "include/prism/diagnostic.h")
  diag_h = File.exist?(diag_h_path) ? File.read(diag_h_path, encoding: "UTF-8") : ""

  has_arena = File.exist?(File.join(prism_dir, "include/prism/internal/arena.h"))
  has_internal_diag = File.exist?(File.join(prism_dir, "include/prism/internal/diagnostic.h"))
  has_metadata_arena = parser_h.include?("metadata_arena")
  has_scratch_arena = parser_h.include?("scratch_arena")
  has_line_offsets = parser_h.include?("line_offsets")
  location_is_offset = ast_h.include?("uint32_t length;")
  visit_returns_enum = node_h.include?("PM_VISIT_SKIP")
  has_diag_type_fn = diag_h.include?("pm_diagnostic_type(")
  has_buffer_new = File.exist?(File.join(prism_dir, "include/prism/buffer.h"))

  contexts = parser_h.scan(/\b(PM_CONTEXT_[A-Z0-9_]+)\b/).flatten.uniq

  compat_c = <<~C
    #ifndef PRISM_TRACE_COMPAT_H
    #define PRISM_TRACE_COMPAT_H

    #define PRISM_TRACE_HAS_INTERNAL_HEADERS #{has_internal_parser ? 1 : 0}
    #define PRISM_TRACE_HAS_ARENA #{has_arena ? 1 : 0}
    #define PRISM_TRACE_HAS_INTERNAL_DIAG #{has_internal_diag ? 1 : 0}
    #define PRISM_TRACE_HAS_METADATA_ARENA #{has_metadata_arena ? 1 : 0}
    #define PRISM_TRACE_HAS_SCRATCH_ARENA #{has_scratch_arena ? 1 : 0}
    #define PRISM_TRACE_HAS_LINE_OFFSETS #{has_line_offsets ? 1 : 0}
    #define PRISM_TRACE_LOCATION_IS_OFFSET #{location_is_offset ? 1 : 0}
    #define PRISM_TRACE_VISIT_RETURNS_ENUM #{visit_returns_enum ? 1 : 0}
    #define PRISM_TRACE_HAS_DIAG_TYPE_FN #{has_diag_type_fn ? 1 : 0}
    #define PRISM_TRACE_HAS_BUFFER_NEW #{has_buffer_new ? 1 : 0}

    #if PRISM_TRACE_HAS_INTERNAL_HEADERS
    #include "prism/internal/parser.h"
    #if PRISM_TRACE_HAS_ARENA
    #include "prism/internal/arena.h"
    #endif
    #include "prism/internal/node.h"
    #include "prism/internal/tokens.h"
    #if PRISM_TRACE_HAS_INTERNAL_DIAG
    #include "prism/internal/diagnostic.h"
    #endif
    #include "prism/internal/buffer.h"
    #include "prism/diagnostic.h"
    #include "prism/node.h"
    #else
    #include "prism.h"
    #include "prism/parser.h"
    #include "prism/node.h"
    #include "prism/diagnostic.h"
    #include "prism/util/pm_buffer.h"
    #include "prism/util/pm_newline_list.h"
    #define pm_token_type(t_) pm_token_type_name(t_)
    #define pm_node_type(t_) pm_node_type_to_str(t_)
    #endif

    static inline const char *
    prism_trace_context_name(pm_context_t ctx) {
        switch (ctx) {
  C

  contexts.each do |c|
    short = c.sub(/\APM_CONTEXT_/, "")
    short = "MAX" if short == "MAXIMUM"
    compat_c << "        case #{c}: return \"#{short}\";\n"
  end

  compat_c << <<~C
            default: return "UNKNOWN";
        }
    }

    #endif
  C

  FileUtils.mkdir_p(build_dir)
  File.write(File.join(build_dir, "trace_compat.h"), compat_c, encoding: "UTF-8")

  {
    visit_returns_enum: visit_returns_enum
  }
end

def instrument_node_c(src_path, out_path, visit_returns_enum:)
  content = File.read(src_path, encoding: "UTF-8")
  orig_lines = content.count("\n")

  content.sub!(/\A#line\s+\d+\s+"[^"]*node\.c\.erb"/, '/* \0 */')

  # 1. Make pm_visit_node NULL-safe on the same line
  null_guard = visit_returns_enum ? "if ((uintptr_t)node == 0) return true;" : "if ((uintptr_t)node == 0) return;"
  replace_regex_once!(
    content,
    /^(pm_visit_node\([^;{]*\)\s*\{)/,
    "pm_visit_node"
  ) { |m, _| "#{m} #{null_guard}" }

  # 2. In all pm_*_node_new functions in src/node.c (if present, v2.0.0+), wrap `return node;` on the same line
  content.gsub!(/^(pm_[a-z0-9_]+_node_new\([^;{]*\)\s*\{.*?\n\})/m) do |fn_block|
    fn_block.gsub(
      /^    return node;$/,
      "    return (void *) prism_trace_node_new((const pm_node_t *) node, __func__, __LINE__);"
    )
  end

  raise "Line count changed in trace_node.c!" unless content.count("\n") == orig_lines

  header = %(#include "trace_runtime.h"\n#line 1 "src/node.c"\n)
  FileUtils.mkdir_p(File.dirname(out_path))
  File.write(out_path, header + content, encoding: "UTF-8")
end

def instrument_prism_c(src_path, out_path)
  orig_content = File.read(src_path, encoding: "UTF-8")
  content = orig_content.dup

  # 1. Hook lex_mode_push and all lex_mode_push_* wrappers dynamically by signature
  push_funcs = orig_content.scan(/^(lex_mode_push[a-z0-9_]*)\(/).flatten.uniq
  raise "Could not find any lex_mode_push* functions in #{src_path}" if push_funcs.empty?

  push_macros = push_funcs.map do |fn|
    info = function_signature_info(orig_content, fn)
    raise "Could not parse signature of #{fn}" unless info

    if info[:arity] <= 1
      if info[:returns_bool]
        "#define #{fn}(p_) prism_trace_emit_bool(#{fn}((p_)), (p_), \"LEX_MODE_PUSH\", __func__, __LINE__)"
      else
        "#define #{fn}(p_) (#{fn}((p_)), prism_trace_emit_event((p_), \"LEX_MODE_PUSH\", __func__, __LINE__, NULL, 0))"
      end
    elsif info[:returns_bool]
      "#define #{fn}(p_, ...) prism_trace_emit_bool(#{fn}((p_), __VA_ARGS__), (p_), \"LEX_MODE_PUSH\", __func__, __LINE__)"
    else
      "#define #{fn}(p_, ...) (#{fn}((p_), __VA_ARGS__), prism_trace_emit_event((p_), \"LEX_MODE_PUSH\", __func__, __LINE__, NULL, 0))"
    end
  end
  inject_after_function!(content, orig_content, push_funcs.last, push_macros)

  # 2. Hook lex_mode_pop and pm_node_list_append(_inline) right after lex_mode_pop
  pop_lines = [
    '#define lex_mode_pop(p_) (lex_mode_pop((p_)), prism_trace_emit_event((p_), "LEX_MODE_POP", __func__, __LINE__, NULL, 0))'
  ]
  if orig_content.include?("pm_node_list_append_inline(")
    pop_lines << "#define pm_node_list_append_inline(arena_, list_, node_) (pm_node_list_append_inline((arena_), (list_), (node_)), prism_trace_node_list_append((list_), (node_), __func__, __LINE__))"
  else
    pop_lines << "#define pm_node_list_append(list_, node_) (pm_node_list_append((list_), (node_)), prism_trace_node_list_append((list_), (node_), __func__, __LINE__))"
  end
  inject_after_function!(content, orig_content, "lex_mode_pop", pop_lines)

  # 3. Hook lex_state_set by signature
  inject_after_function!(
    content,
    orig_content,
    "lex_state_set",
    ['#define lex_state_set(p_, s_) (lex_state_set((p_), (s_)), prism_trace_emit_event((p_), "LEX_STATE", __func__, __LINE__, NULL, 0))']
  )

  # 4. Hook pm_parser_err and all pm_parser_err_* wrappers dynamically by signature
  err_funcs = orig_content.scan(/^(pm_parser_err(?:_[a-z0-9_]+)?)\(/).flatten.uniq
  raise "Could not find any pm_parser_err* functions in #{src_path}" if err_funcs.empty?

  err_macros = err_funcs.map do |fn|
    "#define #{fn}(p_, ...) (#{fn}((p_), __VA_ARGS__), prism_trace_emit_last_error((p_), __func__, __LINE__))"
  end
  inject_after_function!(content, orig_content, err_funcs.last, err_macros)

  # 5. Hook parser_lex_callback by signature
  inject_after_function!(
    content,
    orig_content,
    "parser_lex_callback",
    ['#define parser_lex_callback(p_) (parser_lex_callback((p_)), prism_trace_emit_event((p_), "LEX_TOKEN", __func__, __LINE__, NULL, 0))']
  )

  # 6. Hook parser_flush_heredoc_end by signature
  flush_hd_hook = one_line(<<~C)
    static inline void prism_trace_flush_heredoc_end_hook(pm_parser_t *parser, const char *func, int line) {
        const uint8_t *old_hd = parser->heredoc_end;
        parser_flush_heredoc_end(parser);
        if (old_hd != NULL) {
            prism_trace_emit_event(parser, "HEREDOC_FLUSH", func, line, NULL, 0);
        }
    }
  C
  inject_after_function!(
    content,
    orig_content,
    "parser_flush_heredoc_end",
    [
      flush_hd_hook,
      "#define parser_flush_heredoc_end(p_) prism_trace_flush_heredoc_end_hook((p_), __func__, __LINE__)"
    ]
  )

  # 7. Set g_trace_parser at the opening brace of pm_parse (same line)
  replace_regex_once!(
    content,
    /^(pm_parse\(pm_parser_t\s*\*parser\)\s*\{)/,
    "pm_parse"
  ) { |m, _| "#{m} g_trace_parser = parser;" }

  # 8. In v1.x, node constructors are pm_*_node_create in src/prism.c; wrap `return node;` on the same line
  content.gsub!(/^(pm_[a-z0-9_]+_node_create\([^;{]*\)\s*\{.*?\n\})/m) do |fn_block|
    fn_block.gsub(
      /^    return node;$/,
      "    return (void *) prism_trace_node_new((const pm_node_t *) node, __func__, __LINE__);"
    )
  end

  # 9. Inject PRISM_TRACE_PARSE_SCOPE on the same line as `{` in every parse_* function definition
  count = 0
  content.gsub!(/^(?:static\s+(?:PRISM_INLINE\s+|PRISM_FORCE_INLINE\s+)?[a-zA-Z0-9_*\s]+\n)(parse_[a-zA-Z0-9_]+)\([^;{]*\)\s*\{/) do |match|
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

compat = write_compat_header(prism_dir, build_dir)
instrument_node_c(File.join(prism_dir, "src/node.c"), File.join(build_dir, "trace_node.c"), visit_returns_enum: compat[:visit_returns_enum])
instrument_prism_c(File.join(prism_dir, "src/prism.c"), File.join(build_dir, "trace_prism.c"))
