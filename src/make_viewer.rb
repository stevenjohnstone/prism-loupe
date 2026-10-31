#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"

def load_jsonl(path, name)
  lines = File.readlines(path, chomp: true).reject(&:empty?).filter_map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
  meta = lines.first
  steps = lines.drop(1)
  { "name" => name, "source" => meta["source"], "steps" => steps }
end

PRISM_DIR = ARGV[0] || "vendor/prism"
BUILD_DIR = ARGV[1] || "build"
OUT_HTML = ARGV[2] || "dist/index.html"

def run_trace(code, name, out_jsonl)
  FileUtils.mkdir_p(File.dirname(out_jsonl))
  ok = system(File.join(BUILD_DIR, "prism_trace"), "-e", code, "-o", out_jsonl)
  raise "Failed to run prism_trace for #{name}" unless ok

  load_jsonl(out_jsonl, name)
end

HTML_TEMPLATE = <<~'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Prism Parse & Lexer Visualizer</title>
<style>
  :root {
    --bg: #0d1117;
    --panel: #161b22;
    --panel-alt: #1c2128;
    --border: #30363d;
    --text: #e6edf3;
    --muted: #8b949e;
    --accent: #58a6ff;
    --green: #3fb950;
    --amber: #d29922;
    --purple: #bc8cff;
    --pink: #f778ba;
    --red: #f85149;
    --cyan: #39c5cf;
    --font-mono: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 13px;
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  header {
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    padding: 8px 14px;
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }
  .header-logo {
    width: 22px;
    height: 22px;
    display: block;
    flex-shrink: 0;
  }
  select, button, input[type="file"]::file-selector-button {
    background: var(--panel-alt);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 5px;
    padding: 4px 9px;
    font-size: 12px;
    cursor: pointer;
    white-space: nowrap;
    flex-shrink: 0;
  }
  button:hover:not(:disabled), select:hover { border-color: var(--accent); }
  button.primary { background: #1f6feb; border-color: #388bfd; font-weight: 600; }
  button.success { background: #238636; border-color: #2ea043; font-weight: 600; }
  button.warn { border-color: var(--red); color: #ffa198; }
  button:disabled {
    background: var(--panel-alt);
    color: var(--muted);
    border-color: var(--border);
    opacity: 0.45;
    cursor: default;
    font-weight: 400;
  }
  #rubyEditor {
    width: 100%;
    min-height: 220px;
    background: #090d13;
    color: var(--text);
    border: 1px solid var(--accent);
    border-radius: 6px;
    padding: 10px 12px;
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 1.6;
    resize: vertical;
    display: none;
  }
  #rubyEditor:focus { outline: 1px solid var(--accent); }
  .scrubber-bar {
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    padding: 8px 14px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    user-select: none;
  }
  .timeline-track {
    position: relative;
    height: 18px;
    background: #090d13;
    border: 1px solid var(--border);
    border-radius: 4px;
    overflow: hidden;
    cursor: ew-resize;
    touch-action: none;
  }
  .timeline-marker {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 2px;
    pointer-events: none;
  }
  .timeline-playhead {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 3px;
    background: #fff;
    box-shadow: 0 0 6px #fff;
    pointer-events: none;
    z-index: 3;
  }
  .main-grid {
    flex: 1;
    display: grid;
    grid-template-columns: 1.15fr 0.95fr 1.1fr;
    gap: 1px;
    background: var(--border);
    overflow: hidden;
  }
  .pane {
    background: var(--bg);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .pane-header {
    background: var(--panel);
    padding: 7px 12px;
    min-height: 36px;
    font-weight: 600;
    font-size: 12px;
    border-bottom: 1px solid var(--border);
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .pane-body {
    padding: 10px 12px;
    overflow: auto;
    flex: 1;
  }
  .source-box {
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 1.65;
    background: #090d13;
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 10px;
    overflow-x: auto;
    white-space: pre;
  }
  .src-line {
    display: flex;
    align-items: baseline;
    border-left: 2px solid transparent;
    padding-left: 4px;
    border-radius: 2px;
  }
  .src-line.active-line {
    background: rgba(88, 166, 255, 0.07);
    border-left-color: var(--accent);
  }
  .line-gutter {
    min-width: 3.2em;
    padding-right: 8px;
    margin-right: 8px;
    text-align: right;
    border-right: 1px solid var(--border);
    color: var(--muted);
    font-size: 11px;
    user-select: none;
    flex-shrink: 0;
  }
  .char-cell {
    display: inline-block;
    position: relative;
    padding: 0 1px;
    border-radius: 2px;
    min-width: 8px;
    text-align: center;
  }
  .char-cell.nl-char { color: #6e7681; }
  .char-cell.in-prev {
    background: rgba(210, 153, 34, 0.25);
    border-bottom: 2px solid var(--amber);
  }
  .char-cell.in-curr {
    background: rgba(63, 185, 80, 0.30);
    border-bottom: 2px solid var(--green);
  }
  .char-cell.curr-caret {
    box-shadow: inset 2px 0 0 var(--green);
    background: rgba(63, 185, 80, 0.18);
  }
  .char-cell.in-ast-hover {
    outline: 2px solid var(--accent);
    background: rgba(88, 166, 255, 0.30);
  }
  .badge {
    display: inline-block;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
  }
  .kind-LEX_TOKEN { background: rgba(63, 185, 80, 0.2); color: var(--green); border: 1px solid var(--green); }
  .kind-LEX_STATE { background: rgba(57, 197, 207, 0.2); color: var(--cyan); border: 1px solid var(--cyan); }
  .kind-LEX_MODE_PUSH, .kind-LEX_MODE_POP { background: rgba(247, 120, 186, 0.2); color: var(--pink); border: 1px solid var(--pink); }
  .kind-HEREDOC_FLUSH { background: rgba(188, 140, 255, 0.25); color: var(--purple); border: 1px solid var(--purple); }
  .kind-PARSE_ENTER, .kind-PARSE_EXIT { background: rgba(139, 148, 158, 0.15); color: var(--muted); border: 1px solid var(--border); }
  .kind-NODE_NEW, .kind-NODE_LIST_APPEND { background: rgba(88, 166, 255, 0.2); color: var(--accent); border: 1px solid var(--accent); }
  .kind-ERROR { background: rgba(247, 120, 186, 0.22); color: var(--pink); border: 1px solid var(--pink); }
  .kind-CRASH { background: var(--red); color: #fff; border: 1px solid #ff7b72; font-weight: 700; }
  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 9px 11px;
    margin-bottom: 10px;
  }
  .card-title {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--muted);
    margin-bottom: 6px;
    display: flex;
    justify-content: space-between;
  }
  .kv-grid {
    display: grid;
    grid-template-columns: 110px minmax(0, 1fr);
    row-gap: 5px;
    font-family: var(--font-mono);
    font-size: 12px;
  }
  .kv-grid > div {
    overflow-wrap: anywhere;
  }
  .kv-key { color: var(--muted); }
  .copy-pill {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 1px 5px;
    font-size: 10.5px;
    font-family: var(--font-mono);
    border-radius: 3px;
    background: var(--panel-alt);
    border: 1px solid var(--border);
    color: var(--muted);
    cursor: pointer;
    vertical-align: middle;
    margin-left: 4px;
  }
  .copy-pill:hover {
    border-color: var(--accent);
    color: var(--text);
  }
  .stack-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-family: var(--font-mono);
    font-size: 12px;
  }
  .stack-frame {
    padding: 4px 8px;
    background: var(--panel-alt);
    border-left: 3px solid var(--accent);
    border-radius: 3px;
    display: flex;
    justify-content: space-between;
    gap: 8px;
  }
  .stack-frame.mode-HEREDOC { border-left-color: var(--purple); }
  .stack-frame.mode-STRING { border-left-color: var(--green); }
  .stack-frame.mode-EMBEXPR { border-left-color: var(--amber); }
  .ast-node {
    font-family: var(--font-mono);
    font-size: 12px;
    margin-left: 14px;
    border-left: 1px dashed var(--border);
    padding-left: 8px;
    margin-top: 3px;
  }
  .ast-row {
    padding: 3px 6px;
    border-radius: 4px;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .ast-row:hover { background: var(--panel-alt); }
  .ast-row.just-changed {
    background: rgba(88, 166, 255, 0.22);
    outline: 1px solid var(--accent);
  }
  .ast-row.underflow-node {
    background: rgba(248, 81, 73, 0.22);
    outline: 1px solid var(--red);
  }
  .ast-id { color: var(--accent); font-weight: 700; }
  .ast-loc { color: var(--muted); font-size: 11px; }
  .ast-slice { color: var(--green); font-size: 11px; }
  .rewind-banner {
    background: rgba(210, 153, 34, 0.2);
    border: 1px solid var(--amber);
    color: #f2cc60;
    padding: 6px 9px;
    border-radius: 5px;
    margin-bottom: 8px;
    font-weight: 600;
    display: none;
  }
  .crash-banner, .underflow-banner {
    background: rgba(248, 81, 73, 0.22);
    border: 1px solid var(--red);
    color: #ffa198;
    padding: 8px 10px;
    border-radius: 5px;
    margin-bottom: 8px;
    font-family: var(--font-mono);
    font-size: 12px;
    display: none;
  }
  .offset-chip {
    display: inline-block;
    padding: 1px 5px;
    margin: 1px;
    border-radius: 3px;
    background: var(--panel-alt);
    border: 1px solid var(--border);
    font-family: var(--font-mono);
    font-size: 11px;
  }
  .offset-chip.bad {
    background: rgba(248, 81, 73, 0.25);
    border-color: var(--red);
    color: #ffa198;
  }
  .mem-row {
    margin-bottom: 7px;
    font-family: var(--font-mono);
    font-size: 11.5px;
  }
  .mem-row-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 3px;
  }
  .mem-bar-bg {
    height: 6px;
    background: #090d13;
    border-radius: 3px;
    overflow: hidden;
    border: 1px solid var(--border);
  }
  .mem-bar-fill {
    height: 100%;
    transition: width 0.08s ease-out;
  }
  .mem-delta-pill {
    display: inline-block;
    padding: 0 5px;
    border-radius: 3px;
    font-size: 10.5px;
    font-weight: 700;
    background: rgba(63, 185, 80, 0.22);
    color: var(--green);
    border: 1px solid var(--green);
    margin-left: 5px;
  }
  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: pre-wrap;
    border: 0;
  }
  .gemini-drawer {
    position: fixed;
    top: 44px;
    right: 0;
    bottom: 0;
    width: 420px;
    max-width: 95vw;
    background: var(--panel);
    border-left: 1px solid var(--border);
    box-shadow: -8px 0 24px rgba(0, 0, 0, 0.55);
    z-index: 50;
    display: none;
    flex-direction: column;
  }
  .gemini-drawer.open { display: flex; }
  .gemini-chip {
    background: var(--panel-alt);
    border: 1px solid var(--border);
    color: var(--text);
    border-radius: 14px;
    padding: 3px 9px;
    font-size: 11px;
    cursor: pointer;
  }
  .gemini-chip:hover { border-color: var(--accent); color: var(--accent); }
  .gemini-output {
    flex: 1;
    overflow-y: auto;
    padding: 10px 12px;
    background: #090d13;
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: 12.5px;
    line-height: 1.55;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  }
  .gemini-output code {
    font-family: var(--font-mono);
    font-size: 11.5px;
    background: var(--panel-alt);
    padding: 1px 4px;
    border-radius: 3px;
  }
  .settings-popover {
    position: fixed;
    top: 44px;
    right: 14px;
    width: 380px;
    max-width: 94vw;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.55);
    padding: 12px;
    z-index: 60;
    display: none;
  }
  .settings-popover.open { display: block; }
</style>
</head>
<body>

<header>
  <img src="data:image/svg+xml;base64,__RUBY_SVG_BASE64__" alt="Ruby" title="Prism Parse &amp; Lexer Visualizer" class="header-logo">
  <button id="btnPlayPause" class="success" style="min-width:68px;" title="Play / Pause automatic playthrough at 1 step/s (Spacebar)">&#9654; Play</button>
  <button id="btnPrev" class="primary" title="Step backward 1 trace event (Left Arrow)">&larr; Step</button>
  <button id="btnNext" class="primary" title="Step forward 1 trace event (Right Arrow)">Step &rarr;</button>
  <button id="btnPrevTok" class="primary" title="Jump to previous lexed token (Shift + Left Arrow)">&larr; Token</button>
  <button id="btnNextTok" class="primary" title="Jump to next lexed token (Shift + Right Arrow)">Token &rarr;</button>
  <button id="btnPrevAst" class="primary" title="Jump to previous AST node creation/attachment (Shift + N)">&larr; AST</button>
  <button id="btnNextAst" class="primary" title="Jump to next AST node creation/attachment (Key: N)">AST &rarr;</button>
  <button id="btnPrevAlloc" class="primary" title="Jump to previous memory allocation (Shift + M)">&larr; Alloc</button>
  <button id="btnNextAlloc" class="primary" title="Jump to next memory allocation (Key: M)">Alloc &rarr;</button>
  <button id="btnPrevRewind" class="primary" title="Jump to previous cursor rewind (Shift + R)">&larr; Rewind</button>
  <button id="btnNextRewind" class="primary" title="Jump to next cursor rewind (Key: R)">Rewind &rarr;</button>
  <button id="btnJumpUnderflow" class="warn" style="display:none;" title="Jump to corrupted node underflow detection step (Key: U)">⚠ Underflow</button>
  <button id="btnJumpCrash" class="warn" style="display:none;" title="Jump to intercepted crash step (Key: C)">💥 Crash</button>
  <span id="stepCounter" style="margin-left:auto; font-family:var(--font-mono); font-size:12px; color:var(--muted); white-space:nowrap;">Step 0 / 0</span>
  <button id="btnToggleGemini" style="display:none; border-color:var(--purple); color:var(--purple); font-weight:600;" title="Open in-page Gemini assistant drawer">✨ Ask Gemini</button>
  <button id="btnSettings" title="Settings (Configure local Prism repository path for Antigravity IDE links)">&#9881;</button>
</header>

<div id="settingsPopover" class="settings-popover">
  <div class="card-title" style="margin-bottom:8px;">
    <span>Viewer Settings</span>
    <span id="btnCloseSettings" style="cursor:pointer; font-size:14px; color:var(--muted);" title="Close">&times;</span>
  </div>
  <label for="repoRootInput" style="display:block; font-size:11.5px; color:var(--muted); margin-bottom:5px;">
    Prism Repository Path (enables <code>&nearr; Antigravity IDE</code> links):
  </label>
  <div style="display:flex; gap:5px;">
    <input type="text" id="repoRootInput" placeholder="/path/to/prism" style="flex:1; min-width:0; background:#090d13; color:var(--text); border:1px solid var(--border); border-radius:4px; padding:5px 8px; font-size:12px; font-family:var(--font-mono);">
    <button id="btnSaveRepoRoot" class="success">Save</button>
    <button id="btnClearRepoRoot">Clear</button>
  </div>
</div>

<div class="scrubber-bar">
  <div class="timeline-track" id="timelineTrack" title="Drag or click to scrub — Red = Crash / Corrupted Node (Underflow) | Pink = Syntax Error | Amber = Cursor Rewind | Blue = AST Update | Green = Token">
    <div class="timeline-playhead" id="timelinePlayhead"></div>
  </div>
</div>

<div class="main-grid">
  <div class="pane">
    <div class="pane-header">
      <span>Ruby Buffer &amp; Live Lexer</span>
      <span id="wasmStatus" style="font-size:11px; color:var(--muted); font-family:var(--font-mono); font-weight:400; white-space:nowrap;">Wasm: init...</span>
    </div>
    <div class="pane-body">
      <div id="crashBanner" class="crash-banner"></div>
      <div id="underflowBanner" class="underflow-banner"></div>
      <div id="rewindBanner" class="rewind-banner"></div>
      <div style="display:flex; flex-direction:column; gap:6px; margin-bottom:6px;">
        <div style="display:flex; align-items:center; justify-content:space-between; gap:5px;">
          <span style="font-size:11px; text-transform:uppercase; letter-spacing:0.5px; color:var(--muted);">Source Input</span>
          <div style="display:flex; align-items:center; gap:5px;">
            <button id="btnEditSource" class="success" title="Edit Ruby source in-place (or double-click source buffer)">✎ Edit Code</button>
            <button id="btnRunWasm" class="success" style="display:none;" title="Parse &amp; trace with in-browser Prism Wasm (Cmd/Ctrl + Enter)">▶ Parse &amp; Trace (⌘+Enter)</button>
            <button id="btnCancelEdit" style="display:none;">Cancel</button>
            <button id="btnOpenRb" title="Load a .rb file and trace it live">📂 .rb</button>
            <button id="btnOpenJsonl" title="Load a pre-recorded .jsonl trace">📂 .jsonl</button>
            <input type="file" id="rbFileInput" accept=".rb,.txt,*" style="display:none;">
            <input type="file" id="fileInput" accept=".jsonl,.json" style="display:none;">
          </div>
        </div>
        <div style="display:flex; align-items:center; gap:6px;">
          <label for="presetSelect" style="font-size:11px; color:var(--muted); white-space:nowrap;">Preset:</label>
          <select id="presetSelect" style="flex:1; min-width:0; flex-shrink:1; text-overflow:ellipsis; overflow:hidden;"></select>
        </div>
      </div>
      <div id="sourceBox" class="source-box" title="Double-click (or click '✎ Edit Code') to edit Ruby snippet in-place"></div>
      <textarea id="rubyEditor" spellcheck="false" placeholder="Paste or type Ruby code here and press ⌘+Enter / Ctrl+Enter (or click ▶ Parse & Trace)..."></textarea>

      <div class="card" style="margin-top:12px;">
        <div class="card-title">
          <span>Recorded Line Offsets (<code>parser-&gt;line_offsets</code>)</span>
          <span id="lineOffsetStatus"></span>
        </div>
        <div id="lineOffsetsBox"></div>
      </div>
    </div>
  </div>

  <div class="pane">
    <div class="pane-header">
      <span>Lexer State, Mode Stack &amp; Call Stack</span>
    </div>
    <div class="pane-body">
      <div class="card">
        <div class="card-title">Current Transition</div>
        <div class="kv-grid" id="transitionGrid"></div>
      </div>

      <div class="card">
        <div class="card-title"><span>Lexer Mode Stack (<code>parser-&gt;lex_modes</code>, top &rarr; bottom)</span></div>
        <div class="stack-list" id="lexModesStack"></div>
      </div>

      <div class="card">
        <div class="card-title"><span>Parser Context Stack (<code>parser-&gt;current_context</code>)</span></div>
        <div id="contextsBox" style="font-family:var(--font-mono); font-size:12px;"></div>
      </div>

      <div class="card">
        <div class="card-title">
          <span>Recursive-Descent Call Stack (<code>parse_*</code>)</span>
          <span id="callDepthBadge"></span>
        </div>
        <div class="stack-list" id="callStackBox"></div>
      </div>
    </div>
  </div>

  <div class="pane">
    <div class="pane-header">
      <span>Live Arenas, Memory &amp; AST Assembly</span>
      <span id="astSummary" style="font-family:var(--font-mono); color:var(--muted);"></span>
    </div>
    <div style="padding:10px 12px 0 12px; flex-shrink:0; border-bottom:1px solid var(--border);">
      <div class="card">
        <div class="card-title">
          <span>Arena Memory Telemetry (Used / Capacity)</span>
          <span id="memCardBadge"></span>
        </div>
        <div id="memBreakdownBox"></div>
      </div>
    </div>
    <div class="pane-body">
      <div class="card">
        <div class="card-title">Active AST Roots (Attached &amp; In-Flight Nodes)</div>
        <div id="astTreeBox"></div>
      </div>
      <div class="card">
        <div class="card-title">Superseded / Unreferenced Arena Nodes</div>
        <div id="astOrphansBox"></div>
      </div>
    </div>
  </div>
</div>

<aside id="geminiPageContext" class="sr-only" aria-label="Full Prism Parser Trace and Step Context for Gemini in Chrome"></aside>

<div id="geminiDrawer" class="gemini-drawer">
  <div class="pane-header">
    <span>✨ Ask Gemini about this Trace</span>
    <div style="display:flex; gap:5px;">
      <button id="btnCopyGemini" title="Copy structured step &amp; trace context to clipboard">📋 Copy Context</button>
      <button id="btnCloseGemini" title="Close Gemini drawer">&times; Close</button>
    </div>
  </div>
  <div style="padding:10px 12px; display:flex; flex-direction:column; gap:8px; flex:1; overflow:hidden;">
    <div id="geminiKeySetup" class="card" style="margin-bottom:0;">
      <div class="card-title">
        <span>Gemini Connection</span>
        <a href="https://aistudio.google.com/apikey" target="_blank" rel="noopener" style="color:var(--accent); text-decoration:none; text-transform:none;">Get Free API Key &nearr;</a>
      </div>
      <div style="display:flex; gap:5px;">
        <input type="password" id="geminiKeyInput" placeholder="Paste Gemini API key (saved in localStorage)..." style="flex:1; min-width:0; background:#090d13; color:var(--text); border:1px solid var(--border); border-radius:4px; padding:4px 8px; font-size:11.5px; font-family:var(--font-mono);">
        <button id="btnSaveGeminiKey" class="success">Save</button>
      </div>
      <div style="font-size:11px; color:var(--muted); margin-top:5px;">
        Or use <strong>Chrome's built-in Gemini side panel</strong> (top-right of Chrome) — this page automatically exposes live step context in the DOM, or click <strong>📋 Copy for Gemini</strong>.
      </div>
    </div>
    <div id="geminiKeySavedBar" style="display:none; align-items:center; justify-content:space-between; font-size:11px; color:var(--muted); background:var(--panel-alt); padding:5px 8px; border-radius:4px; border:1px solid var(--border);">
      <span id="geminiModeLabel" style="color:var(--green);">🔑 API Key saved in browser</span>
      <button id="btnClearGeminiKey" style="padding:1px 6px; font-size:10.5px;">Change / Clear Key</button>
    </div>

    <div style="display:flex; flex-wrap:wrap; gap:5px;">
      <button type="button" class="gemini-chip" data-prompt="Explain what Prism is doing at this exact step and why.">Explain this step</button>
      <button type="button" class="gemini-chip" data-prompt="Explain why the lexer cursor rewound or jumped in this trace and how lex_modes / next_start / heredoc_end caused it.">Why did the cursor rewind?</button>
      <button type="button" class="gemini-chip" data-prompt="Diagnose any syntax error, parser recovery, or unexpected state transition in this trace and point to the responsible Prism mechanism.">Diagnose error / recovery</button>
      <button type="button" class="gemini-chip" data-prompt="Explain the current AST assembly and why there are superseded/orphaned nodes in the arena.">Explain AST &amp; arenas</button>
    </div>

    <div style="display:flex; gap:5px;">
      <input type="text" id="geminiPromptInput" placeholder="Ask Gemini about this step or trace (Enter to send)..." style="flex:1; min-width:0; background:#090d13; color:var(--text); border:1px solid var(--border); border-radius:5px; padding:6px 9px; font-size:12px;">
      <button id="btnSendGemini" class="primary">Ask</button>
    </div>

    <div id="geminiOutput" class="gemini-output">Select a prompt chip above or type a question to analyze the current trace step with Gemini.</div>
  </div>
</div>

<script>
const PRESETS = __PRESETS_JSON__;
const WASM_BASE64 = "__WASM_BASE64__";
const REPO_ROOT_STORAGE = 'prism_trace_repo_root';

function getRepoRoot() {
  const saved = localStorage.getItem(REPO_ROOT_STORAGE);
  return saved ? saved.trim().replace(/\/+$/, '') : '';
}

let wasmBytes = null;
let wasmExports = null;
let currentTrace = null;
let currentIdx = 0;
let hoverRange = null;
let playInterval = null;

function stopPlayback() {
  if (playInterval !== null) {
    clearInterval(playInterval);
    playInterval = null;
  }
  const btn = document.getElementById('btnPlayPause');
  if (btn) btn.innerHTML = '&#9654; Play';
}

function togglePlayback() {
  if (!currentTrace || currentTrace.steps.length <= 1) return;
  if (playInterval !== null) {
    stopPlayback();
    return;
  }
  if (currentIdx >= currentTrace.steps.length - 1) {
    currentIdx = 0;
    renderStep();
  }
  const btn = document.getElementById('btnPlayPause');
  btn.innerHTML = '&#9208; Pause';
  playInterval = setInterval(() => {
    if (!currentTrace || currentIdx >= currentTrace.steps.length - 1) {
      stopPlayback();
      return;
    }
    currentIdx++;
    renderStep();
    if (currentIdx >= currentTrace.steps.length - 1) {
      stopPlayback();
    }
  }, 1000);
}

const presetSelect = document.getElementById('presetSelect');
PRESETS.forEach((p, i) => {
  const opt = document.createElement('option');
  opt.value = i;
  opt.textContent = p.name;
  presetSelect.appendChild(opt);
});

async function initWasm() {
  const statusEl = document.getElementById('wasmStatus');
  if (!WASM_BASE64) {
    statusEl.textContent = 'Wasm: not embedded';
    return;
  }
  try {
    if (!wasmBytes) {
      const binStr = atob(WASM_BASE64);
      wasmBytes = new Uint8Array(binStr.length);
      for (let i = 0; i < binStr.length; i++) wasmBytes[i] = binStr.charCodeAt(i);
    }

    const wasiImport = new Proxy({
      proc_exit: (c) => { throw new Error('WASI proc_exit(' + c + ')'); }
    }, {
      get: (t, p) => (p in t ? t[p] : () => 0)
    });

    const { instance } = await WebAssembly.instantiate(wasmBytes, { wasi_snapshot_preview1: wasiImport });
    if (instance.exports._initialize) instance.exports._initialize();
    wasmExports = instance.exports;
    if (!statusEl.innerHTML.includes('Crash captured')) {
      statusEl.innerHTML = '<span style="color:var(--green)">● Wasm ready (in-browser Prism)</span>';
    }
  } catch (err) {
    statusEl.innerHTML = `<span style="color:var(--red)">Wasm init error: ${err.message}</span>`;
  }
}

async function parseWithWasm(rubyCode, label = 'Live Wasm Parse') {
  if (!wasmExports) {
    await initWasm();
    if (!wasmExports) {
      alert('Wasm module is not initialized yet.');
      return;
    }
  }
  const t0 = performance.now();
  const srcBytes = new TextEncoder().encode(rubyCode);
  const srcPtr = wasmExports.malloc(Math.max(1, srcBytes.length));
  new Uint8Array(wasmExports.memory.buffer, srcPtr, srcBytes.length).set(srcBytes);

  const bufPtr = wasmExports.pm_buffer_new();
  let trappedError = null;

  try {
    wasmExports.prism_trace_run_to_buffer(bufPtr, srcPtr, srcBytes.length, 50000);
  } catch (err) {
    trappedError = err;
  }

  // Read pm_buffer_t { size_t length (0); size_t capacity (4); char *value (8); } directly
  // from Wasm linear memory so we can recover all emitted JSONL lines even after a trap!
  const dv = new DataView(wasmExports.memory.buffer, bufPtr, 12);
  const outLen = dv.getUint32(0, true);
  const outPtr = dv.getUint32(8, true);
  const jsonlText = (outPtr && outLen)
    ? new TextDecoder().decode(new Uint8Array(wasmExports.memory.buffer, outPtr, outLen))
    : '';

  if (!trappedError) {
    wasmExports.pm_buffer_free(bufPtr);
    wasmExports.free(srcPtr);
  } else {
    wasmExports = null;
    initWasm();
  }

  const lines = [];
  jsonlText.split(/\r?\n/).forEach(l => {
    if (!l.trim()) return;
    try { lines.push(JSON.parse(l)); } catch (_) {}
  });

  const meta = lines[0] || { source: rubyCode };
  const steps = lines.slice(1);
  const lastStep = steps[steps.length - 1];

  if (trappedError && (!lastStep || lastStep.kind !== 'CRASH')) {
    const base = lastStep || {
      prev: [-1, -1, 'NOT_PROVIDED'],
      curr: [-1, -1, 'NOT_PROVIDED'],
      next_start: -1,
      heredoc_end: -1,
      lex_state: 'NONE',
      lex_modes: [],
      contexts: [],
      call_stack: [],
      line_offsets: [0],
      errors: 0,
      func: 'pm_parse',
      line: 0
    };
    steps.push({
      ...base,
      step: steps.length,
      kind: 'CRASH',
      detail: {
        reason: 'WASM_TRAP',
        expr: trappedError.message || String(trappedError),
        file: 'src/prism.c',
        line: base.line || 0,
        func: base.func || 'pm_parse'
      }
    });
  }

  const dt = (performance.now() - t0).toFixed(1);
  loadTrace({ name: label, source: meta.source, steps }, false);

  const hasCrash = currentTrace._crashIdx >= 0;
  const hasUnderflow = currentTrace._underflowIdx >= 0;

  if (hasCrash) {
    document.getElementById('wasmStatus').innerHTML =
      `<span style="color:var(--red);font-weight:700;">💥 Crash captured at step ${steps.length - 1} (${dt} ms) — Wasm reset</span>`;
  } else if (hasUnderflow) {
    const uStep = currentTrace.steps[currentTrace._underflowIdx];
    document.getElementById('wasmStatus').innerHTML =
      `<span style="color:var(--red);font-weight:700;">⚠ Corrupted node (underflow) at step ${uStep.step} (${dt} ms)</span>`;
  } else {
    document.getElementById('wasmStatus').innerHTML =
      `<span style="color:var(--green)">● Traced ${steps.length} steps in ${dt} ms</span>`;
  }
}

function formatBytes(b) {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(2)} KB`;
  return `${(b / (1024 * 1024)).toFixed(2)} MB`;
}

function preprocessTrace(trace) {
  let lastAst = [];
  let lastChangedNodeId = -1;
  let prevCurrStart = 0;
  let prevAstU = 0, prevMetaU = 0, prevScratchU = 0, prevTotalU = 0;
  const prevUnderflowById = new Map();
  trace._crashIdx = -1;
  trace._underflowIdx = -1;
  trace._underflowSteps = [];
  trace._underflowEvents = [];
  trace._underflowFirstStepByNode = {};
  trace._peakMemUsed = 0;
  trace.steps.forEach((s, i) => {
    const newUnderflows = [];
    if (s.ast) {
      lastAst = s.ast;
      s.ast.forEach(n => {
        const isU = Boolean(n.underflow || n.end < n.start);
        const wasU = prevUnderflowById.get(n.id) || false;
        if (isU && !wasU) {
          newUnderflows.push(n);
          if (trace._underflowFirstStepByNode[n.id] === undefined) {
            trace._underflowFirstStepByNode[n.id] = i;
          }
          trace._underflowEvents.push({
            stepIdx: i,
            step: s.step,
            node: n,
            func: s.func,
            line: s.line,
            file: stepSourceFile(s),
            callStack: s.call_stack || []
          });
        }
        prevUnderflowById.set(n.id, isU);
      });
    }
    if (s.detail && s.detail.node_id) {
      lastChangedNodeId = s.detail.node_id;
    } else if (newUnderflows.length > 0) {
      lastChangedNodeId = newUnderflows[0].id;
    }
    s._astSnapshot = lastAst;
    s._lastChangedNodeId = lastChangedNodeId;
    s._newUnderflows = newUnderflows;
    s._hasNewUnderflow = newUnderflows.length > 0;
    if (s._hasNewUnderflow) {
      if (trace._underflowIdx < 0) trace._underflowIdx = i;
      trace._underflowSteps.push(i);
    }
    s._isRewind = (i > 0 && s.curr[0] >= 0 && prevCurrStart >= 0 && s.curr[0] < prevCurrStart);
    s._rewindDelta = s._isRewind ? (s.curr[0] - prevCurrStart) : 0;
    if (s.curr[0] >= 0) prevCurrStart = s.curr[0];
    if (s.kind === 'CRASH') trace._crashIdx = i;

    const m = s.mem || { ast: [0, 0, 0], meta: [0, 0, 0], scratch: [0, 0, 0], lo: [0, 0], cp: [0, 0] };
    const astU = m.ast[0] || 0;
    const metaU = m.meta[0] || 0;
    const scratchU = m.scratch[0] || 0;
    const totalU = astU + metaU + scratchU;
    const totalCap = (m.ast[1] || 0) + (m.meta[1] || 0) + (m.scratch[1] || 0);

    s._astDelta = i > 0 ? Math.max(0, astU - prevAstU) : 0;
    s._metaDelta = i > 0 ? Math.max(0, metaU - prevMetaU) : 0;
    s._scratchDelta = i > 0 ? Math.max(0, scratchU - prevScratchU) : 0;
    s._memDelta = i > 0 ? Math.max(0, totalU - prevTotalU) : 0;
    s._memTotalUsed = totalU;
    s._memTotalCap = totalCap;
    if (totalU > trace._peakMemUsed) trace._peakMemUsed = totalU;

    prevAstU = astU;
    prevMetaU = metaU;
    prevScratchU = scratchU;
    prevTotalU = totalU;
  });
}

function setEditMode(editing) {
  if (editing) stopPlayback();
  const srcBox = document.getElementById('sourceBox');
  const editor = document.getElementById('rubyEditor');
  const btnEdit = document.getElementById('btnEditSource');
  const btnRun = document.getElementById('btnRunWasm');
  const btnCancel = document.getElementById('btnCancelEdit');
  if (editing) {
    editor.value = currentTrace ? currentTrace.source : '';
    const h = Math.max(220, srcBox.getBoundingClientRect().height);
    editor.style.height = h + 'px';
    srcBox.style.display = 'none';
    editor.style.display = 'block';
    btnEdit.style.display = 'none';
    btnRun.style.display = 'inline-block';
    btnCancel.style.display = 'inline-block';
    editor.focus();
  } else {
    editor.style.display = 'none';
    srcBox.style.display = 'block';
    btnEdit.style.display = 'inline-block';
    btnRun.style.display = 'none';
    btnCancel.style.display = 'none';
  }
}

function loadTrace(trace, syncEditor = true) {
  stopPlayback();
  setEditMode(false);
  preprocessTrace(trace);
  currentTrace = trace;
  currentIdx = 0;
  if (syncEditor) {
    document.getElementById('rubyEditor').value = trace.source;
  }
  renderTimeline();
  renderStep();
}

function renderTimeline() {
  const track = document.getElementById('timelineTrack');
  track.querySelectorAll('.timeline-marker').forEach(el => el.remove());
  const total = currentTrace.steps.length;
  if (total <= 1) return;

  currentTrace.steps.forEach((s, idx) => {
    let color = null;
    let width = '2px';
    let zIndex = 1;
    let shadow = '';
    if (s.kind === 'CRASH') {
      color = 'var(--red)';
      width = '6px';
      zIndex = 2;
      shadow = '0 0 6px var(--red)';
    } else if (s._hasNewUnderflow) {
      color = 'var(--red)';
      width = '5px';
      zIndex = 2;
      shadow = '0 0 5px var(--red)';
    } else if (s.kind === 'ERROR') {
      color = 'var(--pink)';
      width = '3px';
    } else if (s._isRewind) {
      color = 'var(--amber)';
    } else if (s.kind === 'NODE_NEW' || s.kind === 'NODE_LIST_APPEND') {
      color = 'var(--accent)';
    } else if (s.kind === 'LEX_TOKEN') {
      color = 'rgba(63, 185, 80, 0.45)';
    }
    if (color) {
      const ratio = idx / (total - 1);
      const m = document.createElement('div');
      m.className = 'timeline-marker';
      m.style.left = (ratio * 100) + '%';
      m.style.transform = `translateX(-${ratio * 100}%)`;
      m.style.width = width;
      m.style.zIndex = zIndex;
      m.style.background = color;
      if (shadow) m.style.boxShadow = shadow;
      track.appendChild(m);
    }
  });
}

function escapeHtml(str) {
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function stepSourceFile(step) {
  if (step.detail && step.detail.file) {
    const f = step.detail.file;
    return f.includes('/') ? f : ('src/' + f);
  }
  if (step.func.startsWith('pm_') && step.func.endsWith('_new')) return 'src/node.c';
  return 'src/prism.c';
}

function renderSource(step, autoScroll = false) {
  const src = currentTrace.source;
  const box = document.getElementById('sourceBox');
  const paneBody = box.closest('.pane-body');
  const prevScrollTop = paneBody ? paneBody.scrollTop : 0;
  const prevScrollLeft = box.scrollLeft;
  box.innerHTML = '';

  const [prevS, prevE] = step.prev;
  const [currS, currE] = step.curr;

  let focusOffset = (hoverRange && hoverRange[0] >= 0)
    ? hoverRange[0]
    : (currE >= 0 ? currE : (currS >= 0 ? currS : (prevE >= 0 ? prevE : 0)));
  if (!hoverRange && (step.kind === 'ERROR' || step.kind === 'NODE_NEW') && step.detail && typeof step.detail.start === 'number') {
    focusOffset = step.detail.start;
  }
  focusOffset = Math.max(0, Math.min(src.length, focusOffset));

  let lineNum = 1;
  let lineDiv = document.createElement('div');
  lineDiv.className = 'src-line';
  const makeGutter = (ln, off) => {
    const g = document.createElement('span');
    g.className = 'line-gutter';
    g.textContent = `${ln}`;
    g.title = `Line ${ln} (starts at byte offset ${off})`;
    return g;
  };
  lineDiv.appendChild(makeGutter(lineNum, 0));

  let focusCell = null;

  for (let i = 0; i <= src.length; i++) {
    const ch = i < src.length ? src[i] : 'EOF';
    const cell = document.createElement('span');
    cell.className = 'char-cell';
    cell.title = `Line ${lineNum}, Byte offset ${i}`;

    if (i >= prevS && i < prevE) cell.classList.add('in-prev');
    if (i >= currS && i < currE) cell.classList.add('in-curr');
    else if (currS >= 0 && currS === currE && i === currS) cell.classList.add('curr-caret');
    if (hoverRange && i >= hoverRange[0] && i < hoverRange[1]) {
      cell.classList.add('in-ast-hover');
    }
    if (i === focusOffset) {
      focusCell = cell;
      lineDiv.classList.add('active-line');
    }

    const txt = document.createElement('span');
    if (ch === '\n') {
      cell.classList.add('nl-char');
      txt.textContent = '\\n';
    } else if (ch === '\r') {
      cell.classList.add('nl-char');
      txt.textContent = '\\r';
    } else if (ch === 'EOF') {
      cell.classList.add('nl-char');
      txt.textContent = '␄';
    } else {
      txt.textContent = ch;
    }
    cell.appendChild(txt);
    lineDiv.appendChild(cell);

    if (ch === '\n') {
      box.appendChild(lineDiv);
      lineNum++;
      lineDiv = document.createElement('div');
      lineDiv.className = 'src-line';
      lineDiv.appendChild(makeGutter(lineNum, i + 1));
    }
  }
  box.appendChild(lineDiv);
  if (paneBody) paneBody.scrollTop = prevScrollTop;
  box.scrollLeft = prevScrollLeft;

  if (autoScroll && focusCell) {
    if (paneBody) {
      const paneRect = paneBody.getBoundingClientRect();
      const cellRect = focusCell.getBoundingClientRect();
      const relTop = cellRect.top - paneRect.top;
      const marginY = paneRect.height * 0.22;
      if (relTop < marginY || relTop + cellRect.height > paneRect.height - marginY) {
        paneBody.scrollTop += relTop - (paneRect.height / 2) + (cellRect.height / 2);
      }
    }
    const boxRect = box.getBoundingClientRect();
    const cellRect = focusCell.getBoundingClientRect();
    const relLeft = cellRect.left - boxRect.left;
    const marginX = boxRect.width * 0.2;
    if (relLeft < marginX || relLeft + cellRect.width > boxRect.width - marginX) {
      box.scrollLeft += relLeft - (boxRect.width / 2) + (cellRect.width / 2);
    }
  }
}

function jumpToStep(idx) {
  currentIdx = Math.max(0, Math.min(currentTrace.steps.length - 1, idx));
  renderStep();
}

function hasStepInDir(dir, pred) {
  let i = currentIdx + dir;
  while (i >= 0 && i < currentTrace.steps.length) {
    if (pred(currentTrace.steps[i])) return true;
    i += dir;
  }
  return false;
}

function updateNavButtons() {
  const total = currentTrace.steps.length;
  document.getElementById('btnPrev').disabled = currentIdx <= 0;
  document.getElementById('btnNext').disabled = currentIdx >= total - 1;
  document.getElementById('btnPrevTok').disabled = !hasStepInDir(-1, s => s.kind === 'LEX_TOKEN');
  document.getElementById('btnNextTok').disabled = !hasStepInDir(1, s => s.kind === 'LEX_TOKEN');
  document.getElementById('btnPrevAst').disabled = !hasStepInDir(-1, s => s.kind === 'NODE_NEW' || s.kind === 'NODE_LIST_APPEND');
  document.getElementById('btnNextAst').disabled = !hasStepInDir(1, s => s.kind === 'NODE_NEW' || s.kind === 'NODE_LIST_APPEND');
  document.getElementById('btnPrevAlloc').disabled = !hasStepInDir(-1, s => s._memDelta > 0);
  document.getElementById('btnNextAlloc').disabled = !hasStepInDir(1, s => s._memDelta > 0);
  document.getElementById('btnPrevRewind').disabled = !hasStepInDir(-1, s => s._isRewind);
  document.getElementById('btnNextRewind').disabled = !hasStepInDir(1, s => s._isRewind);
  const btnUnderflow = document.getElementById('btnJumpUnderflow');
  const uSteps = currentTrace._underflowSteps || [];
  btnUnderflow.disabled = !(uSteps.length > 0 && (uSteps.length > 1 || currentIdx !== uSteps[0]));
  const btnCrash = document.getElementById('btnJumpCrash');
  btnCrash.disabled = !(currentTrace._crashIdx >= 0 && currentIdx !== currentTrace._crashIdx);
}

function renderStep() {
  if (!currentTrace || currentTrace.steps.length === 0) return;
  const step = currentTrace.steps[currentIdx];
  const total = currentTrace.steps.length;

  updateNavButtons();
  document.getElementById('stepCounter').textContent = `Step ${step.step} / ${total - 1}`;
  const ratio = total > 1 ? (currentIdx / (total - 1)) : 0;
  const pct = (ratio * 100) + '%';
  const xform = `translateX(-${ratio * 100}%)`;
  const tp = document.getElementById('timelinePlayhead');
  tp.style.left = pct;
  tp.style.transform = xform;

  const srcFile = stepSourceFile(step);

  const cb = document.getElementById('crashBanner');
  const btnCrash = document.getElementById('btnJumpCrash');
  if (currentTrace._crashIdx >= 0) {
    const crashStep = currentTrace.steps[currentTrace._crashIdx];
    const cd = crashStep.detail || {};
    const cFile = stepSourceFile(crashStep);
    cb.style.display = 'block';
    btnCrash.style.display = 'inline-block';
    btnCrash.disabled = (currentIdx === currentTrace._crashIdx);
    const jumpBtn = currentIdx !== currentTrace._crashIdx
      ? `<button class="warn" style="margin-left:8px;padding:2px 7px;" onclick="jumpToStep(${currentTrace._crashIdx})">Jump to Crash Step #${crashStep.step}</button>`
      : `<span class="badge kind-CRASH" style="margin-left:8px;">AT CRASH POINT</span>`;
    cb.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <strong>💥 PRISM CRASH INTERCEPTED (${escapeHtml(cd.reason || 'CRASH')})</strong>
        ${jumpBtn}
      </div>
      <div style="margin-top:4px;color:var(--text);">
        <code>assert(${escapeHtml(cd.expr || '')})</code> failed in <code>${escapeHtml(cd.func || crashStep.func)}()</code> at <code>${escapeHtml(cFile)}:${cd.line || crashStep.line}</code>
      </div>
    `;
  } else {
    cb.style.display = 'none';
    btnCrash.style.display = 'none';
  }

  const ub = document.getElementById('underflowBanner');
  const btnUnderflow = document.getElementById('btnJumpUnderflow');
  const uEvents = currentTrace._underflowEvents || [];
  const uSteps = currentTrace._underflowSteps || [];
  if (uEvents.length > 0) {
    ub.style.display = 'block';
    btnUnderflow.style.display = 'inline-block';
    btnUnderflow.disabled = (uSteps.length === 1 && currentIdx === uSteps[0]);
    const atUnderflowStep = uSteps.includes(currentIdx);
    const nextUStepIdx = uSteps.find(idx => idx > currentIdx) ?? uSteps[0];
    const nextUStep = currentTrace.steps[nextUStepIdx];
    let headerActionHtml = '';
    if (!atUnderflowStep) {
      headerActionHtml = `<button class="warn" style="margin-left:8px;padding:2px 7px;" onclick="jumpToStep(${nextUStepIdx})">Jump to Detection Step #${nextUStep.step}</button>`;
    } else if (uSteps.length > 1) {
      headerActionHtml = `
        <span style="display:inline-flex;align-items:center;gap:6px;margin-left:8px;">
          <span class="badge kind-CRASH">AT DETECTION STEP #${step.step}</span>
          <button class="warn" style="padding:2px 7px;" onclick="jumpToStep(${nextUStepIdx})">Next Underflow (#${nextUStep.step}) &rarr;</button>
        </span>
      `;
    } else {
      headerActionHtml = `<span class="badge kind-CRASH" style="margin-left:8px;">AT DETECTION STEP</span>`;
    }
    const itemsHtml = uEvents.map(ev => {
      const caller = ev.callStack.length > 0 ? ev.callStack[ev.callStack.length - 1] : null;
      const callerStr = (caller && caller !== ev.func) ? ` via <code>${escapeHtml(caller)}()</code>` : '';
      const stepBtn = (uEvents.length > 1 && currentIdx !== ev.stepIdx)
        ? ` <button class="warn" style="padding:1px 6px;font-size:11px;margin-left:4px;" onclick="jumpToStep(${ev.stepIdx})">Step #${ev.step}</button>`
        : '';
      return `
        <div style="margin-top:4px;color:var(--text);">
          Node <code>#${ev.node.id} ${escapeHtml(ev.node.type)}</code> underflowed (<code>start=${ev.node.start}, end=${ev.node.end}, len=${ev.node.len}</code>) in <code>${escapeHtml(ev.func)}()</code>${callerStr} at <code>${escapeHtml(ev.file)}:${ev.line}</code>${stepBtn}
        </div>
      `;
    }).join('');
    ub.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <strong>⚠ CORRUPTED AST NODE DETECTED (${uEvents.length === 1 ? 'LOCATION UNDERFLOW' : uEvents.length + ' LOCATION UNDERFLOWS'})</strong>
        ${headerActionHtml}
      </div>
      ${itemsHtml}
    `;
  } else {
    ub.style.display = 'none';
    btnUnderflow.style.display = 'none';
  }

  const rb = document.getElementById('rewindBanner');
  if (step._isRewind) {
    rb.style.display = 'block';
    rb.textContent = `↺ Cursor Rewind: current.start moved backward by ${step._rewindDelta} bytes (to offset ${step.curr[0]})`;
  } else {
    rb.style.display = 'none';
  }

  renderSource(step, true);

  const bindOffsetHover = (el, startOff, endOff = startOff + 1) => {
    if (startOff < 0) return;
    el.style.cursor = 'pointer';
    el.addEventListener('mouseenter', () => {
      hoverRange = [startOff, Math.max(startOff + 1, endOff)];
      renderSource(currentTrace.steps[currentIdx], true);
    });
    el.addEventListener('mouseleave', () => {
      hoverRange = null;
      renderSource(currentTrace.steps[currentIdx], false);
    });
  };

  const loBox = document.getElementById('lineOffsetsBox');
  loBox.innerHTML = '';
  let badOffsets = 0;
  step.line_offsets.forEach((off, idx) => {
    const chip = document.createElement('span');
    const isBad = idx > 0 && off <= step.line_offsets[idx - 1];
    if (isBad) badOffsets++;
    chip.className = 'offset-chip' + (isBad ? ' bad' : '');
    chip.textContent = `L${idx + 1}:@${off}`;
    chip.title = `Hover to highlight byte offset ${off} in source buffer`;
    bindOffsetHover(chip, off);
    loBox.appendChild(chip);
  });
  const loStatus = document.getElementById('lineOffsetStatus');
  if (badOffsets > 0) {
    loStatus.innerHTML = `<span style="color:var(--red);font-weight:700;">⚠ ${badOffsets} duplicate/out-of-order newline offset(s)!</span>`;
  } else {
    loStatus.textContent = `${step.line_offsets.length} line(s)`;
  }

  const prevSlice = currentTrace.source.slice(Math.max(0, step.prev[0]), Math.max(0, step.prev[1]));
  const currSlice = currentTrace.source.slice(Math.max(0, step.curr[0]), Math.max(0, step.curr[1]));
  const detailStr = step.detail ? JSON.stringify(step.detail) : '—';
  const repoRoot = getRepoRoot();
  let agyPillHtml = '';
  if (repoRoot) {
    const absFile = `${repoRoot}/${srcFile}`.replace(/\/+/g, '/');
    const agyHref = `antigravity-ide://file${absFile.startsWith('/') ? '' : '/'}${absFile}:${step.line}`;
    agyPillHtml = ` <a id="btnOpenAgyIde" class="copy-pill" href="${escapeHtml(agyHref)}" style="text-decoration:none;" title="Open ${escapeHtml(absFile)}:${step.line} in Antigravity IDE and copy trace context to clipboard">↗ Antigravity IDE</a>`;
  }
  const tg = document.getElementById('transitionGrid');
  tg.innerHTML = `
    <div class="kv-key">Event Kind</div><div><span class="badge kind-${step.kind}">${step.kind}</span></div>
    <div class="kv-key">Location</div><div>
      <code>${srcFile}:${step.line}</code> in <code>${step.func}()</code>${agyPillHtml}
    </div>
    <div class="kv-key">lex_state</div><div><span class="badge kind-LEX_STATE">${step.lex_state}</span></div>
    <div class="kv-key" style="color:var(--green)">current token</div><div id="kvCurrTok"><code style="color:var(--green)">${step.curr[2]}</code> [${step.curr[0]}..${step.curr[1]}] <code>${escapeHtml(JSON.stringify(currSlice))}</code></div>
    <div class="kv-key" style="color:var(--amber)">previous token</div><div id="kvPrevTok"><code style="color:var(--amber)">${step.prev[2]}</code> [${step.prev[0]}..${step.prev[1]}] <code>${escapeHtml(JSON.stringify(prevSlice))}</code></div>
    <div class="kv-key">next_start</div><div id="kvNextStart">${step.next_start >= 0 ? '<code>offset ' + step.next_start + '</code>' : '<span style="color:var(--muted)">NULL</span>'}</div>
    <div class="kv-key">heredoc_end</div><div id="kvHeredocEnd">${step.heredoc_end >= 0 ? '<code>offset ' + step.heredoc_end + '</code>' : '<span style="color:var(--muted)">NULL</span>'}</div>
    <div class="kv-key">Errors</div><div>${step.errors}</div>
    <div class="kv-key">Detail</div><div><code>${escapeHtml(detailStr)}</code></div>
  `;
  const agyPill = document.getElementById('btnOpenAgyIde');
  if (agyPill) {
    agyPill.addEventListener('click', () => {
      const md = buildGeminiContextMarkdown(step);
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(md).catch(() => {});
      }
      const old = agyPill.textContent;
      agyPill.textContent = '✓ Context Copied!';
      setTimeout(() => { agyPill.textContent = old; }, 1600);
    });
  }
  bindOffsetHover(document.getElementById('kvCurrTok'), step.curr[0], step.curr[1]);
  bindOffsetHover(document.getElementById('kvPrevTok'), step.prev[0], step.prev[1]);
  if (step.next_start >= 0) bindOffsetHover(document.getElementById('kvNextStart'), step.next_start);
  if (step.heredoc_end >= 0) bindOffsetHover(document.getElementById('kvHeredocEnd'), step.heredoc_end);

  const lmBox = document.getElementById('lexModesStack');
  lmBox.innerHTML = '';
  step.lex_modes.forEach((m, idx) => {
    const div = document.createElement('div');
    div.className = `stack-frame mode-${m.mode}`;
    let extra = '';
    if (m.mode === 'HEREDOC') {
      extra = `ident=${JSON.stringify(m.ident)} indent=${m.indent} next_start=${m.next_start >= 0 ? m.next_start : 'NULL'}`;
      if (m.next_start >= 0) {
        div.title = `Hover to highlight saved next_start offset ${m.next_start} in source buffer`;
        bindOffsetHover(div, m.next_start);
      }
    } else if (m.mode === 'STRING' || m.mode === 'LIST') {
      extra = `term='${String.fromCharCode(m.term || 0)}' interp=${m.interp} nest=${m.nesting}`;
    }
    div.innerHTML = `<span style="white-space:nowrap;">${idx === 0 ? '▸ ' : ''}${m.mode}</span><span style="color:var(--muted);text-align:right;">${escapeHtml(extra)}</span>`;
    lmBox.appendChild(div);
  });

  document.getElementById('contextsBox').textContent =
    step.contexts.length ? step.contexts.join(' → ') : '(empty / top-level)';

  const csBox = document.getElementById('callStackBox');
  csBox.innerHTML = '';
  document.getElementById('callDepthBadge').textContent = `depth: ${step.call_stack.length}`;
  [...step.call_stack].reverse().forEach((fn, idx) => {
    const div = document.createElement('div');
    div.className = 'stack-frame';
    div.innerHTML = `<span>${idx === 0 ? '▸ ' : ''}${fn}()</span><span style="color:var(--muted)">#${step.call_stack.length - idx}</span>`;
    csBox.appendChild(div);
  });

  renderMemoryTelemetry(step);
  renderAstForest(step);
  updateGeminiDomContext(step);
}

