#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/External/NativeStatic/.work}"
TARGET_CPU="${TARGET_CPU:-arm64}"
RID="${RID:-osx-$TARGET_CPU}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/External/NativeStatic/$RID}"
SKIASHARP_VERSION="${SKIASHARP_VERSION:-4.154.0-preview.1}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
SKIA_DEPS_RETRIES="${SKIA_DEPS_RETRIES:-3}"
HARFBUZZ_COMMIT="${HARFBUZZ_COMMIT:-863d3f7787c6df18d20e4535c5906bf3eb803bd5}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_tools() {
  require_cmd git
  require_cmd python3
  require_cmd clang
  require_cmd clang++
  require_cmd ar
  require_cmd ninja
}

ensure_depot_tools() {
  local depot_dir="$WORK_DIR/depot_tools"
  if [[ ! -d "$depot_dir/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  export PATH="$depot_dir:$PATH"
  if [[ ! -f "$depot_dir/python3_bin_reldir.txt" ]]; then
    "$depot_dir/ensure_bootstrap"
  fi
}

copy_first_existing() {
  local dest="$1"
  shift
  for src in "$@"; do
    if [[ -f "$src" ]]; then
      cp "$src" "$dest"
      echo "Wrote $dest"
      return 0
    fi
  done
  echo "None of the expected files exist for $dest:" >&2
  printf '  %s\n' "$@" >&2
  return 1
}

sync_skiasharp() {
  local src="$WORK_DIR/SkiaSharp-$SKIASHARP_VERSION"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch "release/$SKIASHARP_VERSION" https://github.com/mono/SkiaSharp.git "$src"
  else
    git -C "$src" fetch --depth 1 origin "release/$SKIASHARP_VERSION"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  git -C "$src" submodule update --init --depth 1 externals/skia >&2
  echo "$src"
}

prepare_skia_git_sync_deps() {
  skia_dir="$1"
python3 - "$skia_dir" "$HARFBUZZ_COMMIT" <<'PY'
import re
import pathlib
import sys

skia_dir = pathlib.Path(sys.argv[1])
harfbuzz_target = sys.argv[2]
sync_deps_path = skia_dir / "tools" / "git-sync-deps"
deps_path = skia_dir / "DEPS"

if deps_path.exists():
    deps = deps_path.read_text(encoding='utf-8', errors='ignore')
    # Normalize non-breaking spaces to standard spaces
    deps = deps.replace('\xa0', ' ')
    
    # List of unneeded third-party externals to strip out completely based on current build config
    unused_deps = [
        "dng_sdk",
        "piex",
        "spirv-cross",
        "vulkanmemoryallocator",
        "vulkan-headers",
        "d3d12allocator",
    ]
    
    for dep in unused_deps:
        pattern = rf'^\s*["\']third_party/externals/{dep}["\']\s*:\s*[^,\n]+,\s*\n'
        deps = re.sub(pattern, '', deps, flags=re.MULTILINE)
    
    # Dynamically update HarfBuzz hash using a callback function to avoid group reference errors
    def replace_harfbuzz(match):
        return match.group(1) + harfbuzz_target + match.group(2)
        
    deps = re.sub(
        r'(["\']third_party/externals/harfbuzz["\']\s*:\s*["\'][^@]+@)[^"\']+(["\'])',
        replace_harfbuzz,
        deps
    )
    # Safely swap Google's proxy mirrors for GitHub-backed dependencies directly to github.com
    deps = re.sub(
        r'https://(skia|chromium)\.googlesource\.com/external/github\.com/([^@]+)\.git',
        r'https://github.com/\2.git',
        deps
    )
    deps = re.sub(
        r'https://(skia|chromium)\.googlesource\.com/external/github\.com/([^@"]+)',
        r'https://github.com/\2',
        deps
    )
    
    # Explicitly redirect libpng and libwebp to their mirror GitHub repositories
    deps = re.sub(
        r'("third_party/externals/libpng"\s*:\s*)"[^@]+@',
        r'\1"https://github.com/pnggroup/libpng.git@',
        deps
    )
    deps = re.sub(
        r'("third_party/externals/libwebp"\s*:\s*)"[^@]+@',
        r'\1"https://github.com/webmproject/libwebp.git@',
        deps
    )
    deps = re.sub(
        r'("third_party/externals/freetype"\s*:\s*)"[^@]+@',
        r'\1"https://github.com/aseprite/freetype2.git@',
        deps
    )
    deps = re.sub(
        r'("third_party/externals/zlib"\s*:\s*)"[^@]+@',
        r'\1"https://github.com/xmake-mirror/chromium_zlib.git@',
        deps
    )
    
    deps_path.write_text(deps, encoding='utf-8')
    print("Successfully patched and cleaned DEPS file.")
else:
    print(f"Warning: DEPS file not found at {deps_path}", file=sys.stderr)
PY
}

sync_skia_deps() {
  local skia_dir="$1"
  prepare_skia_git_sync_deps "$skia_dir"

  local attempt
  for attempt in $(seq 1 "$SKIA_DEPS_RETRIES"); do
    if python3 "$skia_dir/tools/git-sync-deps"; then
      return 0
    fi
    if [[ "$attempt" == "$SKIA_DEPS_RETRIES" ]]; then
      return 1
    fi
    echo "git-sync-deps failed; retrying ($attempt/$SKIA_DEPS_RETRIES)..." >&2
    sleep 10
  done
}

build_skia() {
  ensure_tools
  ensure_depot_tools
  local src
  src="$(sync_skiasharp)"
  local skia_dir="$src/externals/skia"
  if [[ ! -x "$skia_dir/bin/gn" ]]; then
    sync_skia_deps "$skia_dir"
  fi

  local out_dir="$skia_dir/out/mac-static-$TARGET_CPU"
  mkdir -p "$out_dir" "$OUTPUT_DIR"
  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "mac"
target_cpu = "$TARGET_CPU"
min_macos_version = "10.13"
is_official_build = true
is_static_skiasharp = true
skia_enable_tools = false
skia_enable_ganesh = true
skia_use_metal = true
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = false
skia_use_freetype = false
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_system_expat = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = false
skia_use_xps = false
skia_use_partition_alloc = false
cc = "clang"
cxx = "clang++"
ar = "ar"
extra_cflags = [ "-DSKIA_C_DLL" ]
extra_cflags_cc = [ "-frtti" ]
EOF_ARGS

  (cd "$skia_dir" && "$skia_dir/bin/gn" gen "$out_dir")
  ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp
  copy_first_existing "$OUTPUT_DIR/libskia.a" "$out_dir/libskia.a" "$out_dir/obj/libskia.a"
  copy_first_existing "$OUTPUT_DIR/libSkiaSharp.a" "$out_dir/libSkiaSharp.a" "$out_dir/obj/libSkiaSharp.a"
  copy_first_existing "$OUTPUT_DIR/libHarfBuzzSharp.a" "$out_dir/libHarfBuzzSharp.a" "$out_dir/obj/libHarfBuzzSharp.a"
}

main() {
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  case "${1:-all}" in
    skia) build_skia ;;
    all) build_skia ;;
    *) echo "Usage: scripts/build-macos-static-graphics.sh [skia]" >&2; exit 1 ;;
  esac
}

main "$@"