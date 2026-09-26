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
TARGET_OS="linux"
if [ -z "${RID:-}" ]; then
  if [ -f /etc/alpine-release ]; then
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

export DEPOT_TOOLS_METRICS=0
export DEPOT_TOOLS_REPORT_BUILD=0
export DEPOT_TOOLS_UPDATE=0
export PYTHONUNBUFFERED=1

usage() {
  cat <<'USAGE'
Usage: scripts/build-static-graphics.sh [skia]

Environment:
  WORK_DIR            Source/build cache directory. Default: External/NativeStatic/.work
  OUTPUT_DIR          Final static library directory. Default: External/NativeStatic/$RID
  SKIASHARP_VERSION   SkiaSharp release branch version. Default: 4.154.0-preview.1
  TARGET_CPU          GN target_cpu. Default: x64. Supported: x64, arm64
  TARGET_OS           GN target_os. Default: auto-detected
  RID                 Output RID. Default: $TARGET_OS-$TARGET_CPU
  BUILD_JOBS          Ninja parallelism. Default: nproc/sysctl
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

is_musl_rid() {
  case "$RID" in
    *-musl-*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_tools() {
  require_cmd git
  require_cmd python3
  require_cmd clang
  require_cmd clang++
  require_cmd ar
  require_cmd ninja
  require_cmd pkg-config
}

ensure_depot_tools() {
  depot_dir="$WORK_DIR/depot_tools"
  python_bin_dir="$(dirname "$(command -v python3)")"
  if [ ! -d "$depot_dir/.git" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  initialize_depot_tools_system_python "$depot_dir"
  patch_depot_tools_python_deps "$depot_dir"
  export PATH="$python_bin_dir:$depot_dir:$PATH"
}

initialize_depot_tools_system_python() {
  depot_dir="$1"
  python_bin_dir="$(dirname "$(command -v python3)")"
  if [ -d "$depot_dir" ]; then
    python3 - "$depot_dir" "$python_bin_dir" <<'PY'
import os
import pathlib
import sys

depot_dir = pathlib.Path(sys.argv[1]).resolve()
python_bin_dir = pathlib.Path(sys.argv[2]).resolve()
marker = depot_dir / "python3_bin_reldir.txt"
marker.write_text(os.path.relpath(python_bin_dir, depot_dir) + "\n")
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
  sync_deps="$1/tools/git-sync-deps"
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
  if [ ! -x "$skia_dir/bin/gn" ]; then
    prepare_skia_git_sync_deps "$skia_dir"
    attempt=1
    while [ "$attempt" -le "$SKIA_DEPS_RETRIES" ]; do
      if python3 "$skia_dir/tools/git-sync-deps"; then
        return 0
      fi
      if [ "$attempt" -eq "$SKIA_DEPS_RETRIES" ]; then
        return 1
      fi
      echo "git-sync-deps failed; retrying ($attempt/$SKIA_DEPS_RETRIES)..." >&2
      sleep 10
      attempt=$((attempt + 1))
    done
  fi
}

build_skia() {
  ensure_tools
  ensure_depot_tools
  src="$(sync_skiasharp)"
  sync_skia_deps "$src"
  skia_dir="$src/externals/skia"
  out_dir="$skia_dir/out/$RID"
  mkdir -p "$out_dir" "$OUTPUT_DIR"

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
ar = "ar"
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DHAVE_SYSCALL_GETRANDOM",
  "-DXML_DEV_URANDOM",
  "-stdlib=libc++"
]
extra_cflags_cc = [ "-frtti" ]
extra_ldflags = [
  "-stdlib=libc++", 
  "-lc++abi"
]
EOF_ARGS

  (cd "$skia_dir" && "$skia_dir/bin/gn" gen "$out_dir")
  # Use system ninja explicitly to prevent depot_tools wrapper hangs
  /usr/bin/ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp

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