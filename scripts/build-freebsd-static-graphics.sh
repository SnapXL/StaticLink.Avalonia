#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/External/NativeStatic/.work}"

TARGET_OS="freebsd"

if [ -z "${TARGET_CPU:-}" ]; then
  case "$(uname -m)" in
    amd64|x86_64) TARGET_CPU="x64" ;;
    i386|i?86) TARGET_CPU="x86" ;;
    aarch64|arm64) TARGET_CPU="arm64" ;;
    armv*|arm) TARGET_CPU="arm" ;;
    riscv64) TARGET_CPU="riscv64" ;;
    powerpc*|ppc*) TARGET_CPU="ppc64" ;;
    *) TARGET_CPU="$(uname -m)" ;;
  esac
fi
export TARGET_CPU
export TARGET_OS

RID="${RID:-$TARGET_OS-$TARGET_CPU}"
export RID

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/External/NativeStatic/$RID}"
SKIASHARP_VERSION="${SKIASHARP_VERSION:-4.154.0-preview.1}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)}"
LLVM_AR="${LLVM_AR:-$(command -v llvm-ar 2>/dev/null || echo ar)}"
SKIA_DEPS_RETRIES="${SKIA_DEPS_RETRIES:-3}"

export PYTHONUNBUFFERED=1

usage() {
  cat <<'USAGE'
Usage: scripts/build-static-graphics.sh [skia|all]

Environment:
  WORK_DIR            Source/build cache directory. Default: External/NativeStatic/.work
  OUTPUT_DIR          Final static library directory. Default: External/NativeStatic/$RID
  SKIASHARP_VERSION   SkiaSharp release branch version. Default: 4.154.0-preview.1
  TARGET_CPU          GN target_cpu. Default: auto-detected (x64, arm64, etc.)
  TARGET_OS           GN target_os. Default: auto-detected
  RID                 Output RID. Default: $TARGET_OS-$TARGET_CPU
  BUILD_JOBS          Ninja parallelism. Default: sysctl hw.ncpu
  LLVM_AR             llvm-ar command used to expand thin archives. Default: auto-detected

Requires system packages:
  devel/gn, devel/ninja, devel/pkgconf, lang/python3, devel/git, devel/llvm
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
  require_cmd ar
  require_cmd "$LLVM_AR"
  require_cmd ninja
  require_cmd pkg-config
  require_cmd gn
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
  sync_deps="$skia_dir/tools/git-sync-deps"

python3 - "$sync_deps" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

if "import shutil" not in text:
    text = text.replace("import threading", "import threading\nimport shutil")

old_os_lookup = """    for os_name in command_line_os_requests:
      # Add OS-specific dependencies"""

new_os_lookup = """    for os_name in command_line_os_requests:
      if os_name == 'freebsd':
        os_name = 'linux'
      # Add OS-specific dependencies"""

if old_os_lookup in text:
    text = text.replace(old_os_lookup, new_os_lookup, 1)

old_main_fetch = """  git_sync_deps(deps_file_path, argv, shallow, verbose)
  subprocess.check_call(
      [sys.executable,
       os.path.join(os.path.dirname(deps_file_path), 'bin', 'fetch-gn')])
  if not skip_emsdk:
    subprocess.check_call(
        [sys.executable,
         os.path.join(os.path.dirname(deps_file_path), 'bin', 'activate-emsdk')])
  return 0"""

new_main_fetch = """  git_sync_deps(deps_file_path, argv, shallow, verbose)

  if sys.platform.startswith('freebsd'):
    if shutil.which('gn') is None:
      sys.stderr.write(
          'warning: gn not found in PATH; install it with '
          '"pkg install gn"\\n')
  else:
    subprocess.check_call(
        [sys.executable,
         os.path.join(os.path.dirname(deps_file_path), 'bin', 'fetch-gn')])

  if not skip_emsdk and not sys.platform.startswith('freebsd'):
    subprocess.check_call(
        [sys.executable,
         os.path.join(os.path.dirname(deps_file_path), 'bin', 'activate-emsdk')])
  return 0"""

if old_main_fetch in text:
    text = text.replace(old_main_fetch, new_main_fetch, 1)

path.write_text(text)
print("Successfully patched git-sync-deps via Python!")
PY

  python3 - "$sync_deps" <<'PY'
import re
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
deps_path = path.with_name("DEPS")
if deps_path.exists():
    deps = deps_path.read_text()
    deps = re.sub(r'^\s*"third_party/externals/dng_sdk"\s*:\s*"[^"]+",\s*\n', '', deps, flags=re.MULTILINE)
    deps_path.write_text(deps)
old = "  multithread(git_checkout_to_directory, list_of_arg_lists)"
new = "  for args in list_of_arg_lists:\n    git_checkout_to_directory(*args)"
if old in text:
    path.write_text(text.replace(old, new))
PY
}

sync_skia_deps() {
  skia_dir="$1/externals/skia"
  prepare_skia_git_sync_deps "$skia_dir"
  attempt=1
  while [ "$attempt" -le "$SKIA_DEPS_RETRIES" ]; do
    if python3 "$skia_dir/tools/git-sync-deps" freebsd; then
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
  src="$(sync_skiasharp)"
  sync_skia_deps "$src"
  skia_dir="$src/externals/skia"
  out_dir="$skia_dir/out/$RID"
  mkdir -p "$out_dir" "$OUTPUT_DIR"
  
  # Create a private include directory for physical header isolation
  ISOLATED_INCLUDE_DIR="$WORK_DIR/isolated_include"
  rm -rf "$ISOLATED_INCLUDE_DIR"
  mkdir -p "$ISOLATED_INCLUDE_DIR"
  
  cp -R /usr/local/include/fontconfig "$ISOLATED_INCLUDE_DIR/"
  cp -R /usr/local/include/freetype2/* "$ISOLATED_INCLUDE_DIR/"
  
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
skia_use_fontconfig = true
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
cc = "clang"
cxx = "clang++"
ar = "llvm-ar"
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DXML_DEV_URANDOM",
  "-I$WORK_DIR/isolated_include"
]
extra_ldflags = []
extra_cflags_cc = [ "-frtti" ]
EOF_ARGS
python3 - "$skia_dir" <<'PY'
import pathlib
import sys

skia_dir = pathlib.Path(sys.argv[1])
getrandom_c = skia_dir / "third_party/externals/expat/expat/lib/random_getrandom.c"

if getrandom_c.exists():
    safe_code = """
#include <stddef.h>
#include <stdlib.h>

int getRandomBytes(void *target, size_t count) {
    return 0; // Returning 0 force Expat to fall back to its standard urandom implementation
}
"""
    getrandom_c.write_text(safe_code)
    print("Successfully replaced expat's random_getrandom.c with a stub.")
PY
  (cd "$skia_dir" && gn gen "$out_dir")
  ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp

  copy_first_existing "$OUTPUT_DIR/libskia.a" \
    "$out_dir/libskia.a" \
    "$out_dir/obj/libskia.a"
  copy_first_existing "$OUTPUT_DIR/libSkiaSharp.a" \
    "$out_dir/libSkiaSharp.a" \
    "$out_dir/obj/libSkiaSharp.a"
  copy_first_existing "$OUTPUT_DIR/libHarfBuzzSharp.a" \
    "$out_dir/libHarfBuzzSharp.a" \
    "$out_dir/obj/libHarfBuzzSharp.a"
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
    all)
      build_skia
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"