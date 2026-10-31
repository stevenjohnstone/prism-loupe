#!/usr/bin/env ruby
# frozen_string_literal: true

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
  leak_summary = steps.pop if steps.last && steps.last["summary"]
  { "name" => name, "source" => meta["source"], "steps" => steps, "leak_summary" => leak_summary }
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
<title>Ruby Prism Playground</title>
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
  .version-selector-group {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }
  #prismVersionSelect {
    font-family: var(--font-mono);
    font-size: 11.5px;
    font-weight: 600;
    padding: 4px 8px;
  }
  .github-commit-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: 5px;
    background: var(--panel-alt);
    border: 1px solid var(--border);
    color: var(--muted);
    text-decoration: none;
    flex-shrink: 0;
    transition: border-color 0.15s, color 0.15s;
  }
  .github-commit-btn:hover {
    border-color: var(--accent);
    color: var(--text);
  }
  .github-commit-btn svg {
    width: 15px;
    height: 15px;
    fill: currentColor;
    display: block;
  }
  .playground-source-link {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    height: 26px;
    padding: 0 8px;
    border-radius: 5px;
    background: var(--panel-alt);
    border: 1px solid var(--border);
    color: var(--muted);
    font-family: var(--font-mono);
    font-size: 11px;
    text-decoration: none;
    white-space: nowrap;
    flex-shrink: 0;
    transition: border-color 0.15s, color 0.15s;
  }
  .playground-source-link:hover {
    border-color: var(--accent);
    color: var(--text);
  }
  .playground-source-link svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
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
    gap: 8px;
    user-select: none;
  }
  .scrubber-controls {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
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
  .kind-TEARDOWN { background: rgba(57, 197, 207, 0.2); color: var(--cyan); border: 1px solid var(--cyan); }
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
  <img src="data:image/svg+xml;base64,__RUBY_SVG_BASE64__" alt="Ruby" title="Ruby Prism Playground" class="header-logo">
  <span style="font-weight:600; font-size:13.5px; color:var(--text); white-space:nowrap;">Ruby Prism Playground</span>
  <div class="version-selector-group">
    <select id="prismVersionSelect" title="Select Prism parser version (re-traces current Ruby snippet in-place)"></select>
    <a id="prismVersionCommitLink" class="github-commit-btn" href="__PRISM_COMMIT_URL__" target="_blank" rel="noopener" aria-label="View Prism commit on GitHub" title="__PRISM_VERSION_TITLE__">
      <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"></path></svg>
    </a>
  </div>
  <div style="margin-left:auto; display:flex; align-items:center; gap:8px;">
    <button id="btnToggleGemini" style="display:none; border-color:var(--purple); color:var(--purple); font-weight:600;" title="Open in-page Gemini assistant drawer">✨ Ask Gemini</button>
    <a id="playgroundSourceLink" class="playground-source-link" href="__PLAYGROUND_COMMIT_URL__" target="_blank" rel="noopener" title="__PLAYGROUND_TITLE__">
      <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"></path></svg>
      <span>__PLAYGROUND_REPO_SLUG__@<strong style="color:var(--text);font-weight:600;">__PLAYGROUND_SHORT_SHA__</strong></span>
    </a>
    <button id="btnSettings" title="Settings (Playback speed &amp; local Prism repository path)">&#9881;</button>
  </div>
</header>

<div id="settingsPopover" class="settings-popover">
  <div class="card-title" style="margin-bottom:8px;">
    <span>Viewer Settings</span>
    <span id="btnCloseSettings" style="cursor:pointer; font-size:14px; color:var(--muted);" title="Close">&times;</span>
  </div>
  <div style="margin-bottom:12px; padding-bottom:10px; border-bottom:1px solid var(--border);">
    <label for="playIntervalInput" style="display:block; font-size:11.5px; color:var(--muted); margin-bottom:5px;">
      Playback Step Interval (ms):
    </label>
    <div style="display:flex; align-items:center; gap:5px; margin-bottom:6px;">
      <input type="number" id="playIntervalInput" min="10" max="10000" step="10" value="250" style="width:90px; background:#090d13; color:var(--text); border:1px solid var(--border); border-radius:4px; padding:5px 8px; font-size:12px; font-family:var(--font-mono);">
      <div style="display:flex; gap:4px; flex-wrap:wrap;">
        <button type="button" class="interval-preset-btn" data-ms="50" style="padding:3px 6px; font-size:11px;">50ms</button>
        <button type="button" class="interval-preset-btn" data-ms="100" style="padding:3px 6px; font-size:11px;">100ms</button>
        <button type="button" class="interval-preset-btn" data-ms="250" style="padding:3px 6px; font-size:11px;">250ms</button>
        <button type="button" class="interval-preset-btn" data-ms="500" style="padding:3px 6px; font-size:11px;">500ms</button>
        <button type="button" class="interval-preset-btn" data-ms="1000" style="padding:3px 6px; font-size:11px;">1s</button>
      </div>
    </div>
  </div>
  <label for="repoRootInput" style="display:block; font-size:11.5px; color:var(--muted); margin-bottom:5px;">
    Prism Repository Path (enables <code>&nearr; Antigravity IDE</code> links):
  </label>
  <div style="display:flex; gap:5px;">
    <input type="text" id="repoRootInput" placeholder="/path/to/prism" style="flex:1; min-width:0; background:#090d13; color:var(--text); border:1px solid var(--border); border-radius:4px; padding:5px 8px; font-size:12px; font-family:var(--font-mono);">
    <button id="btnSaveRepoRoot" class="success">Save</button>
    <button id="btnClearRepoRoot">Clear</button>
  </div>
  <div style="margin-top:12px; padding-top:10px; border-top:1px solid var(--border); font-size:11px; color:var(--muted); display:flex; justify-content:space-between; align-items:center; gap:8px;">
    <span>Source: <a href="__PLAYGROUND_REPO_URL__" target="_blank" rel="noopener" style="color:var(--accent); text-decoration:none; font-family:var(--font-mono);">__PLAYGROUND_REPO_NAME__ &nearr;</a></span>
    <span>Build: <a href="__PLAYGROUND_COMMIT_URL__" target="_blank" rel="noopener" style="color:var(--accent); text-decoration:none; font-family:var(--font-mono);">__PLAYGROUND_SHORT_SHA__</a> (__PLAYGROUND_DATE__)</span>
  </div>
</div>

<div class="scrubber-bar">
  <div class="timeline-track" id="timelineTrack" title="Drag or click to scrub — Red = Crash / Corrupted Node (Underflow) | Pink = Syntax Error | Amber = Cursor Rewind | Blue = AST Update | Green = Token">
    <div class="timeline-playhead" id="timelinePlayhead"></div>
  </div>
  <div class="scrubber-controls">
    <button id="btnPlayPause" class="success" style="min-width:68px;" title="Play / Pause automatic playthrough (Spacebar)">&#9654; Play</button>
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
        <div style="display:flex; align-items:center; justify-content:space-between; gap:5px; flex-wrap:wrap;">
          <span style="font-size:11px; text-transform:uppercase; letter-spacing:0.5px; color:var(--muted);">Source Input</span>
          <div style="display:flex; align-items:center; gap:5px; flex-wrap:wrap;">
            <button id="btnEditSource" class="success" title="Edit Ruby source in-place (or double-click source buffer)">✎ Edit Code</button>
            <button id="btnRunWasm" class="success" style="display:none;" title="Parse &amp; trace with in-browser Prism Wasm (Cmd/Ctrl + Enter)">▶ Parse &amp; Trace (⌘+Enter)</button>
            <button id="btnCancelEdit" style="display:none;">Cancel</button>
            <button id="btnShareCode" title="Copy a shareable URL with the current Ruby snippet Base64-encoded in ?code=">🔗 Share</button>
            <button id="btnRecordVideo" title="Record a video of the Ruby source buffer being parsed step-by-step">🎬 Video</button>
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
      <span id="astPaneTitle">Live Arenas, Memory &amp; AST Assembly</span>
      <span id="astSummary" style="font-family:var(--font-mono); color:var(--muted);"></span>
    </div>
    <div style="padding:10px 12px 0 12px; flex-shrink:0; border-bottom:1px solid var(--border);">
      <div class="card">
        <div class="card-title">
          <span id="memCardTitle">Arena Memory Telemetry (Used / Capacity)</span>
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
      <div class="card" id="astOrphansCard">
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
const PRISM_VERSIONS = __PRISM_VERSIONS_JSON__;
let currentPrismVersionIdx = 0;
let PRISM_BUILD_INFO = PRISM_VERSIONS[0] || __PRISM_BUILD_INFO_JSON__;
const REPO_ROOT_STORAGE = 'prism_trace_repo_root';
const PLAY_INTERVAL_STORAGE = 'prism_trace_play_interval_ms';
const DEFAULT_PLAY_INTERVAL_MS = 250;

function getRepoRoot() {
  const saved = localStorage.getItem(REPO_ROOT_STORAGE);
  return saved ? saved.trim().replace(/\/+$/, '') : '';
}

function getPlayIntervalMs() {
  const saved = parseInt(localStorage.getItem(PLAY_INTERVAL_STORAGE), 10);
  if (Number.isFinite(saved) && saved >= 10 && saved <= 10000) {
    return saved;
  }
  return DEFAULT_PLAY_INTERVAL_MS;
}

function updatePlayIntervalUI(ms) {
  const input = document.getElementById('playIntervalInput');
  if (input && document.activeElement !== input) {
    input.value = ms;
  }
  document.querySelectorAll('.interval-preset-btn').forEach(btn => {
    const btnMs = parseInt(btn.getAttribute('data-ms'), 10);
    btn.classList.toggle('active', btnMs === ms);
  });
  const playBtn = document.getElementById('btnPlayPause');
  if (playBtn) {
    playBtn.title = `Play / Pause automatic stepping (${ms}ms per step)`;
  }
}

function setPlayIntervalMs(rawMs) {
  const parsed = parseInt(rawMs, 10);
  const clamped = Number.isFinite(parsed) ? Math.max(10, Math.min(10000, parsed)) : DEFAULT_PLAY_INTERVAL_MS;
  localStorage.setItem(PLAY_INTERVAL_STORAGE, String(clamped));
  updatePlayIntervalUI(clamped);
  if (playInterval !== null) {
    clearInterval(playInterval);
    playInterval = setInterval(advancePlaybackStep, clamped);
  }
  return clamped;
}

const wasmBytesCache = new Map();
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

function advancePlaybackStep() {
  if (!currentTrace || currentIdx >= currentTrace.steps.length - 1) {
    stopPlayback();
    return;
  }
  currentIdx++;
  renderStep();
  if (currentIdx >= currentTrace.steps.length - 1) {
    stopPlayback();
  }
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
  playInterval = setInterval(advancePlaybackStep, getPlayIntervalMs());
}

const presetSelect = document.getElementById('presetSelect');
PRESETS.forEach((p, i) => {
  const opt = document.createElement('option');
  opt.value = i;
  opt.textContent = p.name;
  presetSelect.appendChild(opt);
});

const prismVersionSelect = document.getElementById('prismVersionSelect');
const prismVersionCommitLink = document.getElementById('prismVersionCommitLink');

function updateVersionBadgeUI() {
  if (!PRISM_BUILD_INFO) return;
  if (prismVersionSelect) {
    prismVersionSelect.value = PRISM_BUILD_INFO.id;
  }
  if (prismVersionCommitLink) {
    prismVersionCommitLink.href = PRISM_BUILD_INFO.url || 'https://github.com/ruby/prism';
    const datePart = PRISM_BUILD_INFO.date ? `, ${PRISM_BUILD_INFO.date}` : '';
    prismVersionCommitLink.title = `View Prism ${PRISM_BUILD_INFO.id} (${PRISM_BUILD_INFO.short_sha}${datePart}) on GitHub`;
  }
}

PRISM_VERSIONS.forEach((v) => {
  const opt = document.createElement('option');
  opt.value = v.id;
  opt.textContent = v.id === 'main'
    ? `Prism main (${v.short_sha})`
    : `Prism ${v.id} (${v.short_sha})`;
  opt.style.background = '#161b22';
  opt.style.color = '#e6edf3';
  prismVersionSelect.appendChild(opt);
});
updateVersionBadgeUI();

function findPrismVersionIndex(query) {
  if (!query) return -1;
  const q = String(query).trim();
  let idx = PRISM_VERSIONS.findIndex(v => v.id === q);
  if (idx >= 0) return idx;
  idx = PRISM_VERSIONS.findIndex(v => v.id === 'v' + q || v.version === q.replace(/^v/, ''));
  if (idx >= 0) return idx;
  idx = PRISM_VERSIONS.findIndex(v => v.short_sha === q || (v.sha && v.sha.startsWith(q)));
  return idx;
}

async function selectPrismVersion(versionQuery, reparse = true) {
  const idx = findPrismVersionIndex(versionQuery);
  if (idx < 0) return false;
  currentPrismVersionIdx = idx;
  PRISM_BUILD_INFO = PRISM_VERSIONS[idx];
  wasmExports = null;
  updateVersionBadgeUI();
  updateBrowserUrlVersionOnly();
  await initWasm();
  if (reparse && currentTrace) {
    const editor = document.getElementById('rubyEditor');
    const isEditing = editor && editor.style.display !== 'none';
    const src = isEditing ? editor.value : currentTrace.source;
    const hasCodeInUrl = new URLSearchParams(window.location.search).has('code');
    await parseWithWasm(src, currentTrace.name, hasCodeInUrl || isEditing);
  }
  return true;
}

prismVersionSelect.addEventListener('change', async (e) => {
  await selectPrismVersion(e.target.value, true);
});

async function initWasm() {
  const statusEl = document.getElementById('wasmStatus');
  const verObj = PRISM_VERSIONS[currentPrismVersionIdx] || PRISM_BUILD_INFO;
  const b64 = verObj ? verObj.wasm_b64 : '';
  if (!b64) {
    statusEl.textContent = 'Wasm: not embedded';
    return;
  }
  try {
    let bytes = wasmBytesCache.get(verObj.id);
    if (!bytes) {
      const binStr = atob(b64);
      bytes = new Uint8Array(binStr.length);
      for (let i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
      wasmBytesCache.set(verObj.id, bytes);
    }

    const wasiImport = new Proxy({
      proc_exit: (c) => { throw new Error('WASI proc_exit(' + c + ')'); }
    }, {
      get: (t, p) => (p in t ? t[p] : () => 0)
    });

    const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasiImport });
    if (instance.exports._initialize) instance.exports._initialize();
    wasmExports = instance.exports;
    if (!statusEl.innerHTML.includes('Crash captured')) {
      statusEl.innerHTML = `<span style="color:var(--green)">● Wasm ready (Prism ${escapeHtml(PRISM_BUILD_INFO.id)} @ ${escapeHtml(PRISM_BUILD_INFO.short_sha)})</span>`;
    }
  } catch (err) {
    statusEl.innerHTML = `<span style="color:var(--red)">Wasm init error: ${err.message}</span>`;
  }
}