function buildGeminiContextMarkdown(step) {
  if (!currentTrace || !step) return '';
  const total = currentTrace.steps.length;
  const srcFile = stepSourceFile(step);
  const currSlice = currentTrace.source.slice(Math.max(0, step.curr[0]), Math.max(0, step.curr[1]));
  const prevSlice = currentTrace.source.slice(Math.max(0, step.prev[0]), Math.max(0, step.prev[1]));
  const startWin = Math.max(0, currentIdx - 6);
  const endWin = Math.min(total - 1, currentIdx + 6);
  const nearby = [];
  for (let i = startWin; i <= endWin; i++) {
    const s = currentTrace.steps[i];
    const marker = i === currentIdx ? '>>> ' : '    ';
    nearby.push(`${marker}Step ${s.step}: ${s.kind} in ${s.func}() (${stepSourceFile(s)}:${s.line}) curr=${s.curr[2]}[${s.curr[0]}..${s.curr[1]}] lex_state=${s.lex_state}${s._isRewind ? ' [REWIND ' + s._rewindDelta + 'B]' : ''}`);
  }
  const nodes = step._astSnapshot || [];
  const underflows = nodes.filter(n => n.underflow || n.end < n.start);
  const crashStep = currentTrace._crashIdx >= 0 ? currentTrace.steps[currentTrace._crashIdx] : null;

  return [
    `# Prism Ruby Parser Trace Context`,
    `- Trace Name: ${currentTrace.name}`,
    `- Ruby Source (${currentTrace.source.length} bytes): ${JSON.stringify(currentTrace.source)}`,
    `- Current Step: ${step.step} / ${total - 1}`,
    `- Event: ${step.kind} at ${srcFile}:${step.line} in ${step.func}()`,
    `- lex_state: ${step.lex_state}`,
    `- current token: ${step.curr[2]} [${step.curr[0]}..${step.curr[1]}] ${JSON.stringify(currSlice)}`,
    `- previous token: ${step.prev[2]} [${step.prev[0]}..${step.prev[1]}] ${JSON.stringify(prevSlice)}`,
    `- next_start: ${step.next_start}, heredoc_end: ${step.heredoc_end}`,
    `- lex_modes stack (top->bottom): ${JSON.stringify(step.lex_modes)}`,
    `- parser call_stack: ${step.call_stack.join(' -> ')}`,
    `- line_offsets (${step.line_offsets.length}): [${step.line_offsets.join(', ')}]`,
    `- Arena Memory Used/Cap: AST=${step.mem ? step.mem.ast[0] : 0}/${step.mem ? step.mem.ast[1] : 0}B, Meta=${step.mem ? step.mem.meta[0] : 0}/${step.mem ? step.mem.meta[1] : 0}B, Scratch=${step.mem ? step.mem.scratch[0] : 0}/${step.mem ? step.mem.scratch[1] : 0}B`,
    `- Allocated AST Nodes: ${nodes.length} (${underflows.length} underflowed locations)`,
    (currentTrace._underflowEvents && currentTrace._underflowEvents.length > 0)
      ? `- DETECTED CORRUPTED/UNDERFLOW NODES: ` + currentTrace._underflowEvents.map(ev => `#${ev.node.id} ${ev.node.type} [start=${ev.node.start}, end=${ev.node.end}, len=${ev.node.len}] detected at Step ${ev.step} in ${ev.func}() (${ev.file}:${ev.line})`).join('; ')
      : '',
    crashStep ? `- INTERCEPTED CRASH at Step ${crashStep.step}: ${JSON.stringify(crashStep.detail)}` : '',
    `\n## Surrounding Trace Steps (${startWin}..${endWin}):\n` + nearby.join('\n')
  ].filter(Boolean).join('\n');
}

