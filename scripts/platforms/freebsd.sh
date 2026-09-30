#!/usr/bin/env sh

set -eu

platform_apply_skia_patches() {
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

  if shutil.which('gn') is None:
    sys.stderr.write(
        'warning: gn not found in PATH; install it with '
        '"pkg install gn"\\n')

  return 0"""

if old_main_fetch in text:
    text = text.replace(old_main_fetch, new_main_fetch, 1)

path.write_text(text)
print("Successfully patched git-sync-deps via Python!")
PY

    python3 - "$skia_dir" <<'PY'
import pathlib
import re
import sys

skia_dir = pathlib.Path(sys.argv[1])
build_gn = skia_dir / "third_party/zlib/BUILD.gn"

if not build_gn.exists():
    print(f"Warning: {build_gn} not found; skipping zlib FreeBSD patch")
    sys.exit(0)

text = build_gn.read_text()

pattern = re.compile(
    r'use_arm_neon_optimizations\s*=\s*'
    r'\(current_cpu\s*==\s*"arm"\s*\|\|\s*current_cpu\s*==\s*"arm64"\)\s*&&\s*'
    r'!\(is_win\s*&&\s*!is_clang\)',
    re.MULTILINE,
)

replacement = (
    'use_arm_neon_optimizations = (current_cpu == "arm" || current_cpu == "arm64") &&\n'
    '                         !(is_win && !is_clang) &&\n'
    '                         target_os != "freebsd"'
)

new_text, count = pattern.subn(replacement, text, count=1)

if count == 0:
    if 'target_os != "freebsd"' in text:
        print("zlib BUILD.gn already patched for FreeBSD")
    else:
        print("Warning: use_arm_neon_optimizations pattern not found; "
              "zlib BUILD.gn layout may have changed")
    sys.exit(0)

build_gn.write_text(new_text)
print("Patched zlib BUILD.gn to disable ARM NEON optimizations on FreeBSD")
PY

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
}