async function parseWithWasm(rubyCode, label = 'Live Wasm Parse', updateUrlCode = true) {
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
  let leakSummary = null;
  if (steps.length > 0 && steps[steps.length - 1] && steps[steps.length - 1].summary) {
    leakSummary = steps.pop();
  }
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
  loadTrace({ name: label, source: meta.source, steps, leak_summary: leakSummary }, false);
  if (updateUrlCode) {
    updateBrowserUrlWithCode(rubyCode);
  } else {
    updateBrowserUrlVersionOnly();
  }

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

function encodeCodeBase64(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) {
    bin += String.fromCharCode(bytes[i]);
  }
  return btoa(bin);
}

function decodeCodeBase64(b64) {
  const normalized = b64.trim().replace(/ /g, '+').replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i);
  }
  return new TextDecoder().decode(bytes);
}

function buildShareableUrl(rubyCode, stepIdx = currentIdx) {
  const url = new URL(window.location.href);
  if (PRISM_BUILD_INFO && PRISM_BUILD_INFO.id) {
    url.searchParams.set('version', PRISM_BUILD_INFO.id);
  }
  url.searchParams.set('code', encodeCodeBase64(rubyCode));
  if (Number.isFinite(stepIdx) && stepIdx >= 0) {
    url.searchParams.set('step', String(stepIdx));
  }
  return url.toString();
}

function updateBrowserUrlVersionOnly() {
  try {
    const url = new URL(window.location.href);
    if (PRISM_BUILD_INFO && PRISM_BUILD_INFO.id) {
      if (currentPrismVersionIdx === 0 && !url.searchParams.has('code') && !url.searchParams.has('version')) {
        return;
      }
      url.searchParams.set('version', PRISM_BUILD_INFO.id);
      window.history.replaceState(null, '', url.toString());
    }
  } catch (_) {}
}

function updateBrowserUrlWithCode(rubyCode, stepIdx = null) {
  try {
    if (typeof rubyCode === 'string' && rubyCode.length <= 16384) {
      const url = new URL(window.location.href);
      if (PRISM_BUILD_INFO && PRISM_BUILD_INFO.id) {
        url.searchParams.set('version', PRISM_BUILD_INFO.id);
      }
      url.searchParams.set('code', encodeCodeBase64(rubyCode));
      if (Number.isFinite(stepIdx) && stepIdx >= 0) {
        url.searchParams.set('step', String(stepIdx));
      } else {
        url.searchParams.delete('step');
      }
      window.history.replaceState(null, '', url.toString());
    }
  } catch (_) {}
}

function clearBrowserUrlCodeParam() {
  try {
    const url = new URL(window.location.href);
    if (url.searchParams.has('code') || url.searchParams.has('step')) {
      url.searchParams.delete('code');
      url.searchParams.delete('step');
      window.history.replaceState(null, '', url.toString());
    }
  } catch (_) {}
}

