#!/usr/bin/env sh

set -eu

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

build_macos_avalonia_native() {
    rid="${RID:-osx-arm64}"
    avalonia_version="${AVALONIA_VERSION:-12.1.3}"
    work_dir="${WORK_DIR:-$REPO_ROOT/External/AvaloniaNative/.work}"
    output_dir="${OUTPUT_DIR:-$REPO_ROOT/External/AvaloniaNative/$rid/native}"
    build_jobs="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

    case "$rid" in
        osx-arm64) arch="arm64" ;;
        osx-x64) arch="x86_64" ;;
        *) echo "Unsupported RID: $rid" >&2; return 2 ;;
    esac

    mkdir -p "$work_dir" "$output_dir"

    src="$work_dir/Avalonia-$avalonia_version"
    if [ ! -d "$src/.git" ]; then
        rm -rf "$src"
        git clone --depth 1 --branch "$avalonia_version" https://github.com/AvaloniaUI/Avalonia.git "$src"
    fi

    if git -C "$src" config -f .gitmodules --get-regexp path | grep -q 'external/Numerge' && [ ! -d "$src/external/Numerge/.git" ]; then
        git -C "$src" submodule update --init --depth 1 external/Numerge
    fi

    if [ ! -f "$src/native/Avalonia.Native/inc/avalonia-native.h" ]; then
        header_project="$src/native/Avalonia.Native/Avalonia.Native.macOS.proj"
        if [ -f "$header_project" ]; then
            dotnet build "$header_project" -t:GenerateMicroComItems
        else
            bash "$src/native/Avalonia.Native/generate-headers.sh"
        fi
    fi

    project="$src/native/Avalonia.Native/src/OSX/Avalonia.Native.OSX.xcodeproj"
    include_dir="$src/native/Avalonia.Native/inc"
    build_dir="$work_dir/avalonia-native-$rid"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    xcodebuild \
        -project "$project" \
        -target Avalonia.Native.OSX \
        -configuration Release \
        -sdk macosx \
        -arch "$arch" \
        CONFIGURATION_BUILD_DIR="$build_dir" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO \
        MACH_O_TYPE=staticlib \
        EXECUTABLE_PREFIX=lib \
        EXECUTABLE_EXTENSION=a \
        PRODUCT_NAME=AvaloniaNative \
        HEADER_SEARCH_PATHS="$include_dir" \
        CLANG_ENABLE_MODULES=YES \
        GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
        -jobs "$build_jobs"

    candidate="$(find "$build_dir" -maxdepth 2 -type f -name 'libAvaloniaNative.a' -print -quit)"
    if [ -z "$candidate" ]; then
        echo "Failed to find libAvaloniaNative.a in $build_dir" >&2
        find "$build_dir" -maxdepth 3 -type f -print >&2
        return 1
    fi

    cp "$candidate" "$output_dir/libAvaloniaNative.a"
    echo "Wrote $output_dir/libAvaloniaNative.a"

    echo "Compiling macos_font_preinit.m..."
    preinit_src="$work_dir/macos_font_preinit.m"
    cat > "$preinit_src" <<'OBJC'
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

__attribute__((constructor(101)))
static void StaticLinkAvaloniaPreinitializeAppKitFonts(void)
{
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        [NSFont systemFontOfSize:13.0];
        ((id (*)(id, SEL, CGFloat, CGFloat))objc_msgSend)([NSFont class], sel_registerName("systemFontOfSize:width:"), 13.0, 0.0);
    }
}
OBJC

    clang -arch "$arch" \
        -mmacosx-version-min=10.13 \
        -fobjc-arc \
        -c "$preinit_src" \
        -o "$output_dir/macos_font_preinit.o"

    rm -f "$preinit_src"
    echo "Wrote $output_dir/macos_font_preinit.o"
}

platform_get_gn_args() {
  echo "min_macos_version = \"10.13\""
  echo "skia_use_metal = true"
}

case "$(basename "$0")" in
    mac.sh|*sh)
        if [ "$(basename "$0")" = "mac.sh" ]; then
            build_macos_avalonia_native "$@"
        fi
        ;;
esac