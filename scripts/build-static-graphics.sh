#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/External/NativeStatic/.work}"
if [ -z "${TARGET_CPU:-}" ]; then
  case "$(uname -m)" in
    x86_64|amd64) TARGET_CPU="x64" ;;
    i?86) TARGET_CPU="x86" ;;
    aarch64|arm64) TARGET_CPU="arm64" ;;
    armv*|arm) TARGET_CPU="arm" ;;
    mips64el) TARGET_CPU="mips64el" ;;
    mips64) TARGET_CPU="mips64" ;;
    mipsel) TARGET_CPU="mipsel" ;;
    mips) TARGET_CPU="mips" ;;
    s390x) TARGET_CPU="s390x" ;;
    ppc64le|ppc64el) TARGET_CPU="ppc64le" ;;
    ppc64) TARGET_CPU="ppc64" ;;
    riscv64) TARGET_CPU="riscv64" ;;
    loongarch64) TARGET_CPU="loong64" ;;
    *) TARGET_CPU="$(uname -m)" ;;
  esac
fi
export TARGET_CPU
if [ -z "${TARGET_OS:-}" ]; then
  case "$(uname -s)" in
    Linux*)   TARGET_OS="linux" ;;
    FreeBSD*) TARGET_OS="freebsd" ;;
    Darwin*)  TARGET_OS="mac" ;;
    CYGWIN*|MINGW*|MSYS*) TARGET_OS="win" ;;
    *)        TARGET_OS="linux" ;;
  esac
fi
export TARGET_OS
if [ -z "${RID:-}" ]; then
  if (command -v cc >/dev/null 2>&1 && cc -dumpmachine 2>/dev/null | grep -q musl) || [ -f /etc/alpine-release ]; then
    RID="linux-musl-$TARGET_CPU"
  else
    RID="$TARGET_OS-$TARGET_CPU"
  fi
fi
export RID
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/External/NativeStatic/$RID}"
SKIASHARP_VERSION="${SKIASHARP_VERSION:-4.154.0-preview.1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}"
SKIA_DEPS_RETRIES="${SKIA_DEPS_RETRIES:-3}"
CC="${CC:-clang}"
CXX="${CXX:-clang++}"
AR="${AR:-llvm-ar}"
GN="${GN:-gn}"

export DEPOT_TOOLS_METRICS=0
export DEPOT_TOOLS_REPORT_BUILD=0
export DEPOT_TOOLS_UPDATE=0
export PYTHONUNBUFFERED=1
HARFBUZZ_COMMIT="${HARFBUZZ_COMMIT:-863d3f7787c6df18d20e4535c5906bf3eb803bd5}"
ZLIB_COMMIT="${ZLIB_COMMIT:-456ae730017b9b4bd3371927abc82627fd51feef}"

# Define default POSIX-compliant stubs for platform hooks
platform_ensure_tools() { :; }
platform_apply_skia_patches() { :; }
platform_get_gn_args() { :; }
platform_build_angle() {
  echo "Error: This script was only made to build ANGLE on Windows. You don't need ANGLE anywhere else in Avalonia apps." >&2
  exit 1
}

PLATFORM_SCRIPT="$ROOT_DIR/scripts/platforms/$TARGET_OS.sh"
if [ -f "$PLATFORM_SCRIPT" ]; then
  # shellcheck disable=SC1090
  . "$PLATFORM_SCRIPT"
fi

usage() {
  cat <<'USAGE'
Usage: scripts/build-static-graphics.sh [skia]

Environment:
  WORK_DIR            Source/build cache directory. Default: External/NativeStatic/.work
  OUTPUT_DIR          Final static library directory. Default: External/NativeStatic/$RID
  SKIASHARP_VERSION   SkiaSharp release branch version. Default: 4.154.0-preview.1
  TARGET_CPU          GN target_cpu. Default: auto-detected
  TARGET_OS           GN target_os. Default: auto-detected
  RID                 Output RID. Default: $TARGET_OS-$TARGET_CPU
  BUILD_JOBS          Ninja parallelism. Default: auto-detected
USAGE
}

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
  require_cmd "$AR"
  require_cmd ninja
  # GN is not typically pre-packaged via native package managers on Windows and macOS,
  # but is provided automatically by depot_tools.
  if [ "$TARGET_OS" != "win" ] && [ "$TARGET_OS" != "mac" ]; then
    require_cmd gn
  fi
  platform_ensure_tools
}