function formatBytes(b) {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(2)} KB`;
  return `${(b / (1024 * 1024)).toFixed(2)} MB`;
}

function preprocessTrace(trace) {
  if (trace.steps && trace.steps.length > 0 && trace.steps[trace.steps.length - 1] && trace.steps[trace.steps.length - 1].summary) {
    trace.leak_summary = trace.steps.pop();
  }
  let lastAst = [];
  let lastChangedNodeId = -1;
  let prevCurrStart = 0;
  let prevAstU = 0, prevMetaU = 0, prevScratchU = 0, prevTotalU = 0, prevXallocU = 0;
  const prevUnderflowById = new Map();
  trace._crashIdx = -1;
  trace._underflowIdx = -1;
  trace._underflowSteps = [];
  trace._underflowEvents = [];
  trace._underflowFirstStepByNode = {};
  trace._peakMemUsed = 0;
  trace._peakXallocUsed = (trace.leak_summary && trace.leak_summary.peak_bytes) ? trace.leak_summary.peak_bytes : 0;
  trace._hasArena = false;
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

    const m = s.mem || { ast: [0, 0, 0], meta: [0, 0, 0], scratch: [0, 0, 0], lo: [0, 0], cp: [0, 0], xalloc: [0, 0, 0, 0] };
    const astU = m.ast[0] || 0;
    const metaU = m.meta[0] || 0;
    const scratchU = m.scratch[0] || 0;
    const totalU = astU + metaU + scratchU;
    const totalCap = (m.ast[1] || 0) + (m.meta[1] || 0) + (m.scratch[1] || 0);
    const xallocArr = m.xalloc || [0, 0, 0, 0];
    const xLive = xallocArr[0] || 0;
    const xPeak = xallocArr[1] || 0;

    s._astDelta = i > 0 ? Math.max(0, astU - prevAstU) : 0;
    s._metaDelta = i > 0 ? Math.max(0, metaU - prevMetaU) : 0;
    s._scratchDelta = i > 0 ? Math.max(0, scratchU - prevScratchU) : 0;
    s._xallocDelta = i > 0 ? (xLive - prevXallocU) : xLive;
    const arenaDelta = i > 0 ? Math.max(0, totalU - prevTotalU) : 0;
    s._memDelta = totalCap > 0 ? arenaDelta : Math.max(0, s._xallocDelta);
    s._memTotalUsed = totalU;
    s._memTotalCap = totalCap;
    if (totalCap > 0) trace._hasArena = true;
    if (totalU > trace._peakMemUsed) trace._peakMemUsed = totalU;
    if (xPeak > trace._peakXallocUsed) trace._peakXallocUsed = xPeak;
    if (xLive > trace._peakXallocUsed) trace._peakXallocUsed = xLive;

    prevAstU = astU;
    prevMetaU = metaU;
    prevScratchU = scratchU;
    prevTotalU = totalU;
    prevXallocU = xLive;
  });
}

function setEditMode(editing) {
  if (editing) {
    stopPlayback();
    if (typeof stopVideoRecording === 'function') stopVideoRecording();
  }
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
  if (typeof stopVideoRecording === 'function') stopVideoRecording();
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
    `- Prism Version: v${PRISM_BUILD_INFO.version} (${PRISM_BUILD_INFO.describe}, commit ${PRISM_BUILD_INFO.short_sha})`,
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

function traceHasArena() {
  if (currentTrace && typeof currentTrace._hasArena === 'boolean' && currentTrace.steps && currentTrace.steps.length > 0) {
    if (currentTrace._hasArena) return true;
  }
  if (PRISM_BUILD_INFO && typeof PRISM_BUILD_INFO.has_arena === 'boolean') {
    return PRISM_BUILD_INFO.has_arena;
  }
  return Boolean(currentTrace && currentTrace._hasArena);
}

function renderMemoryTelemetry(step) {
  const hasArena = traceHasArena();
  const m = step.mem || { ast: [0, 0, 0], meta: [0, 0, 0], scratch: [0, 0, 0], lo: [0, 0], cp: [0, 0], xalloc: [0, 0, 0, 0] };
  const badge = document.getElementById('memCardBadge');
  const paneTitle = document.getElementById('astPaneTitle');
  const cardTitle = document.getElementById('memCardTitle');
  if (paneTitle) {
    paneTitle.textContent = hasArena ? 'Live Arenas, Memory & AST Assembly' : 'Live Memory & AST Assembly';
  }
  if (cardTitle) {
    cardTitle.textContent = hasArena ? 'Arena & Heap Memory Telemetry' : 'Heap Memory Telemetry (PRISM_XALLOCATOR)';
  }

  const [loSize, loCap] = m.lo || [0, 0];
  const [cpSize, cpCap] = m.cp || [0, 0];
  const [xLive, xPeakStep, xAllocs, xFrees] = m.xalloc || [0, 0, 0, 0];
  const xPeak = Math.max(xPeakStep || 0, (currentTrace && currentTrace._peakXallocUsed) || 0, xLive || 0);
  const xPct = xPeak > 0 ? Math.min(100, (xLive / xPeak) * 100).toFixed(1) : 0;
  const xDelta = step._xallocDelta || 0;
  const xDeltaPill = xDelta > 0
    ? `<span class="mem-delta-pill">+${formatBytes(xDelta)}</span>`
    : (xDelta < 0 ? `<span class="mem-delta-pill" style="background:rgba(88,166,255,0.18);color:var(--accent);">-${formatBytes(Math.abs(xDelta))}</span>` : '');

  const leak = currentTrace && currentTrace.leak_summary;
  let leakBadgeHtml = '';
  if (leak) {
    if (leak.leaked_bytes > 0) {
      leakBadgeHtml = `<span style="color:var(--red);font-weight:700;" title="${leak.leaked_blocks} unfreed block(s) remaining after parser teardown">⚠ Leak: ${formatBytes(leak.leaked_bytes)} (${leak.leaked_blocks} blk)</span>`;
    } else if (step.kind === 'TEARDOWN') {
      leakBadgeHtml = `<span style="color:var(--green);font-weight:600;" title="All ${leak.alloc_count} xmalloc/xcalloc/xrealloc allocations (${formatBytes(leak.total_bytes)}) freed cleanly on teardown">✓ 0 B leaked (${leak.alloc_count}/${leak.free_count} freed)</span>`;
    } else {
      leakBadgeHtml = `<span style="color:var(--green);font-weight:600;" title="Step to TEARDOWN (final step) to see all ${leak.alloc_count} allocations freed">✓ 0 B leaked on teardown</span>`;
    }
  }

  const xallocRowHtml = `
    <div class="mem-row">
      <div class="mem-row-header">
        <span><span class="swatch" style="background:var(--green);margin-right:5px;"></span>Heap (<code>xmalloc</code> / <code>xfree</code>)${xDeltaPill}</span>
        <span style="color:var(--muted)">
          <strong style="color:var(--text)">${formatBytes(xLive)}</strong> / peak ${formatBytes(xPeak)}
          (${xAllocs} alloc / ${xFrees} free)
        </span>
      </div>
      <div class="mem-bar-bg">
        <div class="mem-bar-fill" style="width:${xPct}%;background:var(--green);"></div>
      </div>
    </div>
  `;

  if (!hasArena) {
    badge.innerHTML = leakBadgeHtml || `<span style="color:var(--muted)">peak: ${formatBytes(xPeak)}</span>`;
    document.getElementById('memBreakdownBox').innerHTML = `
      ${xallocRowHtml}
      <div style="display:flex;justify-content:space-between;font-family:var(--font-mono);font-size:11px;color:var(--muted);padding-top:4px;border-top:1px solid var(--border);">
        <span><code>line_offsets</code>: <strong style="color:var(--text)">${loSize}</strong>/${loCap} (${loSize * 4} B)</span>
        <span><code>constant_pool</code>: <strong style="color:var(--text)">${cpSize}</strong>/${cpCap}</span>
      </div>
    `;
    return;
  }

  badge.innerHTML = step._memDelta > 0
    ? `<span class="mem-delta-pill">+${formatBytes(step._memDelta)} this step</span>`
    : (leakBadgeHtml || `<span style="color:var(--muted)">peak: ${formatBytes(currentTrace._peakMemUsed || 0)}</span>`);

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

  document.getElementById('memBreakdownBox').innerHTML = `
    ${makeArenaRow('AST Arena (<code>parser-&gt;arena</code>)', m.ast, step._astDelta, 'var(--accent)')}
    ${makeArenaRow('Metadata Arena (<code>metadata_arena</code>)', m.meta, step._metaDelta, 'var(--purple)')}
    ${makeArenaRow('Scratch Arena (<code>scratch_arena</code>)', m.scratch, step._scratchDelta, 'var(--cyan)')}
    ${xallocRowHtml}
    <div style="display:flex;justify-content:space-between;font-family:var(--font-mono);font-size:11px;color:var(--muted);padding-top:4px;border-top:1px solid var(--border);">
      <span><code>line_offsets</code>: <strong style="color:var(--text)">${loSize}</strong>/${loCap} (${loSize * 4} B)</span>
      <span><code>constant_pool</code>: <strong style="color:var(--text)">${cpSize}</strong>/${cpCap}</span>
      <span>Arena: <strong style="color:var(--text)">${formatBytes(step._memTotalUsed)}</strong>/${formatBytes(step._memTotalCap)}</span>
    </div>
  `;
}

function renderAstForest(step) {
  const hasArena = traceHasArena();
  const nodes = step._astSnapshot || [];
  const treeBox = document.getElementById('astTreeBox');
  const orphansBox = document.getElementById('astOrphansBox');
  const orphansCard = document.getElementById('astOrphansCard');
  if (orphansCard) {
    orphansCard.style.display = hasArena ? '' : 'none';
  }
  const astPaneBody = treeBox.closest('.pane-body');
  const prevAstScrollTop = astPaneBody ? astPaneBody.scrollTop : 0;
  treeBox.innerHTML = '';
  orphansBox.innerHTML = '';
  const underflowCount = nodes.filter(n => n.underflow || n.end < n.start).length;

  if (nodes.length === 0) {
    if (step.kind === 'TEARDOWN') {
      const d = step.detail || (currentTrace && currentTrace.leak_summary) || {};
      const leaked = d.leaked_bytes || 0;
      const blocks = d.leaked_blocks || 0;
      const allocs = d.alloc_count || 0;
      const frees = d.free_count || 0;
      document.getElementById('astSummary').innerHTML = '0 nodes (torn down)';
      treeBox.innerHTML = leaked > 0
        ? `<span style="color:var(--red);font-weight:700;">⚠ Parser &amp; AST torn down with memory leak: ${formatBytes(leaked)} unfreed across ${blocks} block(s) (${allocs} alloc / ${frees} free)</span>`
        : `<span style="color:var(--green);font-weight:600;">✓ Parser &amp; AST torn down cleanly — 0 B leaked (${allocs}/${frees} allocations freed)</span>`;
      orphansBox.innerHTML = '<span style="color:var(--muted)">(arena freed)</span>';
      return;
    }
    document.getElementById('astSummary').innerHTML = '0 allocated node(s)';
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

  let displayNodeCount = nodes.length;
  if (!hasArena) {
    let activeCount = 0;
    const countSubtree = (n) => {
      if (!n) return;
      activeCount++;
      n.children.forEach(cid => countSubtree(byId.get(cid)));
    };
    activeRoots.forEach(countSubtree);
    displayNodeCount = activeCount;
  }
  document.getElementById('astSummary').innerHTML = underflowCount > 0
    ? `<span style="color:var(--red);font-weight:700;">⚠ ${underflowCount} corrupted location(s) / ${displayNodeCount} nodes</span>`
    : `${displayNodeCount} ${hasArena ? 'allocated' : 'active'} node(s)`;

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

document.getElementById('btnShareCode').addEventListener('click', async () => {
  const editor = document.getElementById('rubyEditor');
  const isEditing = editor.style.display !== 'none';
  const rubyCode = isEditing ? editor.value : (currentTrace ? currentTrace.source : '');
  const shareUrl = buildShareableUrl(rubyCode, currentIdx);
  updateBrowserUrlWithCode(rubyCode, currentIdx);
  const btn = document.getElementById('btnShareCode');
  const orig = btn.textContent;
  try {
    await navigator.clipboard.writeText(shareUrl);
    btn.textContent = '✓ Copied!';
  } catch (_) {
    btn.textContent = '✓ URL Set';
  }
  setTimeout(() => { btn.textContent = orig; }, 1400);
});

let activeVideoRecording = null;

function pickSupportedVideoMime() {
  if (typeof MediaRecorder === 'undefined') return null;
  const candidates = [
    { mime: 'video/webm;codecs=vp9', ext: 'webm' },
    { mime: 'video/webm;codecs=vp8', ext: 'webm' },
    { mime: 'video/webm', ext: 'webm' },
    { mime: 'video/mp4;codecs=avc1', ext: 'mp4' },
    { mime: 'video/mp4', ext: 'mp4' }
  ];
  for (const c of candidates) {
    if (!MediaRecorder.isTypeSupported || MediaRecorder.isTypeSupported(c.mime)) {
      return c;
    }
  }
  return { mime: '', ext: 'webm' };
}

function getKindBadgeStyle(kind) {
  switch (kind) {
    case 'LEX_TOKEN':
      return { bg: 'rgba(63, 185, 80, 0.22)', fg: '#3fb950', border: '#3fb950' };
    case 'LEX_STATE':
      return { bg: 'rgba(57, 197, 207, 0.22)', fg: '#39c5cf', border: '#39c5cf' };
    case 'LEX_MODE_PUSH':
    case 'LEX_MODE_POP':
    case 'ERROR':
      return { bg: 'rgba(247, 120, 186, 0.22)', fg: '#f778ba', border: '#f778ba' };
    case 'HEREDOC_FLUSH':
      return { bg: 'rgba(188, 140, 255, 0.25)', fg: '#bc8cff', border: '#bc8cff' };
    case 'NODE_NEW':
    case 'NODE_LIST_APPEND':
      return { bg: 'rgba(88, 166, 255, 0.22)', fg: '#58a6ff', border: '#58a6ff' };
    case 'CRASH':
      return { bg: '#f85149', fg: '#ffffff', border: '#ff7b72' };
    default:
      return { bg: 'rgba(139, 148, 158, 0.18)', fg: '#8b949e', border: '#30363d' };
  }
}

function buildCanvasSourceModel(src) {
  const lines = [];
  let currentCells = [];
  let lineNum = 1;
  let lineStartOffset = 0;
  let colUnit = 0;
  let maxColUnits = 0;
  const offsetToPos = new Array(src.length + 1);

  for (let i = 0; i <= src.length; i++) {
    const ch = i < src.length ? src[i] : 'EOF';
    let display = ch;
    let isMeta = false;
    let units = 1;
    if (ch === '\n') {
      display = '\\n';
      isMeta = true;
      units = 2;
    } else if (ch === '\r') {
      display = '\\r';
      isMeta = true;
      units = 2;
    } else if (ch === 'EOF') {
      display = '␄';
      isMeta = true;
      units = 1;
    } else if (ch === '\t') {
      display = '→ ';
      isMeta = true;
      units = 2;
    }
    const cell = {
      offset: i,
      ch,
      display,
      isMeta,
      colUnit,
      units
    };
    offsetToPos[i] = { lineIdx: lines.length, colUnit, units };
    currentCells.push(cell);
    colUnit += units;
    if (colUnit > maxColUnits) maxColUnits = colUnit;

    if (ch === '\n') {
      lines.push({ lineNum, startOffset: lineStartOffset, cells: currentCells, totalUnits: colUnit });
      lineNum++;
      lineStartOffset = i + 1;
      currentCells = [];
      colUnit = 0;
    }
  }
  lines.push({ lineNum, startOffset: lineStartOffset, cells: currentCells, totalUnits: colUnit });
  return { lines, maxColUnits, offsetToPos };
}

function drawRoundedRect(ctx, x, y, w, h, r) {
  const radius = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + w, y, x + w, y + h, radius);
  ctx.arcTo(x + w, y + h, x, y + h, radius);
  ctx.arcTo(x, y + h, x, y, radius);
  ctx.arcTo(x, y, x + w, y, radius);
  ctx.closePath();
}

function createSourceVideoRenderer(trace) {
  const model = buildCanvasSourceModel(trace.source || '');
  const scale = 2;
  const fontMono = '13px "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace';
  const fontSmall = '11px "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace';
  const fontBold = '600 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';

  const measureCanvas = document.createElement('canvas');
  const mctx = measureCanvas.getContext('2d');
  mctx.font = fontMono;
  const charW = Math.ceil(mctx.measureText('M').width) + 2;
  const lineH = 22;

  const visibleLines = Math.max(5, Math.min(20, model.lines.length));
  const visibleCols = Math.max(52, Math.min(86, model.maxColUnits + 4));

  const outerPad = 12;
  const headerH = 42;
  const footerH = 28;
  const boxPadX = 10;
  const boxPadY = 10;
  const gutterW = 42;
  const gutterGap = 10;

  let logicalW = outerPad * 2 + boxPadX * 2 + gutterW + gutterGap + visibleCols * charW;
  let logicalH = outerPad * 2 + headerH + boxPadY * 2 + visibleLines * lineH + footerH;
  if (logicalW % 2 !== 0) logicalW += 1;
  if (logicalH % 2 !== 0) logicalH += 1;

  const canvas = document.createElement('canvas');
  canvas.width = logicalW * scale;
  canvas.height = logicalH * scale;
  const ctx = canvas.getContext('2d');

  let scrollLine = 0;
  let scrollCol = 0;

  function renderFrame(stepIdx) {
    const steps = trace.steps || [];
    const step = steps[stepIdx] || steps[0];
    if (!step) return;

    const [prevS, prevE, prevTok] = step.prev || [-1, -1, ''];
    const [currS, currE, currTok] = step.curr || [-1, -1, ''];

    let focusOffset = (currE >= 0 ? currE : (currS >= 0 ? currS : (prevE >= 0 ? prevE : 0)));
    if ((step.kind === 'ERROR' || step.kind === 'NODE_NEW') && step.detail && typeof step.detail.start === 'number') {
      focusOffset = step.detail.start;
    }
    const maxOff = (trace.source || '').length;
    focusOffset = Math.max(0, Math.min(maxOff, focusOffset));
    const focusPos = model.offsetToPos[focusOffset] || { lineIdx: 0, colUnit: 0 };

    if (model.lines.length > visibleLines) {
      const marginLines = Math.max(1, Math.floor(visibleLines * 0.22));
      if (focusPos.lineIdx < scrollLine + marginLines) {
        scrollLine = Math.max(0, focusPos.lineIdx - marginLines);
      } else if (focusPos.lineIdx >= scrollLine + visibleLines - marginLines) {
        scrollLine = Math.min(model.lines.length - visibleLines, focusPos.lineIdx - visibleLines + marginLines + 1);
      }
    } else {
      scrollLine = 0;
    }

    if (model.maxColUnits > visibleCols) {
      const marginCols = Math.max(4, Math.floor(visibleCols * 0.2));
      if (focusPos.colUnit < scrollCol + marginCols) {
        scrollCol = Math.max(0, focusPos.colUnit - marginCols);
      } else if (focusPos.colUnit >= scrollCol + visibleCols - marginCols) {
        scrollCol = Math.max(0, focusPos.colUnit - visibleCols + marginCols + 2);
      }
    } else {
      scrollCol = 0;
    }

    ctx.save();
    ctx.scale(scale, scale);

    // Outer background
    ctx.fillStyle = '#0d1117';
    ctx.fillRect(0, 0, logicalW, logicalH);

    // Header bar
    ctx.fillStyle = '#161b22';
    ctx.fillRect(0, 0, logicalW, headerH);
    ctx.strokeStyle = '#30363d';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, headerH - 0.5);
    ctx.lineTo(logicalW, headerH - 0.5);
    ctx.stroke();

    // Step counter
    ctx.font = fontBold;
    ctx.fillStyle = '#e6edf3';
    ctx.textBaseline = 'middle';
    const stepText = `Step ${stepIdx + 1} / ${steps.length}`;
    ctx.fillText(stepText, outerPad, 18);
    let cursorX = outerPad + ctx.measureText(stepText).width + 10;

    // Kind badge
    const kStyle = getKindBadgeStyle(step.kind);
    ctx.font = fontSmall;
    const kindLabel = step.kind || 'STEP';
    const kindW = ctx.measureText(kindLabel).width + 12;
    drawRoundedRect(ctx, cursorX, 8, kindW, 20, 4);
    ctx.fillStyle = kStyle.bg;
    ctx.fill();
    ctx.strokeStyle = kStyle.border;
    ctx.stroke();
    ctx.fillStyle = kStyle.fg;
    ctx.fillText(kindLabel, cursorX + 6, 18.5);
    cursorX += kindW + 10;

    // Function & detail summary
    ctx.font = fontSmall;
    ctx.fillStyle = '#8b949e';
    let detailSummary = `${step.func || ''}()`;
    if (step.kind === 'LEX_TOKEN' && currTok) {
      detailSummary += ` → ${currTok.replace(/^PM_TOKEN_/, '')} [${currS}..${currE}]`;
    } else if ((step.kind === 'NODE_NEW' || step.kind === 'NODE_LIST_APPEND') && step.detail) {
      detailSummary += ` → ${(step.detail.type || '').replace(/^PM_/, '')} #${step.detail.node_id ?? '?'} [${step.detail.start ?? '?'}..${step.detail.end ?? '?'}]`;
    } else if (step.kind === 'ERROR' && step.detail && step.detail.message) {
      detailSummary += ` → ${step.detail.message}`;
    }
    if (step._hasNewUnderflow) {
      detailSummary += '  ⚠ UNDERFLOW (end < start)';
    } else if (step._isRewind) {
      detailSummary += `  ↺ REWIND (${step._rewindDelta}B)`;
    }
    ctx.fillText(detailSummary, cursorX, 18.5);

    // Header mini timeline bar
    const trackY = headerH - 5;
    ctx.fillStyle = '#090d13';
    ctx.fillRect(outerPad, trackY, logicalW - outerPad * 2, 3);
    if (steps.length > 1) {
      const trackW = logicalW - outerPad * 2;
      const ratio = stepIdx / (steps.length - 1);
      ctx.fillStyle = step._hasNewUnderflow || step.kind === 'CRASH'
        ? '#f85149'
        : (step._isRewind ? '#d29922' : '#58a6ff');
      ctx.fillRect(outerPad, trackY, Math.max(2, ratio * trackW), 3);
    }

    // Source box container
    const boxX = outerPad;
    const boxY = headerH + outerPad - 4;
    const boxW = logicalW - outerPad * 2;
    const boxH = boxPadY * 2 + visibleLines * lineH;

    drawRoundedRect(ctx, boxX, boxY, boxW, boxH, 6);
    ctx.fillStyle = '#090d13';
    ctx.fill();
    ctx.strokeStyle = '#30363d';
    ctx.lineWidth = 1;
    ctx.stroke();

    // Clip to source box
    ctx.save();
    drawRoundedRect(ctx, boxX + 1, boxY + 1, boxW - 2, boxH - 2, 5);
    ctx.clip();

    const codeOriginX = boxX + boxPadX + gutterW + gutterGap;
    const codeOriginY = boxY + boxPadY;

    // Optional node span highlight on NODE_NEW / NODE_LIST_APPEND
    const nodeStart = (step.detail && typeof step.detail.start === 'number') ? step.detail.start : -1;
    const nodeEnd = (step.detail && typeof step.detail.end === 'number') ? step.detail.end : -1;
    const isNodeStep = (step.kind === 'NODE_NEW' || step.kind === 'NODE_LIST_APPEND') && nodeStart >= 0 && nodeEnd >= 0;
    const isUnderflowRange = isNodeStep && nodeEnd < nodeStart;
    const nRangeLo = isNodeStep ? Math.min(nodeStart, nodeEnd) : -1;
    const nRangeHi = isNodeStep ? Math.max(nodeStart, nodeEnd) : -1;

    for (let v = 0; v < visibleLines; v++) {
      const lineIdx = scrollLine + v;
      if (lineIdx >= model.lines.length) break;
      const lineObj = model.lines[lineIdx];
      const rowY = codeOriginY + v * lineH;
      const isActiveLine = (lineIdx === focusPos.lineIdx);

      if (isActiveLine) {
        ctx.fillStyle = 'rgba(88, 166, 255, 0.08)';
        ctx.fillRect(boxX + 2, rowY, boxW - 4, lineH);
        ctx.fillStyle = '#58a6ff';
        ctx.fillRect(boxX + 2, rowY, 2.5, lineH);
      }

      // Gutter line number
      ctx.font = fontSmall;
      ctx.fillStyle = '#8b949e';
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      ctx.fillText(String(lineObj.lineNum), boxX + boxPadX + gutterW - 8, rowY + lineH / 2);

      // Gutter divider
      ctx.strokeStyle = '#30363d';
      ctx.beginPath();
      ctx.moveTo(boxX + boxPadX + gutterW - 0.5, rowY);
      ctx.lineTo(boxX + boxPadX + gutterW - 0.5, rowY + lineH);
      ctx.stroke();

      // Cells
      ctx.textAlign = 'center';
      ctx.font = fontMono;
      for (const cell of lineObj.cells) {
        const relCol = cell.colUnit - scrollCol;
        if (relCol + cell.units < 0 || relCol > visibleCols + 1) continue;

        const cellX = codeOriginX + relCol * charW;
        const cellW = cell.units * charW;
        const cellH = lineH - 2;
        const cellY = rowY + 1;
        const i = cell.offset;

        if (isNodeStep && i >= nRangeLo && i < nRangeHi) {
          ctx.fillStyle = isUnderflowRange ? 'rgba(248, 81, 73, 0.22)' : 'rgba(88, 166, 255, 0.14)';
          ctx.fillRect(cellX, cellY, cellW, cellH);
        }

        if (i >= prevS && i < prevE) {
          ctx.fillStyle = 'rgba(210, 153, 34, 0.26)';
          ctx.fillRect(cellX, cellY, cellW, cellH);
          ctx.fillStyle = '#d29922';
          ctx.fillRect(cellX, cellY + cellH - 2, cellW, 2);
        }

        if (i >= currS && i < currE) {
          ctx.fillStyle = 'rgba(63, 185, 80, 0.32)';
          ctx.fillRect(cellX, cellY, cellW, cellH);
          ctx.fillStyle = '#3fb950';
          ctx.fillRect(cellX, cellY + cellH - 2, cellW, 2);
        } else if (currS >= 0 && currS === currE && i === currS) {
          ctx.fillStyle = 'rgba(63, 185, 80, 0.18)';
          ctx.fillRect(cellX, cellY, cellW, cellH);
          ctx.fillStyle = '#3fb950';
          ctx.fillRect(cellX, cellY, 2, cellH);
        }

        ctx.fillStyle = cell.isMeta ? '#6e7681' : '#e6edf3';
        ctx.fillText(cell.display, cellX + cellW / 2, rowY + lineH / 2 + 0.5);
      }
    }

    ctx.restore();

    // Footer legend & live token status
    const footerY = boxY + boxH + (footerH / 2) + 2;
    ctx.font = fontSmall;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';

    let fx = outerPad;
    // Prev token legend
    ctx.fillStyle = '#d29922';
    ctx.fillRect(fx, footerY - 4, 8, 8);
    fx += 12;
    ctx.fillStyle = '#8b949e';
    const prevLabel = prevS >= 0 ? `prev [${prevS}..${prevE}] ${(prevTok || '').replace(/^PM_TOKEN_/, '')}` : 'prev: none';
    ctx.fillText(prevLabel, fx, footerY);
    fx += ctx.measureText(prevLabel).width + 16;

    // Curr token legend
    ctx.fillStyle = '#3fb950';
    ctx.fillRect(fx, footerY - 4, 8, 8);
    fx += 12;
    ctx.fillStyle = '#e6edf3';
    const currLabel = currS >= 0 ? `curr [${currS}..${currE}] ${(currTok || '').replace(/^PM_TOKEN_/, '')}` : 'curr: none';
    ctx.fillText(currLabel, fx, footerY);
    fx += ctx.measureText(currLabel).width + 16;

    // Lex mode
    const topMode = (step.lex_modes && step.lex_modes.length > 0) ? step.lex_modes[0].mode : 'DEFAULT';
    ctx.fillStyle = '#8b949e';
    ctx.fillText(`lex_mode: ${topMode}`, fx, footerY);

    ctx.restore();
  }

  return { canvas, renderFrame };
}