function updateGeminiDomContext(step) {
  const el = document.getElementById('geminiPageContext');
  if (el) el.textContent = buildGeminiContextMarkdown(step);
}

function renderMemoryTelemetry(step) {
  const m = step.mem || { ast: [0, 0, 0], meta: [0, 0, 0], scratch: [0, 0, 0], lo: [0, 0], cp: [0, 0] };
  const badge = document.getElementById('memCardBadge');
  badge.innerHTML = step._memDelta > 0
    ? `<span class="mem-delta-pill">+${formatBytes(step._memDelta)} this step</span>`
    : `<span style="color:var(--muted)">peak: ${formatBytes(currentTrace._peakMemUsed || 0)}</span>`;

  const makeArenaRow = (label, arr, delta, color) => {
    const [used, cap, blocks] = arr;
    const pct = cap > 0 ? Math.min(100, (used / cap) * 100).toFixed(1) : 0;
    const dPill = delta > 0 ? `<span class="mem-delta-pill">+${formatBytes(delta)}</span>` : '';
    return `
      <div class="mem-row">
        <div class="mem-row-header">
          <span><span class="swatch" style="background:${color};margin-right:5px;"></span>${label}${dPill}</span>
          <span style="color:var(--muted)">
            <strong style="color:var(--text)">${formatBytes(used)}</strong> / ${formatBytes(cap)}
            (${blocks} blk${blocks === 1 ? '' : 's'}, ${pct}%)
          </span>
        </div>
        <div class="mem-bar-bg">
          <div class="mem-bar-fill" style="width:${pct}%;background:${color};"></div>
        </div>
      </div>
    `;
  };

  const [loSize, loCap] = m.lo || [0, 0];
  const [cpSize, cpCap] = m.cp || [0, 0];

  document.getElementById('memBreakdownBox').innerHTML = `
    ${makeArenaRow('AST Arena (<code>parser-&gt;arena</code>)', m.ast, step._astDelta, 'var(--accent)')}
    ${makeArenaRow('Metadata Arena (<code>metadata_arena</code>)', m.meta, step._metaDelta, 'var(--purple)')}
    ${makeArenaRow('Scratch Arena (<code>scratch_arena</code>)', m.scratch, step._scratchDelta, 'var(--cyan)')}
    <div style="display:flex;justify-content:space-between;font-family:var(--font-mono);font-size:11px;color:var(--muted);padding-top:4px;border-top:1px solid var(--border);">
      <span><code>line_offsets</code>: <strong style="color:var(--text)">${loSize}</strong>/${loCap} (${loSize * 4} B)</span>
      <span><code>constant_pool</code>: <strong style="color:var(--text)">${cpSize}</strong>/${cpCap}</span>
      <span>Total: <strong style="color:var(--text)">${formatBytes(step._memTotalUsed)}</strong>/${formatBytes(step._memTotalCap)}</span>
    </div>
  `;
}

