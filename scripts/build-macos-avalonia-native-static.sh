#!/usr/bin/env bash
set -euo pipefail

RID="${RID:-osx-arm64}"
AVALONIA_VERSION="${AVALONIA_VERSION:-12.1.3}"
WORK_DIR="${WORK_DIR:-$PWD/External/AvaloniaNative/.work}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/External/AvaloniaNative/$RID/native}"

case "$RID" in
  osx-arm64) ARCH="arm64" ;;
  osx-x64) ARCH="x86_64" ;;
  *) echo "Unsupported RID: $RID" >&2; exit 2 ;;
esac

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

src="$WORK_DIR/Avalonia-$AVALONIA_VERSION"
if [[ ! -d "$src/.git" ]]; then
  rm -rf "$src"
  git clone --depth 1 --branch "$AVALONIA_VERSION" https://github.com/AvaloniaUI/Avalonia.git "$src"
fi

cd "$src"

# CompileNative builds the native macOS library now
./build.sh CompileNative

candidate="$(find "$src" -type f -name 'libAvaloniaNative.a' -print -quit)"
if [[ -z "$candidate" ]]; then
  echo "Failed to find libAvaloniaNative.a in $src" >&2
  exit 1
fi

cp "$candidate" "$OUTPUT_DIR/libAvaloniaNative.a"
echo "Wrote $OUTPUT_DIR/libAvaloniaNative.a"