function ebmlVintSize(len) {
  if (len < 0x7F) {
    return new Uint8Array([0x80 | len]);
  }
  if (len < 0x3FFF) {
    return new Uint8Array([0x40 | ((len >> 8) & 0x3F), len & 0xFF]);
  }
  if (len < 0x1FFFFF) {
    return new Uint8Array([0x20 | ((len >> 16) & 0x1F), (len >> 8) & 0xFF, len & 0xFF]);
  }
  if (len < 0x0FFFFFFF) {
    return new Uint8Array([
      0x10 | ((len >>> 24) & 0x0F),
      (len >>> 16) & 0xFF,
      (len >>> 8) & 0xFF,
      len & 0xFF
    ]);
  }
  const out = new Uint8Array(8);
  out[0] = 0x01;
  let rem = len;
  for (let i = 7; i >= 1; i--) {
    out[i] = rem & 0xFF;
    rem = Math.floor(rem / 256);
  }
  return out;
}

function ebmlElement(idBytes, payload) {
  const parts = Array.isArray(payload) ? payload : [payload];
  let totalPayload = 0;
  for (const p of parts) totalPayload += p.byteLength;
  const sizeBytes = ebmlVintSize(totalPayload);
  const out = new Uint8Array(idBytes.length + sizeBytes.length + totalPayload);
  out.set(idBytes, 0);
  out.set(sizeBytes, idBytes.length);
  let offset = idBytes.length + sizeBytes.length;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.byteLength;
  }
  return out;
}

