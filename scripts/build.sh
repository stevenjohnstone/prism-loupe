#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Load default Prism repo and WASI SDK version
source "$ROOT_DIR/PRISM_VERSION"

PRISM_DIR="${PRISM_DIR:-$ROOT_DIR/vendor/prism}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# 1. Ensure Prism checkout exists
if [ ! -d "$PRISM_DIR/.git" ] && [ ! -f "$PRISM_DIR/src/prism.c" ]; then
  echo "==> Cloning Prism ($PRISM_REPO) into $PRISM_DIR..."
  mkdir -p "$(dirname "$PRISM_DIR")"
  git clone "$PRISM_REPO" "$PRISM_DIR"
elif [ "$PRISM_DIR" = "$ROOT_DIR/vendor/prism" ] && [ -d "$PRISM_DIR/.git" ] && [ -n "${FORCE_PRISM_CHECKOUT:-}" ]; then
  echo "==> Fetching latest tags and branches from origin in $PRISM_DIR..."
  git -C "$PRISM_DIR" fetch --tags origin
fi

# 2. Locate or download WASI SDK for in-browser WebAssembly compilation
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

# 3. Determine which Prism version(s) to build
REFS_TO_BUILD=()
if [ "$PRISM_DIR" != "$ROOT_DIR/vendor/prism" ]; then
  REFS_TO_BUILD=("local")
elif [ -n "${PRISM_REF:-}" ]; then
  REFS_TO_BUILD=("$PRISM_REF")
elif [ -n "${PRISM_REFS:-}" ]; then
  read -r -a REFS_TO_BUILD <<< "$PRISM_REFS"
else
  # Auto-select: last 2 minor releases in current major + last release from previous major + main
  AUTO_REFS="$(ruby -e '
    tags = `git -C "#{ARGV[0]}" tag -l`.lines.map(&:strip)
    parsed = tags.filter_map do |t|
      if t =~ /\Av(\d+)\.(\d+)\.(\d+)\z/
        [$1.to_i, $2.to_i, $3.to_i, t]
      end
    end
    by_minor = {}
    parsed.sort.each { |maj, min, pat, t| by_minor[[maj, min]] = t }
    majors = by_minor.keys.map(&:first).uniq.sort
    selected = []
    if (cur_maj = majors.last)
      cur_minors = by_minor.select { |(maj, _), _| maj == cur_maj }.sort_by(&:first).map(&:last)
      selected.concat(cur_minors.last(2).reverse)
      prev_maj = cur_maj - 1
      prev_minors = by_minor.select { |(maj, _), _| maj == prev_maj }.sort_by(&:first).map(&:last)
      selected << prev_minors.last if prev_minors.any?
    end
    selected << "main"
    puts selected.uniq.join(" ")
  ' "$PRISM_DIR")"
  read -r -a REFS_TO_BUILD <<< "$AUTO_REFS"
fi

echo "==> Prism version(s) to build: ${REFS_TO_BUILD[*]}"

rm -rf "$BUILD_DIR/versions"
mkdir -p "$BUILD_DIR/versions" "$BUILD_DIR/wasm_cache"

INSTRUMENT_HASH="$(shasum -a 256 "$ROOT_DIR/src/instrument.rb" "$ROOT_DIR/src/trace_runtime.c" "$ROOT_DIR/src/trace_runtime.h" "$ROOT_DIR/src/prism_xallocator.h" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"