function renderAstForest(step) {
  const nodes = step._astSnapshot || [];
  const treeBox = document.getElementById('astTreeBox');
  const orphansBox = document.getElementById('astOrphansBox');
  const astPaneBody = treeBox.closest('.pane-body');
  const prevAstScrollTop = astPaneBody ? astPaneBody.scrollTop : 0;
  treeBox.innerHTML = '';
  orphansBox.innerHTML = '';
  const underflowCount = nodes.filter(n => n.underflow || n.end < n.start).length;
  document.getElementById('astSummary').innerHTML = underflowCount > 0
    ? `<span style="color:var(--red);font-weight:700;">⚠ ${underflowCount} corrupted location(s) / ${nodes.length} nodes</span>`
    : `${nodes.length} allocated node(s)`;

  if (nodes.length === 0) {
    treeBox.innerHTML = '<span style="color:var(--muted)">(no AST nodes allocated yet)</span>';
    orphansBox.innerHTML = '<span style="color:var(--muted)">—</span>';
    return;
  }

  const byId = new Map();
  const hasParent = new Set();
  nodes.forEach(n => byId.set(n.id, n));
  nodes.forEach(n => {
    n.children.forEach(cid => hasParent.add(cid));
  });

  const changedNodeId = step._lastChangedNodeId || -1;
  const roots = nodes.filter(n => !hasParent.has(n.id));

  const activeRoots = [];
  const superseded = [];
  roots.forEach(r => {
    const isSuperseded = roots.some(other =>
      other.id > r.id &&
      other.start <= r.start &&
      other.end >= r.end &&
      (other.children.length > 0 || other.type.includes('WRITE') || other.type.includes('PROGRAM'))
    );
    if (isSuperseded) {
      superseded.push(r);
    } else {
      activeRoots.push(r);
    }
  });

  function buildNodeDom(n) {
    const wrapper = document.createElement('div');
    wrapper.className = 'ast-node';

    const isUnderflow = n.underflow || n.end < n.start;
    const detectIdx = isUnderflow && currentTrace._underflowFirstStepByNode
      ? currentTrace._underflowFirstStepByNode[n.id]
      : undefined;
    const row = document.createElement('div');
    row.className = 'ast-row' +
      (n.id === changedNodeId ? ' just-changed' : '') +
      (isUnderflow ? ' underflow-node' : '');
    const slice = isUnderflow
      ? `⚠ UNDERFLOW len=${n.len} (end=${n.end} < start=${n.start})`
      : JSON.stringify(currentTrace.source.slice(n.start, Math.min(n.end, n.start + 24)));
    const jumpPill = (typeof detectIdx === 'number' && detectIdx !== currentIdx)
      ? `<span class="copy-pill ast-jump-underflow" style="border-color:var(--red);color:#ffa198;" title="Jump to step #${currentTrace.steps[detectIdx].step} where this corrupted node was detected">↳ Jump to Step #${currentTrace.steps[detectIdx].step}</span>`
      : '';
    row.innerHTML = `
      <span class="ast-id">#${n.id}</span>
      <span>${n.type}</span>
      <span class="ast-loc">[${n.start}..${n.end}]</span>
      <span class="ast-slice" style="${isUnderflow ? 'color:var(--red);font-weight:700;' : ''}">${escapeHtml(slice)}</span>
      ${jumpPill}
    `;
    const jumpEl = row.querySelector('.ast-jump-underflow');
    if (jumpEl && typeof detectIdx === 'number') {
      jumpEl.addEventListener('click', (e) => {
        e.stopPropagation();
        jumpToStep(detectIdx);
      });
    }
    row.addEventListener('mouseenter', () => {
      hoverRange = isUnderflow ? [n.end, n.start] : [n.start, n.end];
      renderSource(currentTrace.steps[currentIdx]);
    });
    row.addEventListener('mouseleave', () => {
      hoverRange = null;
      renderSource(currentTrace.steps[currentIdx]);
    });
    wrapper.appendChild(row);

    n.children.forEach(cid => {
      const child = byId.get(cid);
      if (child) {
        wrapper.appendChild(buildNodeDom(child));
      }
    });
    return wrapper;
  }

  activeRoots.forEach(r => treeBox.appendChild(buildNodeDom(r)));
  if (superseded.length === 0) {
    orphansBox.innerHTML = '<span style="color:var(--muted)">(none)</span>';
  } else {
    superseded.forEach(r => orphansBox.appendChild(buildNodeDom(r)));
  }

  if (astPaneBody) astPaneBody.scrollTop = prevAstScrollTop;
  const changedRow = treeBox.querySelector('.just-changed') || orphansBox.querySelector('.just-changed');
  if (changedRow && astPaneBody) {
    const paneRect = astPaneBody.getBoundingClientRect();
    const rowRect = changedRow.getBoundingClientRect();
    const relTop = rowRect.top - paneRect.top;
    const marginY = paneRect.height * 0.18;
    if (relTop < marginY || relTop + rowRect.height > paneRect.height - marginY) {
      astPaneBody.scrollTop += relTop - (paneRect.height / 2) + (rowRect.height / 2);
    }
  }
}