function ebmlUint(idBytes, val) {
  let n = Math.max(0, Math.floor(val));
  const bytes = [];
  do {
    bytes.unshift(n & 0xFF);
    n = Math.floor(n / 256);
  } while (n > 0);
  return ebmlElement(idBytes, new Uint8Array(bytes));
}

function ebmlFloat64(idBytes, val) {
  const buf = new ArrayBuffer(8);
  new DataView(buf).setFloat64(0, val, false);
  return ebmlElement(idBytes, new Uint8Array(buf));
}

function ebmlAscii(idBytes, str) {
  const bytes = new TextEncoder().encode(str);
  return ebmlElement(idBytes, bytes);
}

function muxWebmVideo(encodedChunks, width, height, codecId, totalDurationMs) {
  const ebmlHeader = ebmlElement([0x1A, 0x45, 0xDF, 0xA3], [
    ebmlUint([0x42, 0x86], 1),
    ebmlUint([0x42, 0xF7], 1),
    ebmlUint([0x42, 0xF2], 4),
    ebmlUint([0x42, 0xF3], 8),
    ebmlAscii([0x42, 0x82], 'webm'),
    ebmlUint([0x42, 0x87], 4),
    ebmlUint([0x42, 0x85], 2)
  ]);

  const segmentInfo = ebmlElement([0x15, 0x49, 0xA9, 0x66], [
    ebmlUint([0x2A, 0xD7, 0xB1], 1000000),
    ebmlFloat64([0x44, 0x89], Math.max(1, totalDurationMs)),
    ebmlAscii([0x4D, 0x80], 'PrismPlayground'),
    ebmlAscii([0x57, 0x41], 'PrismPlayground')
  ]);

  const videoTrack = ebmlElement([0xE0], [
    ebmlUint([0xB0], width),
    ebmlUint([0xBA], height)
  ]);

  const trackEntry = ebmlElement([0xAE], [
    ebmlUint([0xD7], 1),
    ebmlUint([0x73, 0xC5], 1),
    ebmlUint([0x9C], 0),
    ebmlAscii([0x22, 0xB5, 0x9C], 'und'),
    ebmlAscii([0x86], codecId),
    ebmlUint([0x83], 1),
    videoTrack
  ]);

  const tracks = ebmlElement([0x16, 0x54, 0xAE, 0x6B], [trackEntry]);

  const clusters = [];
  let currentClusterBlocks = [];
  let clusterStartMs = 0;

  const flushCluster = () => {
    if (currentClusterBlocks.length === 0) return;
    clusters.push(ebmlElement([0x1F, 0x43, 0xB6, 0x75], [
      ebmlUint([0xE7], clusterStartMs),
      ...currentClusterBlocks
    ]));
    currentClusterBlocks = [];
  };

  for (let i = 0; i < encodedChunks.length; i++) {
    const ch = encodedChunks[i];
    const rel = Math.round(ch.timestampMs - clusterStartMs);
    if (i === 0 || (ch.isKey && rel >= 2000) || rel >= 25000 || rel < 0) {
      flushCluster();
      clusterStartMs = Math.max(0, Math.round(ch.timestampMs));
    }
    const relTime = Math.max(-32768, Math.min(32767, Math.round(ch.timestampMs - clusterStartMs)));
    const blockHeader = new Uint8Array(4);
    blockHeader[0] = 0x81; // Track 1 VINT
    blockHeader[1] = (relTime >> 8) & 0xFF;
    blockHeader[2] = relTime & 0xFF;
    blockHeader[3] = ch.isKey ? 0x80 : 0x00;
    currentClusterBlocks.push(ebmlElement([0xA3], [blockHeader, ch.data]));
  }
  flushCluster();

  const segment = ebmlElement([0x18, 0x53, 0x80, 0x67], [
    segmentInfo,
    tracks,
    ...clusters
  ]);

  return new Blob([ebmlHeader, segment], { type: 'video/webm' });
}

