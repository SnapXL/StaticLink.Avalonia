#!/usr/bin/env sh
set -eu

RID="${RID:-freebsd-x64}"
FREEBSD_DIR="${FREEBSD_DIR:-amd64/amd64}"
FREEBSD_TRIPLE="${FREEBSD_TRIPLE:-x86_64-unknown-freebsd14}"
RELEASE="${RELEASE:-14.5}"
SYSROOT="${SYSROOT:-/opt/freebsd-sysroot-$RID}"

echo "Setting up FreeBSD $RELEASE sysroot for RID: $RID (Triple: $FREEBSD_TRIPLE) at $SYSROOT..."

sudo mkdir -p "$SYSROOT"

# Download FreeBSD base system with fallback mirror support
BASE_URL="https://download.freebsd.org/releases/$FREEBSD_DIR/${RELEASE}-RELEASE/base.txz"
ARCHIVE_URL="https://archive.freebsd.org/old-releases/$FREEBSD_DIR/${RELEASE}-RELEASE/base.txz"

if ! curl -fSL "$BASE_URL" -o /tmp/base.txz; then
  echo "Primary download mirror failed; trying FreeBSD archive..." >&2
  curl -fSL "$ARCHIVE_URL" -o /tmp/base.txz
fi

sudo tar -xJf /tmp/base.txz -C "$SYSROOT" \
  ./usr/include \
  ./usr/lib \
  ./lib
rm /tmp/base.txz

sudo mkdir -p /usr/local/bin

sudo tee /usr/local/bin/clang > /dev/null << EOF
#!/bin/sh
exec /usr/bin/clang --target=$FREEBSD_TRIPLE --sysroot="$SYSROOT" -fuse-ld=lld -Wno-unused-command-line-argument "\$@"
EOF
sudo chmod +x /usr/local/bin/clang

sudo tee /usr/local/bin/clang++ > /dev/null << EOF
#!/bin/sh
exec /usr/bin/clang++ --target=$FREEBSD_TRIPLE --sysroot="$SYSROOT" -fuse-ld=lld -Wno-unused-command-line-argument "\$@"
EOF
sudo chmod +x /usr/local/bin/clang++

sudo ln -s /usr/include/fontconfig "$SYSROOT/usr/include/fontconfig"

echo "Successfully configured FreeBSD sysroot and compiler wrappers for $FREEBSD_TRIPLE."