function stepToKind(kinds, dir) {
  let i = currentIdx + dir;
  while (i >= 0 && i < currentTrace.steps.length) {
    if (kinds.includes(currentTrace.steps[i].kind)) {
      currentIdx = i;
      renderStep();
      return;
    }
    i += dir;
  }
}

document.getElementById('btnEditSource').addEventListener('click', () => {
  setEditMode(true);
});

document.getElementById('sourceBox').addEventListener('dblclick', () => {
  setEditMode(true);
});

document.getElementById('btnCancelEdit').addEventListener('click', () => {
  setEditMode(false);
});

document.getElementById('btnRunWasm').addEventListener('click', () => {
  parseWithWasm(document.getElementById('rubyEditor').value, 'Live Editor Input');
});

document.getElementById('rubyEditor').addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
    e.preventDefault();
    parseWithWasm(document.getElementById('rubyEditor').value, 'Live Editor Input');
  } else if (e.key === 'Escape') {
    e.preventDefault();
    setEditMode(false);
  }
});

document.getElementById('btnOpenRb').addEventListener('click', () => {
  document.getElementById('rbFileInput').click();
});

document.getElementById('btnOpenJsonl').addEventListener('click', () => {
  document.getElementById('fileInput').click();
});

document.getElementById('rbFileInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    document.getElementById('rubyEditor').value = reader.result;
    parseWithWasm(reader.result, file.name);
  };
  reader.readAsText(file);
});