build_prism_version() {
  local idx="$1"
  local ref="$2"
  local ver_dir="$BUILD_DIR/versions/$(printf "%02d" "$idx")"
  mkdir -p "$ver_dir"

  if [ "$PRISM_DIR" = "$ROOT_DIR/vendor/prism" ] && [ -d "$PRISM_DIR/.git" ]; then
    local target_ref="$ref"
    if [ "$ref" = "main" ] && git -C "$PRISM_DIR" rev-parse --verify --quiet origin/main >/dev/null; then
      target_ref="origin/main"
    fi
    local cur_sha
    cur_sha="$(git -C "$PRISM_DIR" rev-parse HEAD)"
    local target_sha
    target_sha="$(git -C "$PRISM_DIR" rev-parse "${target_ref}^{commit}" 2>/dev/null || true)"
    if [ -z "$target_sha" ]; then
      echo "==> Fetching $ref from origin..."
      git -C "$PRISM_DIR" fetch origin "$ref"
      target_sha="$(git -C "$PRISM_DIR" rev-parse "FETCH_HEAD^{commit}")"
      target_ref="$target_sha"
    fi
    if [ "$cur_sha" != "$target_sha" ]; then
      echo "==> Checking out Prism $ref ($target_sha)..."
      git -C "$PRISM_DIR" clean -fdx include src
      git -C "$PRISM_DIR" checkout --quiet "$target_ref"
    fi
  fi

  local sha
  sha="$(git -C "$PRISM_DIR" rev-parse HEAD 2>/dev/null || echo "")"
  local short_sha
  short_sha="$(git -C "$PRISM_DIR" rev-parse --short=9 HEAD 2>/dev/null || echo "local")"
  local describe
  describe="$(git -C "$PRISM_DIR" describe --tags --always 2>/dev/null || echo "$ref")"
  local commit_date
  commit_date="$(git -C "$PRISM_DIR" show -s --format=%cs HEAD 2>/dev/null || echo "")"

  local cached_wasm="$BUILD_DIR/wasm_cache/prism_trace_${sha}_${INSTRUMENT_HASH}.wasm"

  local need_compile=0
  if [ ! -f "$cached_wasm" ] || [ "${BUILD_CLI:-0}" = "1" ]; then
    need_compile=1
  fi

  if [ "$need_compile" -eq 1 ]; then
    if [ ! -f "$PRISM_DIR/src/node.c" ] || [ ! -f "$PRISM_DIR/include/prism/ast.h" ]; then
      echo "==> Running templates/template.rb for Prism $ref..."
      (cd "$PRISM_DIR" && ruby templates/template.rb)
    fi

    echo "==> Instrumenting Prism $ref ($short_sha)..."
    ruby "$ROOT_DIR/src/instrument.rb" "$PRISM_DIR" "$ver_dir"

    local support_srcs=()
    for f in "$PRISM_DIR"/src/*.c "$PRISM_DIR"/src/util/*.c; do
      [ -e "$f" ] || continue
      local base
      base="$(basename "$f")"
      if [ "$base" != "prism.c" ] && [ "$base" != "node.c" ]; then
        support_srcs+=("$f")
      fi
    done

    if [ "${BUILD_CLI:-0}" = "1" ] && [ "$idx" -eq 0 ]; then
      cp "$ver_dir/trace_prism.c" "$BUILD_DIR/trace_prism.c"
      cp "$ver_dir/trace_node.c" "$BUILD_DIR/trace_node.c"
      cp "$ver_dir/trace_compat.h" "$BUILD_DIR/trace_compat.h"
      echo "==> Compiling native prism_trace CLI ($ref)..."
      ${CC:-cc} -O0 -g -std=c99 -D_POSIX_C_SOURCE=200809L -DPRISM_XALLOCATOR \
        -I"$ver_dir" -I"$PRISM_DIR/include" -I"$PRISM_DIR/src" -I"$ROOT_DIR/src" \
        "$ver_dir/trace_prism.c" \
        "$ver_dir/trace_node.c" \
        "$ROOT_DIR/src/trace_runtime.c" \
        "$ROOT_DIR/src/trace_main.c" \
        "${support_srcs[@]}" \
        -o "$BUILD_DIR/prism_trace"
    fi

    if [ -n "${WASI_SDK_PATH:-}" ] && [ -x "${WASI_SDK_PATH}/bin/clang" ]; then
      if [ -f "$cached_wasm" ]; then
        echo "==> Using cached WebAssembly module for Prism $ref ($short_sha)"
        cp "$cached_wasm" "$ver_dir/prism_trace.wasm"
      else
        echo "==> Building WebAssembly module for Prism $ref ($short_sha)..."
        "${WASI_SDK_PATH}/bin/clang" --sysroot="${WASI_SDK_PATH}/share/wasi-sysroot" \
          -DPRISM_EXPORT_SYMBOLS -DPRISM_EXCLUDE_PRETTYPRINT -DPRISM_EXCLUDE_JSON -DPRISM_XALLOCATOR \
          -D_WASI_EMULATED_MMAN -lwasi-emulated-mman \
          -I"$ver_dir" -I"$PRISM_DIR/include" -I"$PRISM_DIR/src" -I"$ROOT_DIR/src" \
          -std=c99 \
          -Wl,--export=malloc,--export=free,--export=pm_buffer_new,--export=pm_buffer_value,--export=pm_buffer_length,--export=pm_buffer_free,--export=prism_trace_run_to_buffer \
          -Wl,-z,stack-size=8388608 \
          -Wl,--gc-sections -Wl,--strip-all -Wl,--no-entry -mexec-model=reactor \
          -Oz -g0 -fdata-sections -ffunction-sections \
          -o "$ver_dir/prism_trace.wasm" \
          "$ver_dir/trace_prism.c" \
          "$ver_dir/trace_node.c" \
          "$ROOT_DIR/src/trace_runtime.c" \
          "${support_srcs[@]}"
        if [ -n "$sha" ]; then
          cp "$ver_dir/prism_trace.wasm" "$cached_wasm"
        fi
      fi
    fi
  else
    echo "==> Using cached WebAssembly module for Prism $ref ($short_sha)"
    cp "$cached_wasm" "$ver_dir/prism_trace.wasm"
  fi

  if [ "$idx" -eq 0 ] && [ -f "$ver_dir/prism_trace.wasm" ]; then
    cp "$ver_dir/prism_trace.wasm" "$BUILD_DIR/prism_trace.wasm"
  fi

  local semver="unknown"
  if [ -f "$PRISM_DIR/include/prism/version.h" ]; then
    semver="$(ruby -e 'puts(File.read(ARGV[0])[/#define\s+PRISM_VERSION\s+"([^"]+)"/, 1] || "unknown")' "$PRISM_DIR/include/prism/version.h")"
  fi

  local has_arena="false"
  if [ -f "$PRISM_DIR/include/prism/arena.h" ]; then
    has_arena="true"
  fi

  ruby -rjson -e '
    id, semver, sha, short_sha, describe, date, has_arena, out = ARGV
    url = sha.empty? ? "https://github.com/ruby/prism" : "https://github.com/ruby/prism/commit/#{sha}"
    label = id == "main" ? "main (v#{semver} @ #{short_sha})" : "#{id} (#{short_sha})"
    meta = {
      "id" => id,
      "label" => label,
      "version" => semver,
      "sha" => sha,
      "short_sha" => short_sha,
      "describe" => describe,
      "date" => date,
      "url" => url,
      "has_arena" => (has_arena == "true")
    }
    File.write(out, JSON.pretty_generate(meta))
  ' "$ref" "$semver" "$sha" "$short_sha" "$describe" "$commit_date" "$has_arena" "$ver_dir/meta.json"
}

idx=0
for ref in "${REFS_TO_BUILD[@]}"; do
  build_prism_version "$idx" "$ref"
  idx=$((idx + 1))
done

# Restore vendor/prism to the primary ref if multiple refs were built
if [ "${#REFS_TO_BUILD[@]}" -gt 1 ] && [ "$PRISM_DIR" = "$ROOT_DIR/vendor/prism" ] && [ -d "$PRISM_DIR/.git" ]; then
  PRIMARY_REF="${REFS_TO_BUILD[0]}"
  if [ "$PRIMARY_REF" = "main" ] && git -C "$PRISM_DIR" rev-parse --verify --quiet origin/main >/dev/null; then
    PRIMARY_REF="origin/main"
  fi
  git -C "$PRISM_DIR" clean -fdx include src
  git -C "$PRISM_DIR" checkout --quiet "$PRIMARY_REF"
fi

# Generate standalone web application in dist/index.html
echo "==> Generating web application in $DIST_DIR/index.html..."
ruby "$ROOT_DIR/src/make_viewer.rb" "$PRISM_DIR" "$BUILD_DIR" "$DIST_DIR/index.html"
touch "$DIST_DIR/.nojekyll"
echo "==> Done! Open $DIST_DIR/index.html in your browser."