function downloadVideoBlob(blob, traceName, ext) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  const safeName = (traceName || 'prism-trace')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'prism-trace';
  a.href = url;
  a.download = `${safeName}.${ext}`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

function stopVideoRecording() {
  if (!activeVideoRecording) return;
  const rec = activeVideoRecording;
  rec.cancelled = true;
  activeVideoRecording = null;
  if (rec.timer) {
    clearTimeout(rec.timer);
    rec.timer = null;
  }
  if (rec.recorder && rec.recorder.state !== 'inactive') {
    try { rec.recorder.stop(); } catch (_) {}
  }
  const btn = document.getElementById('btnRecordVideo');
  if (btn) {
    btn.textContent = '🎬 Video';
    btn.style.borderColor = '';
    btn.style.color = '';
  }
}

async function generateVideoInstantWebCodecs(trace) {
  const { canvas, renderFrame } = createSourceVideoRenderer(trace);
  const candidates = [
    { codec: 'vp09.00.10.08', codecId: 'V_VP9' },
    { codec: 'vp8', codecId: 'V_VP8' }
  ];
  let chosen = null;
  for (const c of candidates) {
    try {
      const sup = await VideoEncoder.isConfigSupported({
        codec: c.codec,
        width: canvas.width,
        height: canvas.height,
        bitrate: 4000000
      });
      if (sup && sup.supported) {
        chosen = c;
        break;
      }
    } catch (_) {}
  }
  if (!chosen) return false;

  const btn = document.getElementById('btnRecordVideo');
  const state = { cancelled: false, timer: null, recorder: null };
  activeVideoRecording = state;

  const encodedChunks = [];
  let encoderError = null;
  const encoder = new VideoEncoder({
    output: (chunk) => {
      const buf = new Uint8Array(chunk.byteLength);
      chunk.copyTo(buf);
      encodedChunks.push({
        data: buf,
        timestampMs: chunk.timestamp / 1000,
        isKey: chunk.type === 'key'
      });
    },
    error: (err) => {
      encoderError = err;
    }
  });

  encoder.configure({
    codec: chosen.codec,
    width: canvas.width,
    height: canvas.height,
    bitrate: 4000000
  });

  const totalSteps = trace.steps.length;
  const intervalMs = Math.max(16, Math.min(2000, getPlayIntervalMs()));
  const intervalUs = intervalMs * 1000;

  if (btn) {
    btn.style.borderColor = 'var(--accent)';
    btn.style.color = 'var(--accent)';
  }

  for (let i = 0; i < totalSteps; i++) {
    if (state.cancelled || encoderError) break;
    renderFrame(i);
    const vf = new VideoFrame(canvas, {
      timestamp: i * intervalUs,
      duration: intervalUs
    });
    encoder.encode(vf, { keyFrame: (i % 30 === 0) });
    vf.close();

    if (i % 20 === 0 || i === totalSteps - 1 || encoder.encodeQueueSize > 10) {
      if (btn) {
        const pct = Math.round(((i + 1) / totalSteps) * 100);
        btn.textContent = `⚡ ${pct}% (${i + 1}/${totalSteps})`;
      }
      await new Promise(r => setTimeout(r, 0));
    }
  }

  if (!state.cancelled && !encoderError && totalSteps > 0) {
    // Hold the final frame for 600ms so video players display the end state cleanly
    renderFrame(totalSteps - 1);
    const holdUs = 600 * 1000;
    const endVf = new VideoFrame(canvas, {
      timestamp: totalSteps * intervalUs,
      duration: holdUs
    });
    encoder.encode(endVf, { keyFrame: true });
    endVf.close();
    await encoder.flush();
  }

  try { encoder.close(); } catch (_) {}

  if (activeVideoRecording === state) {
    activeVideoRecording = null;
  }

  if (state.cancelled || encoderError || encodedChunks.length === 0) {
    if (btn) {
      btn.textContent = '🎬 Video';
      btn.style.borderColor = '';
      btn.style.color = '';
    }
    return !encoderError;
  }

  const totalDurationMs = totalSteps * intervalMs + 600;
  const blob = muxWebmVideo(encodedChunks, canvas.width, canvas.height, chosen.codecId, totalDurationMs);
  downloadVideoBlob(blob, trace.name, 'webm');

  if (btn) {
    btn.textContent = '✓ Video Saved!';
    btn.style.borderColor = 'var(--green)';
    btn.style.color = 'var(--green)';
    setTimeout(() => {
      if (!activeVideoRecording) {
        btn.textContent = '🎬 Video';
        btn.style.borderColor = '';
        btn.style.color = '';
      }
    }, 1500);
  }
  return true;
}

async function toggleVideoRecording() {
  if (activeVideoRecording) {
    stopVideoRecording();
    return;
  }
  if (!currentTrace || !currentTrace.steps || currentTrace.steps.length === 0) return;

  stopPlayback();
  setEditMode(false);

  const trace = currentTrace;

  if (typeof VideoEncoder !== 'undefined' && typeof VideoFrame !== 'undefined') {
    try {
      const ok = await generateVideoInstantWebCodecs(trace);
      if (ok) return;
    } catch (err) {
      console.warn('WebCodecs instant export failed, falling back to MediaRecorder:', err);
    }
  }

  const format = pickSupportedVideoMime();
  if (!format) {
    alert('Neither WebCodecs nor MediaRecorder is supported in this browser.');
    return;
  }

  const totalSteps = trace.steps.length;
  const { canvas, renderFrame } = createSourceVideoRenderer(trace);

  if (typeof canvas.captureStream !== 'function') {
    alert('HTMLCanvasElement.captureStream() is not supported in this browser.');
    return;
  }

  const stream = canvas.captureStream(30);
  const videoTrack = stream.getVideoTracks()[0];
  const requestCanvasFrame = () => {
    if (videoTrack && typeof videoTrack.requestFrame === 'function') {
      try { videoTrack.requestFrame(); } catch (_) {}
    }
  };

  const recorderOpts = { videoBitsPerSecond: 4000000 };
  if (format.mime) recorderOpts.mimeType = format.mime;
  const recorder = new MediaRecorder(stream, recorderOpts);
  const chunks = [];

  recorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) chunks.push(e.data);
  };

  recorder.onstop = () => {
    stream.getTracks().forEach(t => t.stop());
    if (chunks.length === 0) return;
    const blob = new Blob(chunks, { type: format.mime || 'video/webm' });
    downloadVideoBlob(blob, trace.name, format.ext);
  };

  const btn = document.getElementById('btnRecordVideo');
  const updateButtonProgress = (idx) => {
    if (!btn) return;
    btn.textContent = `⏹ Stop (${idx + 1}/${totalSteps})`;
    btn.style.borderColor = 'var(--red)';
    btn.style.color = '#ff7b72';
  };

  currentIdx = 0;
  renderStep();
  renderFrame(0);
  requestCanvasFrame();
  recorder.start(100);

  const state = { cancelled: false, recorder, timer: null };
  activeVideoRecording = state;
  updateButtonProgress(0);

  const stepAdvance = () => {
    if (activeVideoRecording !== state) return;
    if (currentIdx < totalSteps - 1) {
      currentIdx++;
      renderStep();
      renderFrame(currentIdx);
      requestCanvasFrame();
      updateButtonProgress(currentIdx);
      const delayMs = Math.max(16, Math.min(2000, getPlayIntervalMs()));
      state.timer = setTimeout(stepAdvance, delayMs);
    } else {
      renderFrame(currentIdx);
      requestCanvasFrame();
      state.timer = setTimeout(() => {
        if (activeVideoRecording === state) {
          stopVideoRecording();
        }
      }, 650);
    }
  };

  const initialDelayMs = Math.max(80, Math.min(400, getPlayIntervalMs()));
  state.timer = setTimeout(stepAdvance, initialDelayMs);
}

document.getElementById('btnRecordVideo').addEventListener('click', toggleVideoRecording);

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

presetSelect.addEventListener('change', async (e) => {
  clearBrowserUrlCodeParam();
  const preset = PRESETS[parseInt(e.target.value, 10)];
  if (currentPrismVersionIdx === 0) {
    loadTrace(preset);
  } else {
    await parseWithWasm(preset.source, preset.name, false);
  }
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

updatePlayIntervalUI(getPlayIntervalMs());

document.getElementById('btnSettings').addEventListener('click', () => {
  const pop = document.getElementById('settingsPopover');
  const opening = !pop.classList.contains('open');
  pop.classList.toggle('open');
  if (opening) {
    const ms = getPlayIntervalMs();
    const intervalInput = document.getElementById('playIntervalInput');
    if (intervalInput) intervalInput.value = ms;
    updatePlayIntervalUI(ms);
    const input = document.getElementById('repoRootInput');
    input.value = getRepoRoot();
  }
});

document.getElementById('playIntervalInput').addEventListener('change', (e) => {
  const clamped = setPlayIntervalMs(e.target.value);
  e.target.value = clamped;
});

document.getElementById('playIntervalInput').addEventListener('input', (e) => {
  const val = parseInt(e.target.value, 10);
  if (Number.isFinite(val) && val >= 10 && val <= 10000) {
    setPlayIntervalMs(val);
  }
});

document.getElementById('playIntervalInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    const clamped = setPlayIntervalMs(e.target.value);
    e.target.value = clamped;
    document.getElementById('settingsPopover').classList.remove('open');
  } else if (e.key === 'Escape') {
    e.preventDefault();
    document.getElementById('settingsPopover').classList.remove('open');
  }
});