document.getElementById('btnPlayPause').addEventListener('click', togglePlayback);
document.getElementById('btnPrev').addEventListener('click', () => jumpToStep(currentIdx - 1));
document.getElementById('btnNext').addEventListener('click', () => jumpToStep(currentIdx + 1));
document.getElementById('btnPrevTok').addEventListener('click', () => stepToKind(['LEX_TOKEN'], -1));
document.getElementById('btnNextTok').addEventListener('click', () => stepToKind(['LEX_TOKEN'], 1));
document.getElementById('btnPrevAst').addEventListener('click', () => stepToKind(['NODE_NEW', 'NODE_LIST_APPEND'], -1));
document.getElementById('btnNextAst').addEventListener('click', () => stepToKind(['NODE_NEW', 'NODE_LIST_APPEND'], 1));
function stepToAlloc(dir) {
  let i = currentIdx + dir;
  while (i >= 0 && i < currentTrace.steps.length) {
    if (currentTrace.steps[i]._memDelta > 0) {
      currentIdx = i;
      renderStep();
      return;
    }
    i += dir;
  }
}

function stepToRewind(dir) {
  let i = currentIdx + dir;
  while (i >= 0 && i < currentTrace.steps.length) {
    if (currentTrace.steps[i]._isRewind) {
      currentIdx = i;
      renderStep();
      return;
    }
    i += dir;
  }
}