ensure_depot_tools() {
  depot_dir="$WORK_DIR/depot_tools"
  
  if [ ! -d "$depot_dir/.git" ]; then
    git clone --depth 1 --branch main https://github.com/ANaCiSkE/depot_tools_mirror "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  
  patch_depot_tools_python_deps "$depot_dir"
  if [ "$TARGET_OS" = "win" ] || [ "$TARGET_OS" = "mac" ]; then
    unset DEPOT_TOOLS_UPDATE
    export PATH="$depot_dir:$PATH"
  else
    export PATH="$PATH:$depot_dir"
  fi

  if [ ! -f "$depot_dir/python3_bin_reldir.txt" ]; then
    initialize_depot_tools_system_python "$depot_dir"
  fi
}

initialize_depot_tools_system_python() {
  depot_dir="$1"
  python_bin_dir="$(dirname "$(command -v python3)")"
  
  if command -v cygpath >/dev/null 2>&1; then
    python_bin_dir="$(cygpath -u "$python_bin_dir")"
  fi

  if [ -d "$depot_dir" ]; then
    python3 - "$depot_dir" "$python_bin_dir" <<'PY'
import os
import pathlib
import sys

depot_dir = pathlib.Path(sys.argv[1]).resolve()
python_bin_dir = pathlib.Path(sys.argv[2]).resolve()
marker = depot_dir / "python3_bin_reldir.txt"
try:
    rel_path = os.path.relpath(python_bin_dir, depot_dir)
    marker.write_text(rel_path + "\n")
except ValueError:
    marker.write_text(str(python_bin_dir) + "\n")
PY
  fi
}

patch_depot_tools_python_deps() {
  depot_dir="$1"
  gsutil_dir="$depot_dir/external_bin/gsutil/gsutil_4.68/gsutil"
  gsutil_third_party="$gsutil_dir/third_party"
  if [ -d "$gsutil_dir" ] && [ ! -f "$gsutil_dir/six.py" ]; then
    python3 - "$gsutil_dir/six.py" <<'PY'
import pathlib
import shutil
import six
import sys

src = pathlib.Path(six.__file__)
dest = pathlib.Path(sys.argv[1])
shutil.copyfile(src, dest)
PY
  fi
  if [ -d "$gsutil_third_party" ] && [ ! -f "$gsutil_third_party/six.py" ]; then
    python3 - "$gsutil_third_party/six.py" <<'PY'
import pathlib
import shutil
import six
import sys

src = pathlib.Path(six.__file__)
dest = pathlib.Path(sys.argv[1])
shutil.copyfile(src, dest)
PY
  fi
}

sync_skiasharp() {
  src="$WORK_DIR/SkiaSharp-$SKIASHARP_VERSION"
  if [ ! -d "$src/.git" ]; then
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
python3 - "$skia_dir" "$HARFBUZZ_COMMIT" "$ZLIB_COMMIT" "$TARGET_OS" <<'PY'
import re
import pathlib
import sys

skia_dir = pathlib.Path(sys.argv[1])
harfbuzz_target = sys.argv[2]
zlib_target = sys.argv[3]
target_os = sys.argv[4]
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
    ]
    if target_os != "win":
            unused_deps.append("d3d12allocator")
    for dep in unused_deps:
        pattern = rf'^\s*["\']third_party/externals/{dep}["\']\s*:\s*[^,\n]+,\s*\n'
        deps = re.sub(pattern, '', deps, flags=re.MULTILINE)
    
    # Dynamically update HarfBuzz hash using a callback function to avoid group reference errors
    def replace_harfbuzz(match):
        return match.group(1) + harfbuzz_target + match.group(2)
    def replace_zlib(match):
        return match.group(1) + zlib_target + match.group(2)
    
    deps = re.sub(
        r'(["\']third_party/externals/harfbuzz["\']\s*:\s*["\'][^@]+@)[^"\']+(["\'])',
        replace_harfbuzz,
        deps
    )
    deps = re.sub(
        r'(["\']third_party/externals/zlib["\']\s*:\s*["\'][^@]+@)[^"\']+(["\'])',
        replace_zlib,
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
  skia_dir="$1/externals/skia"
  
  if [ "$TARGET_OS" = "win" ] && command -v cygpath >/dev/null 2>&1; then
    skia_dir_normalized="$(cygpath -w "$skia_dir")"
  else
    skia_dir_normalized="$skia_dir"
  fi
  
  prepare_skia_git_sync_deps "$skia_dir_normalized"
  platform_apply_skia_patches "$skia_dir_normalized"
  attempt=1
  while [ "$attempt" -le "$SKIA_DEPS_RETRIES" ]; do
    if python3 "$skia_dir_normalized/tools/git-sync-deps"; then
      return 0
    fi
    if [ "$attempt" -eq "$SKIA_DEPS_RETRIES" ]; then
      return 1
    fi
    echo "git-sync-deps failed; retrying ($attempt/$SKIA_DEPS_RETRIES)..." >&2
    sleep 10
    attempt=$((attempt + 1))
  done
}