document.querySelectorAll('.interval-preset-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    const ms = parseInt(btn.getAttribute('data-ms'), 10);
    const clamped = setPlayIntervalMs(ms);
    const intervalInput = document.getElementById('playIntervalInput');
    if (intervalInput) intervalInput.value = clamped;
  });
});

document.getElementById('btnCloseSettings').addEventListener('click', () => {
  document.getElementById('settingsPopover').classList.remove('open');
});

document.getElementById('btnSaveRepoRoot').addEventListener('click', () => {
  const intervalInput = document.getElementById('playIntervalInput');
  if (intervalInput && intervalInput.value) {
    intervalInput.value = setPlayIntervalMs(intervalInput.value);
  }
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

function buildTraceSummaryObject() {
  if (!currentTrace) return { loaded: false };
  const steps = currentTrace.steps || [];
  const lastStep = steps[steps.length - 1] || {};
  const lo = lastStep.line_offsets || [];
  const badLineOffsets = [];
  for (let i = 1; i < lo.length; i++) {
    if (lo[i] <= lo[i - 1]) {
      badLineOffsets.push({ lineIndex: i, offset: lo[i], prevOffset: lo[i - 1] });
    }
  }
  const crashStep = currentTrace._crashIdx >= 0 ? steps[currentTrace._crashIdx] : null;
  const { wasm_b64, ...cleanBuildInfo } = PRISM_BUILD_INFO || {};
  return {
    name: currentTrace.name,
    prismBuild: cleanBuildInfo,
    availableVersions: PRISM_VERSIONS.map(v => ({
      id: v.id,
      version: v.version,
      short_sha: v.short_sha,
      date: v.date
    })),
    source: currentTrace.source,
    sourceBytes: new TextEncoder().encode(currentTrace.source).length,
    shareUrl: buildShareableUrl(currentTrace.source),
    currentStepIndex: currentIdx,
    totalSteps: steps.length,
    lexTokenCount: steps.filter(s => s.kind === 'LEX_TOKEN').length,
    rewindCount: steps.filter(s => s._isRewind).length,
    peakArenaBytes: currentTrace._peakMemUsed || 0,
    crash: crashStep ? {
      stepIndex: currentTrace._crashIdx,
      step: crashStep.step,
      func: (crashStep.detail && crashStep.detail.func) || crashStep.func,
      file: stepSourceFile(crashStep),
      line: (crashStep.detail && crashStep.detail.line) || crashStep.line,
      reason: crashStep.detail && crashStep.detail.reason,
      expr: crashStep.detail && crashStep.detail.expr
    } : null,
    underflows: (currentTrace._underflowEvents || []).map(ev => ({
      stepIndex: ev.stepIdx,
      step: ev.step,
      nodeId: ev.node.id,
      nodeType: ev.node.type,
      start: ev.node.start,
      end: ev.node.end,
      len: ev.node.len,
      func: ev.func,
      file: ev.file,
      line: ev.line
    })),
    lineOffsetsCount: lo.length,
    lineOffsetAnomalies: badLineOffsets
  };
}

function buildStepStateObject(idx = currentIdx) {
  if (!currentTrace || !currentTrace.steps.length) return { error: 'No trace loaded' };
  const clamped = Math.max(0, Math.min(currentTrace.steps.length - 1, idx));
  const s = currentTrace.steps[clamped];
  return {
    stepIndex: clamped,
    totalSteps: currentTrace.steps.length,
    step: s.step,
    kind: s.kind,
    func: s.func,
    file: stepSourceFile(s),
    line: s.line,
    detail: s.detail || {},
    prevToken: { start: s.prev[0], end: s.prev[1], type: s.prev[2] },
    currToken: { start: s.curr[0], end: s.curr[1], type: s.curr[2] },
    nextStart: s.next_start,
    heredocEnd: s.heredoc_end,
    lexState: s.lex_state,
    lexModes: s.lex_modes || [],
    contexts: s.contexts || [],
    callStack: s.call_stack || [],
    lineOffsets: s.line_offsets || [],
    errors: s.errors || 0,
    isRewind: Boolean(s._isRewind),
    rewindDelta: s._rewindDelta || 0,
    hasNewUnderflow: Boolean(s._hasNewUnderflow),
    memUsedBytes: s._memTotalUsed || 0,
    memCapBytes: s._memTotalCap || 0,
    astNodes: s._astSnapshot || []
  };
}

async function registerWebMcpTools() {
  const toolDefs = [
    {
      name: 'parse_and_trace',
      description: 'Parse and trace a Ruby source snippet in the live Prism Wasm visualizer, update the UI and shareable URL (?code=), and return a structured summary of steps, tokens, crashes, AST location underflows, and line_offsets anomalies.',
      inputSchema: {
        type: 'object',
        properties: {
          code: {
            type: 'string',
            description: 'Ruby source code snippet to parse and trace with Prism.'
          },
          version: {
            type: 'string',
            description: `Optional Prism version ID to trace with (${PRISM_VERSIONS.map(v => v.id).join(', ')}).`
          },
          jumpTo: {
            type: 'string',
            enum: ['start', 'end', 'crash', 'underflow'],
            description: 'Optional position to move the playhead to after tracing (default: start).'
          }
        },
        required: ['code']
      },
      handler: async (input) => {
        if (input && input.version) {
          await selectPrismVersion(input.version, false);
        }
        const code = String(input && input.code !== undefined ? input.code : '');
        document.getElementById('rubyEditor').value = code;
        await parseWithWasm(code, 'WebMCP Input');
        if (input && input.jumpTo && currentTrace) {
          if (input.jumpTo === 'crash' && currentTrace._crashIdx >= 0) {
            jumpToStep(currentTrace._crashIdx);
          } else if (input.jumpTo === 'underflow' && currentTrace._underflowIdx >= 0) {
            jumpToStep(currentTrace._underflowIdx);
          } else if (input.jumpTo === 'end') {
            jumpToStep(currentTrace.steps.length - 1);
          } else {
            jumpToStep(0);
          }
        }
        return buildTraceSummaryObject();
      }
    },
    {
      name: 'get_trace_summary',
      description: 'Return metadata and anomaly summary for the currently loaded Prism trace (Prism version/SHA, Ruby source, total steps, crash details, AST node location underflows, duplicate/out-of-order line_offsets, peak arena memory, and shareable URL).',
      inputSchema: {
        type: 'object',
        properties: {}
      },
      handler: async () => buildTraceSummaryObject()
    },
    {
      name: 'get_step_state',
      description: 'Get the complete lexer, parser, call stack, line_offsets, memory, and AST snapshot for a trace step (defaults to the currently displayed step).',
      inputSchema: {
        type: 'object',
        properties: {
          step: {
            type: 'number',
            description: '0-based step index to inspect (defaults to current step).'
          },
          selectInUi: {
            type: 'boolean',
            description: 'Whether to move the viewer playhead to this step (default: true).'
          },
          format: {
            type: 'string',
            enum: ['json', 'markdown'],
            description: 'Output format: structured json (default) or markdown.'
          }
        }
      },
      handler: async (input = {}) => {
        const targetIdx = (typeof input.step === 'number' && !Number.isNaN(input.step))
          ? Math.max(0, Math.min(currentTrace.steps.length - 1, Math.trunc(input.step)))
          : currentIdx;
        if (input.selectInUi !== false && targetIdx !== currentIdx) {
          jumpToStep(targetIdx);
        }
        if (input.format === 'markdown') {
          return { stepIndex: targetIdx, markdown: buildGeminiContextMarkdown() };
        }
        return buildStepStateObject(targetIdx);
      }
    },
    {
      name: 'jump_to_step',
      description: 'Move the visualizer playhead to a specific step number or semantic landmark (crash, underflow, next_token, prev_token, next_ast, prev_ast, next_alloc, prev_alloc, next_rewind, prev_rewind, start, end) and return that step state.',
      inputSchema: {
        type: 'object',
        properties: {
          target: {
            type: 'string',
            description: "Step number (e.g. '42') or landmark: 'crash', 'underflow', 'next_token', 'prev_token', 'next_ast', 'prev_ast', 'next_alloc', 'prev_alloc', 'next_rewind', 'prev_rewind', 'start', 'end'."
          }
        },
        required: ['target']
      },
      handler: async (input = {}) => {
        const t = String(input.target || '').trim();
        if (t === 'crash' && currentTrace._crashIdx >= 0) jumpToStep(currentTrace._crashIdx);
        else if (t === 'underflow') document.getElementById('btnJumpUnderflow').click();
        else if (t === 'next_token') stepToKind(['LEX_TOKEN'], 1);
        else if (t === 'prev_token') stepToKind(['LEX_TOKEN'], -1);
        else if (t === 'next_ast') stepToKind(['NODE_NEW', 'NODE_LIST_APPEND'], 1);
        else if (t === 'prev_ast') stepToKind(['NODE_NEW', 'NODE_LIST_APPEND'], -1);
        else if (t === 'next_alloc') stepToAlloc(1);
        else if (t === 'prev_alloc') stepToAlloc(-1);
        else if (t === 'next_rewind') stepToRewind(1);
        else if (t === 'prev_rewind') stepToRewind(-1);
        else if (t === 'start') jumpToStep(0);
        else if (t === 'end') jumpToStep(currentTrace.steps.length - 1);
        else {
          const n = parseInt(t, 10);
          if (!Number.isNaN(n)) jumpToStep(n);
        }
        return buildStepStateObject(currentIdx);
      }
    },
    {
      name: 'search_trace_steps',
      description: 'Filter trace steps by event kind, C function name, cursor rewind, or AST location underflow to quickly locate key transitions.',
      inputSchema: {
        type: 'object',
        properties: {
          kind: {
            type: 'string',
            description: 'Optional event kind filter (e.g. LEX_TOKEN, LEX_MODE_PUSH, LEX_MODE_POP, HEREDOC_FLUSH, PARSE_ENTER, PARSE_EXIT, NODE_NEW, ERROR, CRASH).'
          },
          func: {
            type: 'string',
            description: 'Optional substring match on the C function name (e.g. parse_heredoc, escape_read).'
          },
          onlyRewinds: {
            type: 'boolean',
            description: 'If true, only return steps where parser->current.start rewound backward.'
          },
          onlyUnderflows: {
            type: 'boolean',
            description: 'If true, only return steps where a new AST node location underflow occurred.'
          },
          limit: {
            type: 'number',
            description: 'Maximum matching steps to return (default: 50, max: 200).'
          }
        }
      },
      handler: async (input = {}) => {
        const maxResults = Math.max(1, Math.min(200, Number(input.limit) || 50));
        const matches = [];
        const steps = (currentTrace && currentTrace.steps) || [];
        for (let i = 0; i < steps.length; i++) {
          const s = steps[i];
          if (input.kind && s.kind !== input.kind) continue;
          if (input.func && !(s.func || '').includes(input.func)) continue;
          if (input.onlyRewinds && !s._isRewind) continue;
          if (input.onlyUnderflows && !s._hasNewUnderflow) continue;
          matches.push({
            stepIndex: i,
            step: s.step,
            kind: s.kind,
            func: s.func,
            file: stepSourceFile(s),
            line: s.line,
            curr: s.curr,
            nextStart: s.next_start,
            heredocEnd: s.heredoc_end,
            isRewind: Boolean(s._isRewind),
            hasNewUnderflow: Boolean(s._hasNewUnderflow)
          });
          if (matches.length >= maxResults) break;
        }
        return { totalMatchedReturned: matches.length, matches };
      }
    }
  ];

  // Expose structured helper on window.prismMcp for direct DevTools / script automation
  const toolMap = Object.fromEntries(toolDefs.map(t => [t.name, t]));
  window.prismMcp = {
    tools: toolDefs.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
    async callTool(name, args = {}) {
      const def = toolMap[name];
      if (!def) throw new Error(`Unknown Prism WebMCP tool: ${name}`);
      return await def.handler(args);
    }
  };

  // Register with browser-native WebMCP (document.modelContext or navigator.modelContext)
  const mc = (typeof document !== 'undefined' && document.modelContext)
    || (typeof navigator !== 'undefined' && navigator.modelContext)
    || null;
  if (!mc) return;

  const webMcpTools = toolDefs.map(def => ({
    name: def.name,
    description: def.description,
    inputSchema: def.inputSchema,
    execute: async (input) => {
      try {
        const result = await def.handler(input || {});
        return {
          content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
          structuredContent: result
        };
      } catch (err) {
        return {
          content: [{ type: 'text', text: `Error in ${def.name}: ${err && err.message ? err.message : String(err)}` }],
          isError: true
        };
      }
    }
  }));

  try {
    if (typeof mc.registerTool === 'function') {
      for (const tool of webMcpTools) {
        await mc.registerTool(tool);
      }
    } else if (typeof mc.provideContext === 'function') {
      await mc.provideContext({ tools: webMcpTools });
    }
  } catch (err) {
    console.warn('WebMCP tool registration warning:', err);
  }
}

(async function initFromUrlOrPreset() {
  loadTrace(PRESETS[0]);
  await registerWebMcpTools();
  const params = new URLSearchParams(window.location.search);
  const versionParam = params.get('version');
  const codeParam = params.get('code');
  const stepParam = params.get('step');
  const hasCodeParam = (codeParam !== null && codeParam !== '');
  if (versionParam) {
    await selectPrismVersion(versionParam, !hasCodeParam);
  } else {
    await initWasm();
  }
  if (hasCodeParam) {
    try {
      const decoded = decodeCodeBase64(codeParam);
      document.getElementById('rubyEditor').value = decoded;
      await parseWithWasm(decoded, 'Shared URL Snippet');
    } catch (err) {
      document.getElementById('wasmStatus').innerHTML =
        `<span style="color:var(--red)">Invalid ?code= Base64 parameter: ${escapeHtml(err.message)}</span>`;
    }
  }
  if (stepParam && currentTrace) {
    if (stepParam === 'crash' && currentTrace._crashIdx >= 0) {
      jumpToStep(currentTrace._crashIdx);
    } else if (stepParam === 'underflow' && currentTrace._underflowIdx >= 0) {
      jumpToStep(currentTrace._underflowIdx);
    } else {
      const n = parseInt(stepParam, 10);
      if (!Number.isNaN(n)) jumpToStep(n);
    }
  }
})();
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

ruby_svg_b64 = [File.binread(File.join(PRISM_DIR, "doc/images/ruby.svg"))].pack("m0")

version_h_path = File.join(PRISM_DIR, "include/prism/version.h")
prism_semver = if File.exist?(version_h_path)
  File.read(version_h_path)[/#define\s+PRISM_VERSION\s+"([^"]+)"/, 1] || "unknown"
else
  "unknown"
end
prism_sha = IO.popen(["git", "-C", PRISM_DIR, "rev-parse", "HEAD"], err: File::NULL, &:read).strip
prism_short_sha = IO.popen(["git", "-C", PRISM_DIR, "rev-parse", "--short=9", "HEAD"], err: File::NULL, &:read).strip
prism_describe = IO.popen(["git", "-C", PRISM_DIR, "describe", "--tags", "--always"], err: File::NULL, &:read).strip
prism_date = IO.popen(["git", "-C", PRISM_DIR, "show", "-s", "--format=%cs", "HEAD"], err: File::NULL, &:read).strip
prism_short_sha = "local" if prism_short_sha.empty?
prism_describe = "v#{prism_semver}" if prism_describe.empty?
prism_commit_url = prism_sha.empty? ? "https://github.com/ruby/prism" : "https://github.com/ruby/prism/commit/#{prism_sha}"
prism_version_title = "Built with Prism v#{prism_semver} (#{prism_describe}#{prism_date.empty? ? '' : ", #{prism_date}"}) — click to view commit on GitHub"

prism_versions = []
versions_root = File.join(BUILD_DIR, "versions")
if Dir.exist?(versions_root)
  Dir.children(versions_root).sort.each do |entry|
    vdir = File.join(versions_root, entry)
    meta_file = File.join(vdir, "meta.json")
    wasm_file = File.join(vdir, "prism_trace.wasm")
    next unless File.exist?(meta_file)

    meta = JSON.parse(File.read(meta_file, encoding: "UTF-8"))
    compat_file = File.join(vdir, "trace_compat.h")
    meta["has_arena"] = if File.exist?(compat_file)
      File.read(compat_file).include?("#define PRISM_HAS_ARENA 1")
    else
      !meta["version"].to_s.start_with?("1.")
    end
    meta["wasm_b64"] = File.exist?(wasm_file) ? [File.binread(wasm_file)].pack("m0") : ""
    prism_versions << meta
  end
end

if prism_versions.empty?
  wasm_path = File.join(BUILD_DIR, "prism_trace.wasm")
  wasm_b64 = File.exist?(wasm_path) ? [File.binread(wasm_path)].pack("m0") : ""
  prism_versions << {
    "id" => prism_describe,
    "label" => "#{prism_describe} (#{prism_short_sha})",
    "version" => prism_semver,
    "sha" => prism_sha,
    "short_sha" => prism_short_sha,
    "describe" => prism_describe,
    "date" => prism_date,
    "url" => prism_commit_url,
    "wasm_b64" => wasm_b64
  }
end

primary_info = prism_versions.first

playground_root = File.expand_path("..", __dir__)
playground_sha = IO.popen(["git", "-C", playground_root, "rev-parse", "HEAD"], err: File::NULL, &:read).strip
playground_short_sha = IO.popen(["git", "-C", playground_root, "rev-parse", "--short=7", "HEAD"], err: File::NULL, &:read).strip
playground_date = IO.popen(["git", "-C", playground_root, "show", "-s", "--format=%cs", "HEAD"], err: File::NULL, &:read).strip
playground_remote = IO.popen(["git", "-C", playground_root, "config", "--get", "remote.origin.url"], err: File::NULL, &:read).strip
playground_repo_name = if playground_remote =~ %r{github\.com[:/]([^/]+/[^/.]+?)(?:\.git)?$}
  Regexp.last_match(1)
else
  "stevenjohnstone/prism-playground"
end
playground_repo_slug = playground_repo_name.split("/").last || "prism-playground"
playground_repo_url = "https://github.com/#{playground_repo_name}"
playground_short_sha = "local" if playground_short_sha.empty?
playground_date = Time.now.strftime("%Y-%m-%d") if playground_date.empty?
playground_commit_url = playground_sha.empty? ? playground_repo_url : "#{playground_repo_url}/commit/#{playground_sha}"
playground_title = "#{playground_repo_name} built from commit #{playground_short_sha} (#{playground_date}) — click to view project source on GitHub"

html = HTML_TEMPLATE
  .sub("__RUBY_SVG_BASE64__") { ruby_svg_b64 }
  .sub("__PRISM_VERSION__") { primary_info["version"] }
  .sub("__PRISM_SHORT_SHA__") { primary_info["short_sha"] }
  .sub("__PRISM_COMMIT_URL__") { primary_info["url"] }
  .sub("__PRISM_VERSION_TITLE__") { prism_version_title }
  .gsub("__PLAYGROUND_REPO_NAME__") { playground_repo_name }
  .gsub("__PLAYGROUND_REPO_SLUG__") { playground_repo_slug }
  .gsub("__PLAYGROUND_REPO_URL__") { playground_repo_url }
  .gsub("__PLAYGROUND_SHORT_SHA__") { playground_short_sha }
  .gsub("__PLAYGROUND_DATE__") { playground_date }
  .gsub("__PLAYGROUND_COMMIT_URL__") { playground_commit_url }
  .gsub("__PLAYGROUND_TITLE__") { playground_title }
  .sub("__PRISM_BUILD_INFO_JSON__") { JSON.generate(primary_info) }
  .sub("__PRISM_VERSIONS_JSON__") { JSON.generate(prism_versions) }
  .sub("__PRESETS_JSON__") { JSON.generate(presets) }

out_html = OUT_HTML
FileUtils.mkdir_p(File.dirname(out_html))
File.write(out_html, html, encoding: "UTF-8")
version_labels = prism_versions.map { |v| "#{v['id']}@#{v['short_sha']}" }.join(", ")
puts "Generated standalone interactive viewer at #{out_html} (embedded versions: #{version_labels})"