document.getElementById('btnPrevAlloc').addEventListener('click', () => stepToAlloc(-1));
document.getElementById('btnNextAlloc').addEventListener('click', () => stepToAlloc(1));
document.getElementById('btnPrevRewind').addEventListener('click', () => stepToRewind(-1));
document.getElementById('btnNextRewind').addEventListener('click', () => stepToRewind(1));
document.getElementById('btnJumpUnderflow').addEventListener('click', () => {
  if (currentTrace && currentTrace._underflowSteps && currentTrace._underflowSteps.length > 0) {
    const uSteps = currentTrace._underflowSteps;
    const nextIdx = uSteps.find(idx => idx > currentIdx) ?? uSteps[0];
    jumpToStep(nextIdx);
  }
});
document.getElementById('btnJumpCrash').addEventListener('click', () => {
  if (currentTrace && currentTrace._crashIdx >= 0) {
    jumpToStep(currentTrace._crashIdx);
  }
});

function attachTrackScrubber(trackEl) {
  let dragging = false;
  const scrubAt = (clientX) => {
    if (!currentTrace || currentTrace.steps.length === 0) return;
    const rect = trackEl.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    const nextIdx = Math.round(ratio * (currentTrace.steps.length - 1));
    if (nextIdx !== currentIdx) {
      currentIdx = nextIdx;
      renderStep();
    }
  };
  trackEl.addEventListener('pointerdown', (e) => {
    stopPlayback();
    dragging = true;
    trackEl.setPointerCapture(e.pointerId);
    scrubAt(e.clientX);
  });
  trackEl.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    scrubAt(e.clientX);
  });
  const stopDrag = (e) => {
    if (!dragging) return;
    dragging = false;
    if (trackEl.hasPointerCapture(e.pointerId)) {
      trackEl.releasePointerCapture(e.pointerId);
    }
  };
  trackEl.addEventListener('pointerup', stopDrag);
  trackEl.addEventListener('pointercancel', stopDrag);
}
attachTrackScrubber(document.getElementById('timelineTrack'));

presetSelect.addEventListener('change', (e) => {
  loadTrace(PRESETS[parseInt(e.target.value, 10)]);
});

document.getElementById('fileInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const lines = reader.result.split(/\r?\n/).filter(Boolean).map(l => JSON.parse(l));
    const meta = lines[0];
    const steps = lines.slice(1);
    loadTrace({ name: file.name, source: meta.source, steps });
  };
  reader.readAsText(file);
});

window.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT' || e.target.tagName === 'TEXTAREA') return;
  if (e.key === ' ') { e.preventDefault(); togglePlayback(); }
  else if (e.key === 'ArrowRight' && e.shiftKey) { e.preventDefault(); stepToKind(['LEX_TOKEN'], 1); }
  else if (e.key === 'ArrowLeft' && e.shiftKey) { e.preventDefault(); stepToKind(['LEX_TOKEN'], -1); }
  else if (e.key === 'ArrowRight') { e.preventDefault(); jumpToStep(currentIdx + 1); }
  else if (e.key === 'ArrowLeft') { e.preventDefault(); jumpToStep(currentIdx - 1); }
  else if ((e.key === 'n' || e.key === 'N') && e.shiftKey) { e.preventDefault(); stepToKind(['NODE_NEW', 'NODE_LIST_APPEND'], -1); }
  else if (e.key === 'n' || e.key === 'N') { e.preventDefault(); stepToKind(['NODE_NEW', 'NODE_LIST_APPEND'], 1); }
  else if ((e.key === 'm' || e.key === 'M') && e.shiftKey) { e.preventDefault(); stepToAlloc(-1); }
  else if (e.key === 'm' || e.key === 'M') { e.preventDefault(); stepToAlloc(1); }
  else if ((e.key === 'r' || e.key === 'R') && e.shiftKey) { e.preventDefault(); stepToRewind(-1); }
  else if (e.key === 'r' || e.key === 'R') { e.preventDefault(); stepToRewind(1); }
  else if (e.key === 'u' || e.key === 'U') {
    e.preventDefault();
    if (currentTrace && currentTrace._underflowSteps && currentTrace._underflowSteps.length > 0) {
      const uSteps = currentTrace._underflowSteps;
      if (e.shiftKey && uSteps.length > 1) {
        const prevs = uSteps.filter(idx => idx < currentIdx);
        jumpToStep(prevs.length ? prevs[prevs.length - 1] : uSteps[uSteps.length - 1]);
      } else {
        document.getElementById('btnJumpUnderflow').click();
      }
    }
  }
  else if (e.key === 'c' || e.key === 'C') { e.preventDefault(); document.getElementById('btnJumpCrash').click(); }
});

