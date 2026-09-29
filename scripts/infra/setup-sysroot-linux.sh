#!/usr/bin/env sh
set -eu

UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
SYSROOT="${SYSROOT:-/opt/sysroot-ubuntu1804}"

echo "Setting up Ubuntu 18.04 Bionic sysroot for arch: $UBUNTU_ARCH at $SYSROOT..."

if [ "$UBUNTU_ARCH" = "amd64" ]; then
  MIRROR="http://archive.ubuntu.com/ubuntu"
else
  MIRROR="http://ports.ubuntu.com/ubuntu-ports"
fi

sudo debootstrap \
  --arch="$UBUNTU_ARCH" \
  --components=main,universe \
  --include=libc6-dev,libfontconfig1-dev,libfreetype6-dev,zlib1g-dev,gnupg \
  bionic \
  "$SYSROOT" \
  "$MIRROR"

sudo chroot "$SYSROOT" apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 2C277A0A352154E5 1E9377A2BA9EF27F
echo "deb http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu bionic main" | sudo tee -a "$SYSROOT/etc/apt/sources.list" > /dev/null

sudo chroot "$SYSROOT" apt-get update
sudo chroot "$SYSROOT" apt-get install -y libstdc++-10-dev

TRIPLE="$(sudo chroot "$SYSROOT" dpkg-architecture -qDEB_HOST_GNU_TYPE)"
CXX_INCLUDE_DIR="$SYSROOT/usr/include/$TRIPLE/c++/10"

sudo mkdir -p /usr/local/bin

sudo tee /usr/local/bin/clang > /dev/null << EOF
#!/bin/sh
exec /usr/bin/clang --target=$TRIPLE -fuse-ld=lld -Wno-unused-command-line-argument --sysroot=$SYSROOT -isystem$CXX_INCLUDE_DIR -isystem$SYSROOT/usr/include/c++/10 "\$@"
EOF
sudo chmod +x /usr/local/bin/clang

sudo tee /usr/local/bin/clang++ > /dev/null << EOF
#!/bin/sh
exec /usr/bin/clang++ --target=$TRIPLE -fuse-ld=lld -Wno-unused-command-line-argument --sysroot=$SYSROOT -isystem$CXX_INCLUDE_DIR -isystem$SYSROOT/usr/include/c++/10 "\$@"
EOF
sudo chmod +x /usr/local/bin/clang++

echo "Successfully configured Ubuntu Bionic sysroot and compiler wrappers for $TRIPLE."