build_skia() {
  ensure_tools
  ensure_depot_tools
  src="$(sync_skiasharp)"
  sync_skia_deps "$src"
  skia_dir="$src/externals/skia"
  out_dir="$skia_dir/out/$RID"
  mkdir -p "$out_dir" "$OUTPUT_DIR"

  EXTRA_GN_ARGS="$(platform_get_gn_args)"
  if { [ "$TARGET_OS" = "win" ] || [ "$TARGET_OS" = "mac" ]; } && [ "$GN" = "gn" ]; then
    if [ ! -f "$skia_dir/bin/gn" ]; then
      python3 "$skia_dir/bin/fetch-gn"
    fi
    GN="$skia_dir/bin/gn"
  fi
  if [ "$TARGET_OS" = "win" ]; then
    extra_cflags_cc='[]'
  else
    extra_cflags_cc='[ "-frtti", "-Wno-psabi" ]'
  fi
  if [ "$TARGET_OS" = "linux" ] || [ "$TARGET_OS" = "freebsd" ]; then
    skia_use_fontconfig="true"
  else
    skia_use_fontconfig="false"
  fi
  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "$TARGET_OS"
target_cpu = "$TARGET_CPU"
is_official_build = true
is_static_skiasharp = true
skia_enable_tools = false
skia_enable_ganesh = true
skia_enable_graphite = false
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = $skia_use_fontconfig
skia_use_freetype = true
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_system_expat = false
skia_use_system_freetype2 = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = false
skia_use_xps = false
skia_use_partition_alloc = false
cc = "$CC"
cxx = "$CXX"
ar = "$AR"
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DHAVE_SYSCALL_GETRANDOM",
  "-DXML_DEV_URANDOM",
]
extra_cflags_cc = $extra_cflags_cc
extra_ldflags = []
$EXTRA_GN_ARGS
EOF_ARGS

  (cd "$skia_dir" && "$GN" gen "$out_dir")
  ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp
  
  if [ "$TARGET_OS" = "win" ]; then
    lib_ext="lib"
  else
    lib_ext="a"
  fi
  
  copy_first_existing "$OUTPUT_DIR/libskia.$lib_ext" \
    "$out_dir/libskia.$lib_ext" \
    "$out_dir/obj/libskia.$lib_ext" \
    "$out_dir/skia.$lib_ext" \
    "$out_dir/obj/skia.$lib_ext"

  copy_first_existing "$OUTPUT_DIR/libSkiaSharp.$lib_ext" \
    "$out_dir/libSkiaSharp.$lib_ext" \
    "$out_dir/obj/libSkiaSharp.$lib_ext" \
    "$out_dir/SkiaSharp.$lib_ext" \
    "$out_dir/obj/SkiaSharp.$lib_ext"

  copy_first_existing "$OUTPUT_DIR/libHarfBuzzSharp.$lib_ext" \
    "$out_dir/libHarfBuzzSharp.$lib_ext" \
    "$out_dir/obj/libHarfBuzzSharp.$lib_ext" \
    "$out_dir/HarfBuzzSharp.$lib_ext" \
    "$out_dir/obj/HarfBuzzSharp.$lib_ext"
}

build_angle() {
  if [ "$TARGET_OS" != "win" ]; then
    echo "Error: This script is only configured to build ANGLE on Windows. ANGLE is only used on Windows in Avalonia apps." >&2
    exit 1
  fi

  platform_build_angle
}

copy_first_existing() {
  dest="$1"
  shift
  for src in "$@"; do
    if [ -f "$src" ]; then
      cp "$src" "$dest"
      echo "Wrote $dest"
      return 0
    fi
  done
  echo "None of the expected files exist for $dest:" >&2
  printf '  %s\n' "$@" >&2
  return 1
}

main() {
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  case "${1:-all}" in
    skia) build_skia ;;
    angle) build_angle ;;
    all)
      build_skia
      ;;
    -h|--help|help)
      usage ;;
    *)
      usage >&2
      exit 1 ;;
  esac
}

main "$@"