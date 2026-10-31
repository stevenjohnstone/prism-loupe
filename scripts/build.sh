#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Load default Prism repo/ref and WASI SDK version
source "$ROOT_DIR/PRISM_VERSION"

PRISM_DIR="${PRISM_DIR:-$ROOT_DIR/vendor/prism}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# 1. Ensure Prism checkout exists and is at the desired ref (unless custom PRISM_DIR was passed)
if [ ! -d "$PRISM_DIR/.git" ] && [ ! -f "$PRISM_DIR/src/prism.c" ]; then
  echo "==> Cloning Prism ($PRISM_REPO) into $PRISM_DIR..."
  mkdir -p "$(dirname "$PRISM_DIR")"
  git clone "$PRISM_REPO" "$PRISM_DIR"
  git -C "$PRISM_DIR" checkout "$PRISM_REF"
elif [ "$PRISM_DIR" = "$ROOT_DIR/vendor/prism" ] && [ -d "$PRISM_DIR/.git" ]; then
  CUR_SHA="$(git -C "$PRISM_DIR" rev-parse HEAD)"
  TARGET_SHA="$(git -C "$PRISM_DIR" rev-parse "$PRISM_REF^{commit}" 2>/dev/null || true)"
  if [ "$CUR_SHA" != "$TARGET_SHA" ] || [ -n "${FORCE_PRISM_CHECKOUT:-}" ]; then
    echo "==> Updating $PRISM_DIR to $PRISM_REF..."
    if [ -z "$TARGET_SHA" ] || [ -n "${FORCE_PRISM_CHECKOUT:-}" ]; then
      git -C "$PRISM_DIR" fetch origin
    fi
    git -C "$PRISM_DIR" clean -fdx include src
    git -C "$PRISM_DIR" checkout "$PRISM_REF"
    (cd "$PRISM_DIR" && ruby templates/template.rb)
  fi
fi

# 2. Generate Prism template files (src/node.c, include/prism/ast.h, etc.) if missing
if [ ! -f "$PRISM_DIR/src/node.c" ] || [ ! -f "$PRISM_DIR/include/prism/ast.h" ]; then
  echo "==> Running templates/template.rb in $PRISM_DIR..."
  (cd "$PRISM_DIR" && ruby templates/template.rb)
fi

# 3. Locate or download WASI SDK for in-browser WebAssembly compilation
if [ -z "${WASI_SDK_PATH:-}" ]; then
  if [ -x "$ROOT_DIR/vendor/wasi-sdk/bin/clang" ]; then
    WASI_SDK_PATH="$ROOT_DIR/vendor/wasi-sdk"
  elif [ -x "/tmp/wasi-sdk-${WASI_SDK_FULL_VERSION}-arm64-macos/bin/clang" ]; then
    WASI_SDK_PATH="/tmp/wasi-sdk-${WASI_SDK_FULL_VERSION}-arm64-macos"
  elif [ -x "/opt/wasi-sdk/bin/clang" ]; then
    WASI_SDK_PATH="/opt/wasi-sdk"
  elif [ "${SKIP_WASM:-0}" != "1" ]; then
    OS_NAME="$(uname -s)"
    ARCH_NAME="$(uname -m)"
    case "${OS_NAME}-${ARCH_NAME}" in
      Darwin-arm64)  WASI_ARCH="arm64-macos" ;;
      Darwin-x86_64) WASI_ARCH="x86_64-macos" ;;
      Linux-x86_64)  WASI_ARCH="x86_64-linux" ;;
      Linux-aarch64|Linux-arm64) WASI_ARCH="arm64-linux" ;;
      *) WASI_ARCH="" ;;
    esac
    if [ -n "$WASI_ARCH" ]; then
      WASI_TAR="wasi-sdk-${WASI_SDK_FULL_VERSION}-${WASI_ARCH}.tar.gz"
      WASI_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/${WASI_TAR}"
      echo "==> Downloading WASI SDK (${WASI_URL})..."
      mkdir -p "$ROOT_DIR/vendor"
      curl -fSL "$WASI_URL" -o "$ROOT_DIR/vendor/$WASI_TAR"
      rm -rf "$ROOT_DIR/vendor/wasi-sdk"
      mkdir -p "$ROOT_DIR/vendor/wasi-sdk"
      tar -xzf "$ROOT_DIR/vendor/$WASI_TAR" -C "$ROOT_DIR/vendor/wasi-sdk" --strip-components=1
      rm -f "$ROOT_DIR/vendor/$WASI_TAR"
      WASI_SDK_PATH="$ROOT_DIR/vendor/wasi-sdk"
    fi
  fi
