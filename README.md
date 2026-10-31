# Prism Playground — Interactive Parser & Lexer Trace Visualizer

An interactive, in-browser C99 parser, lexer, and AST execution visualizer for the [Prism Ruby parser](https://github.com/ruby/prism).

## Features

- **In-Browser WebAssembly Tracing**: Edit any Ruby snippet directly in the browser and trace every `PARSE_ENTER`, `PARSE_EXIT`, `LEX_TOKEN`, `LEX_MODE_PUSH`, `LEX_MODE_POP`, `LEX_STATE`, `HEREDOC_FLUSH`, `NODE_NEW`, `NODE_LIST_APPEND`, `ERROR`, and `CRASH` transition live via an embedded WASI WebAssembly build of Prism.
- **Interactive Timeline & Scrubber**: Click-and-drag timeline with event markers, directional step/token/AST/allocation/rewind navigation, and `▶ Play` / `⏸ Pause` playback (`Space`).
- **Arena Memory & `line_offsets` Telemetry**: Live byte/capacity/block telemetry for `parser->arena`, `metadata_arena`, `scratch_arena`, `line_offsets`, and `constant_pool`.
- **Antigravity IDE & Gemini Integration**:
  - Click **`⚙` (Settings)** in the top-right header to set your local Prism checkout path and enable one-click **`↗ Antigravity IDE`** deep links (`antigravity-ide://file/<repo>/<file>:<line>`) that simultaneously copy the current step's structured trace context to your clipboard.
  - Exposes a live `<aside id="geminiPageContext">` summary for Google Chrome's built-in Gemini side panel (and a fallback `✨ Ask Gemini` drawer in other browsers).

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
3. Instruments `src/prism.c` and `src/node.c` via [`src/instrument.rb`](src/instrument.rb) while preserving exact `#line` numbers.
4. Builds both the native CLI (`build/prism_trace`) and the in-browser WebAssembly reactor (`build/prism_trace.wasm`).
5. Generates the self-contained single-page application at `dist/index.html`.

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

## Deploying to GitHub Pages

This repository includes [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml), which automatically builds `dist/index.html` (with embedded WebAssembly and presets) and deploys it to GitHub Pages on every push to `main`.

In your GitHub repository settings (**Settings → Pages**), set **Build and deployment → Source** to **GitHub Actions**.