const GEMINI_KEY_STORAGE = 'prism_trace_gemini_key';

function hasBrowserToolbarGemini() {
  const isTopLevel = (window.self === window.top);
  const brands = navigator.userAgentData && Array.isArray(navigator.userAgentData.brands)
    ? navigator.userAgentData.brands
    : [];
  const isGoogleChromeBrand = brands.some(b => b.brand === 'Google Chrome');
  return isTopLevel && isGoogleChromeBrand;
}

if (!hasBrowserToolbarGemini()) {
  document.getElementById('btnToggleGemini').style.display = 'inline-block';
}

function refreshGeminiKeyUi() {
  const saved = localStorage.getItem(GEMINI_KEY_STORAGE);
  const setupBox = document.getElementById('geminiKeySetup');
  const savedBar = document.getElementById('geminiKeySavedBar');
  const modeLabel = document.getElementById('geminiModeLabel');
  if (saved) {
    setupBox.style.display = 'none';
    savedBar.style.display = 'flex';
    modeLabel.textContent = '🔑 Gemini API Key saved (gemini-2.5-flash)';
  } else if (window.LanguageModel || (window.ai && window.ai.languageModel)) {
    setupBox.style.display = 'block';
    savedBar.style.display = 'flex';
    modeLabel.textContent = '✨ Chrome Built-in Gemini Nano detected';
  } else {
    setupBox.style.display = 'block';
    savedBar.style.display = 'none';
  }
}

document.getElementById('btnToggleGemini').addEventListener('click', () => {
  const drawer = document.getElementById('geminiDrawer');
  drawer.classList.toggle('open');
  refreshGeminiKeyUi();
});

document.getElementById('btnCloseGemini').addEventListener('click', () => {
  document.getElementById('geminiDrawer').classList.remove('open');
});

document.getElementById('btnSaveGeminiKey').addEventListener('click', () => {
  const val = document.getElementById('geminiKeyInput').value.trim();
  if (!val) return;
  localStorage.setItem(GEMINI_KEY_STORAGE, val);
  document.getElementById('geminiKeyInput').value = '';
  refreshGeminiKeyUi();
});

document.getElementById('btnClearGeminiKey').addEventListener('click', () => {
  localStorage.removeItem(GEMINI_KEY_STORAGE);
  refreshGeminiKeyUi();
});

document.getElementById('btnCopyGemini').addEventListener('click', () => {
  if (!currentTrace || !currentTrace.steps[currentIdx]) return;
  const md = buildGeminiContextMarkdown(currentTrace.steps[currentIdx]) +
    '\n\nPlease explain what the Prism Ruby parser and lexer are doing at this step and highlight any cursor rewind or bug mechanics.';
  navigator.clipboard.writeText(md);
  const btn = document.getElementById('btnCopyGemini');
  const old = btn.textContent;
  btn.textContent = '✓ Copied for Gemini!';
  setTimeout(() => { btn.textContent = old; }, 1600);
});

async function askGemini(question) {
  if (!currentTrace || !currentTrace.steps[currentIdx]) return;
  const out = document.getElementById('geminiOutput');
  const ctx = buildGeminiContextMarkdown(currentTrace.steps[currentIdx]);
  const fullPrompt = `You are an expert on the Prism Ruby parser (C99 recursive-descent parser and state-machine lexer).\n\n${ctx}\n\nUser Question: ${question}`;
  const apiKey = localStorage.getItem(GEMINI_KEY_STORAGE);

  out.textContent = 'Thinking...';
  try {
    if (apiKey) {
      const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse&key=${encodeURIComponent(apiKey)}`;
      const resp = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: fullPrompt }] }]
        })
      });
      if (!resp.ok) {
        const errText = await resp.text();
        throw new Error(`Gemini API HTTP ${resp.status}: ${errText}`);
      }
      out.textContent = '';
      const reader = resp.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const lines = buf.split('\n');
        buf = lines.pop();
        for (const line of lines) {
          if (!line.startsWith('data: ')) continue;
          const payload = line.slice(6).trim();
          if (!payload || payload === '[DONE]') continue;
          const data = JSON.parse(payload);
          const parts = data.candidates?.[0]?.content?.parts || [];
          for (const p of parts) {
            if (p.text) out.textContent += p.text;
          }
        }
      }
    } else if (window.LanguageModel || (window.ai && window.ai.languageModel)) {
      const factory = window.LanguageModel || window.ai.languageModel;
      const session = await factory.create();
      out.textContent = '';
      const stream = session.promptStreaming(fullPrompt);
      for await (const chunk of stream) {
        out.textContent += chunk;
      }
    } else {
      await navigator.clipboard.writeText(fullPrompt);
      out.textContent = '📋 Copied full step context + question to your clipboard!\n\n' +
        'Since no Gemini API key is saved yet, you can either:\n' +
        '1. Open Chrome\'s built-in Gemini side panel (top-right of Chrome) and press ⌘+V / Ctrl+V (or ask it about this page directly), OR\n' +
        '2. Paste a free AI Studio API key above to stream responses directly inside this drawer.';
    }
  } catch (err) {
    out.textContent = `⚠ Error calling Gemini: ${err.message}`;
  }
}

document.querySelectorAll('.gemini-chip').forEach(btn => {
  btn.addEventListener('click', () => {
    const q = btn.getAttribute('data-prompt');
    document.getElementById('geminiPromptInput').value = q;
    askGemini(q);
  });
});

document.getElementById('btnSendGemini').addEventListener('click', () => {
  const q = document.getElementById('geminiPromptInput').value.trim();
  if (q) askGemini(q);
});

document.getElementById('geminiPromptInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    const q = e.target.value.trim();
    if (q) askGemini(q);
  }
});

document.getElementById('btnSettings').addEventListener('click', () => {
  const pop = document.getElementById('settingsPopover');
  const opening = !pop.classList.contains('open');
  pop.classList.toggle('open');
  if (opening) {
    const input = document.getElementById('repoRootInput');
    input.value = getRepoRoot();
    input.focus();
  }
});

document.getElementById('btnCloseSettings').addEventListener('click', () => {
  document.getElementById('settingsPopover').classList.remove('open');
});

document.getElementById('btnSaveRepoRoot').addEventListener('click', () => {
  const val = document.getElementById('repoRootInput').value.trim().replace(/\/+$/, '');
  if (val) {
    localStorage.setItem(REPO_ROOT_STORAGE, val);
  } else {
    localStorage.removeItem(REPO_ROOT_STORAGE);
  }
  document.getElementById('settingsPopover').classList.remove('open');
  renderStep();
});

document.getElementById('btnClearRepoRoot').addEventListener('click', () => {
  localStorage.removeItem(REPO_ROOT_STORAGE);
  document.getElementById('repoRootInput').value = '';
  document.getElementById('settingsPopover').classList.remove('open');
  renderStep();
});

document.getElementById('repoRootInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    document.getElementById('btnSaveRepoRoot').click();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    document.getElementById('settingsPopover').classList.remove('open');
  }
});

loadTrace(PRESETS[0]);
initWasm();
</script>
</body>
</html>
HTML

presets = []
if File.exist?(File.join(BUILD_DIR, "custom.jsonl"))
  presets << load_jsonl(File.join(BUILD_DIR, "custom.jsonl"), "0. Custom CLI Trace")
end

presets.concat([
  run_trace(
    "x = <<~OUTER + 42\n" \
    "  hello \#{<<-INNER.strip}\n" \
    "    world\n" \
    "  INNER\n" \
    "  done\n" \
    "OUTER\n" \
    "puts x\n",
    "1. Nested Heredoc + Trailing Opener Expression",
    File.join(BUILD_DIR, "preset_nested.jsonl")
  ),
  run_trace(
    "-> (a = <<~HEREDOC) { a.upcase }\n" \
    "  hello lambda\n" \
    "HEREDOC\n",
    "2. Stabby Lambda with Heredoc Default Parameter",
    File.join(BUILD_DIR, "preset_lambda.jsonl")
  ),
  run_trace(
    "def classify(point) = case point\n" \
    "in { x: (0..10) => x, y: [first, *rest] } if x > 0\n" \
    "  [x, first, rest]\n" \
    "else\n" \
    "  nil\n" \
    "end\n",
    "3. Pattern Matching & Endless Method Definition",
    File.join(BUILD_DIR, "preset_pattern.jsonl")
  ),
  run_trace(
    "words = %w[alpha beta \#{1 + 2}]\n" \
    "re = /prefix_\#{words.join('|')}/i\n" \
    "puts re.match?('prefix_alpha')\n",
    "4. Percent Literals, Regex Interpolation & Calls",
    File.join(BUILD_DIR, "preset_literals.jsonl")
  )
])

wasm_path = File.join(BUILD_DIR, "prism_trace.wasm")
wasm_b64 = File.exist?(wasm_path) ? Base64.strict_encode64(File.binread(wasm_path)) : ""
ruby_svg_b64 = Base64.strict_encode64(File.binread(File.join(PRISM_DIR, "doc/images/ruby.svg")))

html = HTML_TEMPLATE
  .sub("__RUBY_SVG_BASE64__") { ruby_svg_b64 }
  .sub("__PRESETS_JSON__") { JSON.generate(presets) }
  .sub("__WASM_BASE64__") { wasm_b64 }

out_html = OUT_HTML
FileUtils.mkdir_p(File.dirname(out_html))
File.write(out_html, html, encoding: "UTF-8")
puts "Generated standalone interactive viewer at #{out_html} (embedded Wasm: #{wasm_b64.bytesize} base64 chars)"