fi

# 4. Instrument Prism's src/prism.c and src/node.c
echo "==> Instrumenting Prism sources from $PRISM_DIR..."
ruby "$ROOT_DIR/src/instrument.rb" "$PRISM_DIR" "$BUILD_DIR"

# Collect supporting Prism C files (excluding src/prism.c and src/node.c which are replaced by instrumented copies)
PRISM_SUPPORT_SRCS=()
for f in "$PRISM_DIR"/src/*.c "$PRISM_DIR"/src/util/*.c; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  if [ "$base" != "prism.c" ] && [ "$base" != "node.c" ]; then
    PRISM_SUPPORT_SRCS+=("$f")
  fi
done

# 5. Compile native trace CLI (used to generate built-in presets)
echo "==> Compiling native prism_trace CLI..."
${CC:-cc} -O0 -g -std=c99 -D_POSIX_C_SOURCE=200809L \
  -I"$BUILD_DIR" -I"$PRISM_DIR/include" -I"$PRISM_DIR/src" -I"$ROOT_DIR/src" \
  "$BUILD_DIR/trace_prism.c" \
  "$BUILD_DIR/trace_node.c" \
  "$ROOT_DIR/src/trace_runtime.c" \
  "$ROOT_DIR/src/trace_main.c" \
  "${PRISM_SUPPORT_SRCS[@]}" \
  -o "$BUILD_DIR/prism_trace"

# 6. Compile WebAssembly trace reactor module for live in-browser tracing
if [ -n "${WASI_SDK_PATH:-}" ] && [ -x "${WASI_SDK_PATH}/bin/clang" ]; then
  echo "==> Building in-browser WebAssembly module with ${WASI_SDK_PATH}..."
  "${WASI_SDK_PATH}/bin/clang" --sysroot="${WASI_SDK_PATH}/share/wasi-sysroot" \
    -DPRISM_EXPORT_SYMBOLS -DPRISM_EXCLUDE_PRETTYPRINT -DPRISM_EXCLUDE_JSON \
    -D_WASI_EMULATED_MMAN -lwasi-emulated-mman \
    -I"$BUILD_DIR" -I"$PRISM_DIR/include" -I"$PRISM_DIR/src" -I"$ROOT_DIR/src" \
    -std=c99 \
    -Wl,--export=malloc,--export=free,--export=pm_buffer_new,--export=pm_buffer_value,--export=pm_buffer_length,--export=pm_buffer_free,--export=prism_trace_run_to_buffer \
    -Wl,-z,stack-size=8388608 \
    -Wl,--gc-sections -Wl,--strip-all -Wl,--no-entry -mexec-model=reactor \
    -Oz -g0 -fdata-sections -ffunction-sections \
    -o "$BUILD_DIR/prism_trace.wasm" \
    "$BUILD_DIR/trace_prism.c" \
    "$BUILD_DIR/trace_node.c" \
    "$ROOT_DIR/src/trace_runtime.c" \
    "${PRISM_SUPPORT_SRCS[@]}"
else
  echo "⚠ Warning: WASI SDK not found; viewer will be generated with presets only (no live in-browser Wasm)."
fi

# 7. Generate standalone web application in dist/index.html
echo "==> Generating web application in $DIST_DIR/index.html..."
ruby "$ROOT_DIR/src/make_viewer.rb" "$PRISM_DIR" "$BUILD_DIR" "$DIST_DIR/index.html"
touch "$DIST_DIR/.nojekyll"
echo "==> Done! Open $DIST_DIR/index.html in your browser."
