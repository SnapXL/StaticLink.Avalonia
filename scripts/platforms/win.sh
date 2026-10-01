#!/usr/bin/env sh

set -eu

platform_ensure_tools() {
  git config --global core.longpaths true
  if [ -d "C:/Program Files/Git/bin" ]; then
      export PATH="C:/Program Files/Git/bin;C:/Program Files/Git/cmd:$PATH"
  elif [ -d "C:/Program Files/Git/cmd" ]; then
      export PATH="C:/Program Files/Git/cmd:$PATH"
  fi
}

sync_angle() {
    src="$WORK_DIR/ANGLE-$ANGLE_BRANCH"
    if [ ! -d "$src/.git" ]; then
        git -c core.longpaths=true clone --depth 1 --branch "chromium/$ANGLE_BRANCH" https://github.com/google/angle.git "$src"
    else
        git -C "$src" fetch --depth 1 origin "chromium/$ANGLE_BRANCH"
        git -C "$src" checkout -q FETCH_HEAD
    fi
    printf '%s\n' "$src"
}

apply_angle_patches() {
    src="$1"
    build_file="$src/BUILD.gn"

    python3 - "$build_file" << 'EOF'
import sys
import re

build_file = sys.argv[1]
with open(build_file, 'r', encoding='utf-8') as f:
    build_text = f.read()

if 'angle_static_library("libANGLE_static")' not in build_text:
    lib_angle_targets = '''angle_static_library("libANGLE_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE" ]
}

angle_static_library("libANGLE_with_capture_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE_with_capture" ]
}

angle_static_library("libGLESv2_static") {'''

    build_text = re.sub(r'(?m)^angle_static_library\("libGLESv2_static"\) \{', lib_angle_targets, build_text)
    build_text = re.sub(r'(?m)^angle_static_library\("libGLESv2_static"\) \{\r?\n\s+sources = libglesv2_sources', 'angle_static_library("libGLESv2_static") {\n  complete_static_lib = true\n  sources = libglesv2_sources', build_text)

    with open(build_file, 'w', encoding='utf-8', newline='') as f:
        f.write(build_text)
EOF
}

platform_build_angle() {
    export GIT_CACHE_PATH=""
    
    ensure_tools
    ensure_depot_tools
    src="$(sync_angle)"
    mkdir -p "$OUTPUT_DIR"
    apply_angle_patches "$src"
    
    current_dir="$(pwd)"
    cd "$src"
    unset DEPOT_TOOLS_METRICS
    unset DEPOT_TOOLS_REPORT_BUILD
    unset DEPOT_TOOLS_UPDATE
    python3 scripts/bootstrap.py
    gclient sync -f -D -R
    
    out_dir="$src/out/$TARGET_OS-static-$TARGET_CPU"
    mkdir -p "$out_dir"
    
    cat << EOF > "$out_dir/args.gn"
target_os = "$TARGET_OS"
target_cpu = "$TARGET_CPU"
is_debug = false
is_component_build = false
is_clang = true
use_lld = true
use_custom_libcxx = false
use_thin_lto = false
treat_warnings_as_errors = false
symbol_level = 0
angle_build_tests = false
build_angle_deqp_tests = false
angle_enable_swiftshader = false
angle_enable_vulkan = false
angle_enable_wgpu = false
EOF

    gn gen "$out_dir"
    ninja -C "$out_dir" -j "$BUILD_JOBS" libANGLE_static libGLESv2_static
    
    copy_first_existing() {
        dest_path="$1"
        shift
        for candidate in "$@"; do
            if [ -f "$candidate" ]; then
                cp "$candidate" "$dest_path"
                return 0
            fi
        done
        return 1
    }

    copy_first_existing "$OUTPUT_DIR/libANGLE_static.lib" \
        "$out_dir/libANGLE_static.lib" \
        "$out_dir/obj/libANGLE_static.lib" \
        "$out_dir/obj/libANGLE_static/libANGLE_static.lib"

    copy_first_existing "$OUTPUT_DIR/libGLESv2_static.lib" \
        "$out_dir/libGLESv2_static.lib" \
        "$out_dir/obj/libGLESv2_static.lib" \
        "$out_dir/obj/libGLESv2_static/libGLESv2_static.lib"

    for libcxx_name in "libc++.lib" "libc++abi.lib"; do
        libcxx_path="$src/third_party/llvm-build/Release+Asserts/lib/$libcxx_name"
        if [ -f "$libcxx_path" ]; then
            cp "$libcxx_path" "$OUTPUT_DIR/$libcxx_name"
            echo "Wrote $OUTPUT_DIR/$libcxx_name"
        fi
    done

    cd "$current_dir"
}