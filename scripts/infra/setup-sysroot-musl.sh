#!/usr/bin/env sh
set -eu

RID="${RID:-linux-musl-x64}"
TARGET_CPU="${TARGET_CPU:-x64}"
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"
ALPINE_VERSION="${ALPINE_VERSION:-3.19.9}"
SYSROOT="${SYSROOT:-/opt/alpine-sysroot-$RID}"

echo "Setting up Alpine Linux sysroot for RID: $RID (Arch: $ALPINE_ARCH) at $SYSROOT..."

sudo mkdir -p "$SYSROOT"

TARBALL="alpine-minirootfs-$ALPINE_VERSION-$ALPINE_ARCH.tar.gz"
URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/$ALPINE_ARCH/$TARBALL"

curl -fSL "$URL" -o "/tmp/$TARBALL"
sudo tar -xzf "/tmp/$TARBALL" -C "$SYSROOT"
rm "/tmp/$TARBALL"

sudo tee "$SYSROOT/etc/apk/repositories" > /dev/null << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

sudo cp /etc/resolv.conf "$SYSROOT/etc/resolv.conf"

sudo chroot "$SYSROOT" apk update
sudo chroot "$SYSROOT" apk add --no-cache \
  ca-certificates \
  musl-dev \
  fontconfig-dev \
  glib-dev \
  linux-headers \
  libstdc++-dev \
  freetype-dev

ARCH_NAME="$(sudo cat "$SYSROOT/etc/apk/arch")"
TRIPLE="${ARCH_NAME}-alpine-linux-musl"
CXX_INCLUDE_DIR="$SYSROOT/usr/include"

# Dynamically locate the C++ include directory and target-specific config header
CONFIG_H_PATH="$(sudo find "$SYSROOT/usr/include" -name "c++config.h" | head -n 1)"
if [ -z "$CONFIG_H_PATH" ]; then
  echo "Error: c++config.h not found in sysroot usr/include" >&2
  exit 1
fi
MACHINE_INCLUDE_DIR="$(dirname "$(dirname "$CONFIG_H_PATH")")"
CXX_BASE_INCLUDE_DIR="$(dirname "$CONFIG_H_PATH")"

sudo mkdir -p /usr/local/bin

EXTRA_FLAGS=""
if [ "$TARGET_CPU" = "arm" ]; then
  EXTRA_FLAGS="-mfloat-abi=hard"
fi

sudo tee /usr/local/bin/clang > /dev/null << EOF
#!/bin/sh
exec /usr/bin/clang --target=$TRIPLE -fuse-ld=lld $EXTRA_FLAGS -Wno-unused-command-line-argument --sysroot="$SYSROOT" --gcc-toolchain=/nonexistent -isystem$CXX_BASE_INCLUDE_DIR -isystem$MACHINE_INCLUDE_DIR -isystem$CXX_INCLUDE_DIR "\$@"
EOF
sudo chmod +x /usr/local/bin/clang

sudo tee /usr/local/bin/clang++ > /dev/null << EOF
#!/bin/sh
exec /usr/bin/clang++ --target=$TRIPLE -fuse-ld=lld $EXTRA_FLAGS -Wno-unused-command-line-argument --sysroot="$SYSROOT" --gcc-toolchain=/nonexistent -isystem$CXX_BASE_INCLUDE_DIR -isystem$MACHINE_INCLUDE_DIR -isystem$CXX_INCLUDE_DIR "\$@"
EOF
sudo chmod +x /usr/local/bin/clang++

echo "Successfully configured Alpine sysroot and compiler wrappers for $TRIPLE."