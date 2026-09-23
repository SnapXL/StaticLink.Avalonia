#!/usr/bin/env sh
set -eu

PROJECT_DIR=""
NUGET_SOURCE=""
STATIC_LINK_VERSION=""
AVALONIA_VERSION="12.1.3"
STATIC_LINK_NATIVE_VERSION=""

usage() {
  cat <<EOF
Usage: $0 --project-dir DIR --nuget-source PATH [OPTIONS]

Options:
  --project-dir DIR                    (required) Target project directory
  --nuget-source PATH                  (required) Path to local NuGet source
  --static-link-version VERSION        StaticLink.Avalonia package version
  --avalonia-version VERSION           Avalonia version (default: 12.1.3)
  --static-link-native-version VERSION StaticLink.Avalonia.Native package version
  -h, --help                           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
      PROJECT_DIR="$2"
      shift 2
      ;;
    --nuget-source)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
      NUGET_SOURCE="$2"
      shift 2
      ;;
    --static-link-version)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
      STATIC_LINK_VERSION="$2"
      shift 2
      ;;
    --avalonia-version)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
      AVALONIA_VERSION="$2"
      shift 2
      ;;
    --static-link-native-version)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
      STATIC_LINK_NATIVE_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$PROJECT_DIR" ] || [ -z "$NUGET_SOURCE" ]; then
  usage >&2
  exit 1
fi

# Resolve the script's own directory, following symlinks, then walk up to the repo root.
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET" ;;
    *) SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/Smoke/AvaloniaStaticLinkSmoke"

if [ ! -f "$TEMPLATE_DIR/AvaloniaStaticLinkSmoke.csproj" ]; then
  echo "Smoke project template was not found: $TEMPLATE_DIR" >&2
  exit 1
fi

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

ESC_NUGET_SOURCE="$(xml_escape "$NUGET_SOURCE")"
ESC_AVALONIA_VERSION="$(xml_escape "$AVALONIA_VERSION")"
ESC_STATIC_LINK_VERSION="$(xml_escape "$STATIC_LINK_VERSION")"
ESC_STATIC_LINK_NATIVE_VERSION="$(xml_escape "$STATIC_LINK_NATIVE_VERSION")"

mkdir -p "$PROJECT_DIR"
cp -R "$TEMPLATE_DIR"/. "$PROJECT_DIR"/

cat >"$PROJECT_DIR/SmokeVersions.props" <<EOF
<Project>
  <PropertyGroup>
    <AvaloniaVersion>$ESC_AVALONIA_VERSION</AvaloniaVersion>
    <StaticLinkVersion>$ESC_STATIC_LINK_VERSION</StaticLinkVersion>
    <StaticLinkNativeVersion>$ESC_STATIC_LINK_NATIVE_VERSION</StaticLinkNativeVersion>
  </PropertyGroup>
</Project>
EOF

cat >"$PROJECT_DIR/NuGet.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local-staticlink" value="$ESC_NUGET_SOURCE" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF