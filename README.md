# Prism Playground — Interactive Parser & Lexer Trace Visualizer

An interactive, single-file, in-browser C99 parser, lexer, and AST execution visualizer for the [Prism Ruby parser](https://github.com/ruby/prism).

**Live Demo:** [https://stevenjohnstone.github.io/prism-playground/](https://stevenjohnstone.github.io/prism-playground/)

---

## Features

### 1. In-Browser WebAssembly Tracing
- **Live Ruby Editing**: Double-click the Ruby source buffer (or click **`✎ Edit Code`**) and press **`⌘+Enter` / `Ctrl+Enter`** to parse and trace any Ruby snippet directly in the browser via an embedded WASI WebAssembly build of Prism (`build/prism_trace.wasm`).
- **Fine-Grained Execution Events**: Records every `PARSE_ENTER`, `PARSE_EXIT`, `LEX_TOKEN`, `LEX_MODE_PUSH`, `LEX_MODE_POP`, `LEX_STATE`, `HEREDOC_FLUSH`, `NODE_NEW`, `NODE_LIST_APPEND`, `ERROR`, and `CRASH` transition while preserving exact upstream C source filenames and line numbers.
- **Version & Commit Provenance**: Displays the exact upstream `ruby/prism` semantic version and commit SHA badge in the header, linking directly to the corresponding commit on GitHub.
- **File Import**: Load `.rb` source files directly into the in-browser Wasm tracer (`📂 .rb`) or inspect pre-recorded `.jsonl` trace files (`📂 .jsonl`).

### 2. Interactive Timeline, Navigation & Playback
- **Color-Coded Timeline Scrubber**: Click or drag across the timeline bar to scrub through the trace. Visual markers highlight:
  - **Green**: Lexed tokens (`LEX_TOKEN`)
  - **Blue**: AST node creation and list appends (`NODE_NEW`, `NODE_LIST_APPEND`)
  - **Amber**: Lexer cursor rewinds (`s.curr[0] < prevCurrStart`, e.g., heredoc body restores)
  - **Pink**: Syntax errors (`ERROR`)
  - **Red**: Parser assertions / traps (`CRASH`) or invalid AST node bounds (`end < start`)
- **Targeted Step Controls & Keyboard Shortcuts**:
  - `Space`: Play / Pause automatic stepping
  - `←` / `→`: Previous / Next trace step
  - `Shift+←` / `Shift+→`: Previous / Next lexed token (`LEX_TOKEN`)
  - `n` / `Shift+n`: Next / Previous AST node event (`NODE_NEW` / `NODE_LIST_APPEND`)
  - `m` / `Shift+m`: Next / Previous arena memory allocation (`+Mem` / `-Mem`)
  - `r` / `Shift+r`: Next / Previous lexer cursor rewind (`+Rewind` / `-Rewind`)
  - `u` / `Shift+u`: Next / Previous invalid AST node location (`⚠ Bad Node`)
  - `c`: Jump to `CRASH` step (when present)
- **Configurable Playback Speed**: Click **`⚙` (Settings)** in the header to customize the playback step interval (`10ms`–`10000ms`, with quick presets for `50ms`, `100ms`, `250ms`, `500ms`, and `1s`), persisted in `localStorage`.

### 3. Three-Pane Parser & Lexer State Inspector
- **Pane 1 — Ruby Buffer & Live Lexer**:
  - Byte-accurate character grid highlighting `parser->previous` (amber), `parser->current` (green), active line, and hovered AST node ranges.
  - Live `parser->line_offsets` table with automatic detection of non-monotonic newline offset entries.
- **Pane 2 — Lexer State, Mode Stack & Call Stack**:
  - Current transition metadata (`step`, `kind`, `func`, C source location, `next_start`, `heredoc_end`, `lex_state`, and syntax error count).
  - Live `parser->lex_modes` stack (`top → bottom`), `parser->current_context` stack, and clickable `parse_*` recursive-descent call stack with GitHub source links.
- **Pane 3 — Live Arenas, Memory & AST Assembly**:
  - Real-time byte, capacity, and block telemetry for `parser->arena` (AST nodes), `metadata_arena`, `scratch_arena`, `line_offsets`, and `constant_pool`.
  - Live bottom-up AST forest distinguishing active candidate roots from superseded/orphaned nodes, with hover-to-highlight source spans and warnings for inverted node locations (`end < start`).

### 4. Shareable URLs & Instant Video Export
- **Shareable Links (`?code=`)**: Click **`🔗 Share`** to copy a URL with the current Ruby snippet Base64-encoded in the `?code=` query parameter (and optional `&step=<n|underflow|crash>` deep-linking). Opening the URL automatically decodes and traces the snippet in Wasm.
- **Instant Playthrough Video Export (`🎬 Video`)**: Click **`🎬 Video`** in the Source Input toolbar to generate a high-DPI `.webm` video of the Ruby source buffer being lexed and parsed step-by-step.
  - Uses the browser's **WebCodecs API** (`VideoEncoder` + `VideoFrame`) and a built-in WebM/EBML muxer to encode the entire playthrough faster-than-realtime (e.g., ~200 steps in under a second), paced to your configured playback interval (with automatic fallback to `MediaRecorder`).

### 5. WebMCP, Antigravity IDE & Gemini Integration
- **WebMCP (`navigator.modelContext`)**: Registers structured in-page tools (`parse_and_trace`, `get_trace_summary`, `get_step_state`, `jump_to_step`, and `search_trace_steps`) so browser AI agents and the WebMCP Inspector can query traces, search steps, and navigate the viewer programmatically.
- **Antigravity IDE Deep Links**: Configure your local Prism repository path in **`⚙` (Settings)** to enable **`↗ Antigravity IDE`** links (`antigravity-ide://file/<repo>/<file>:<line>`) on every trace step and call stack frame, while automatically copying the step's structured markdown context to your clipboard.
- **Gemini Context Sync**: Continuously updates a structured `<aside id="geminiPageContext">` DOM summary for Chrome's built-in Gemini side panel, plus an in-page **`✨ Ask Gemini`** drawer for other browsers.

---

## Building Locally

### Requirements

- `ruby` (3.0+)
- A C99 compiler (`cc` / `clang` / `gcc`)
- `curl` & `tar` (to automatically download [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) into `vendor/wasi-sdk` on first build if not already installed)

### Quick Start

```bash
make build
```

This runs `./scripts/build.sh`, which:
1. Clones `ruby/prism` at the commit specified in [`PRISM_VERSION`](PRISM_VERSION) into `vendor/prism` and runs `ruby templates/template.rb`.
2. Downloads `wasi-sdk` into `vendor/wasi-sdk` (if not already present).
3. Instruments `src/prism.c` and `src/node.c` via [`src/instrument.rb`](src/instrument.rb) while preserving exact `#line` directives.
4. Builds both the native CLI (`build/prism_trace`) and the in-browser WebAssembly reactor (`build/prism_trace.wasm`).
5. Generates the self-contained single-page application at `dist/index.html` via [`src/make_viewer.rb`](src/make_viewer.rb).

To regenerate `dist/index.html` after editing only [`src/make_viewer.rb`](src/make_viewer.rb):

```bash
ruby src/make_viewer.rb
```

To start a local HTTP server on `http://localhost:8080`:

```bash
make serve
```

### Building Against a Custom Prism Commit or Local Checkout

You can point the build at any Prism commit, branch, or local directory:

```bash
# Build against a specific upstream commit or tag:
PRISM_REF=v2.1.0 FORCE_PRISM_CHECKOUT=1 make build

# Or build against an existing local Prism checkout:
PRISM_DIR=/path/to/local/prism make build
```

---

## Deploying to GitHub Pages

This repository includes [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml), which automatically builds `dist/index.html` (with embedded WebAssembly and presets) and deploys it to GitHub Pages on every push to `main`.

In your GitHub repository settings (**Settings → Pages**), set **Build and deployment → Source** to **GitHub Actions**.
