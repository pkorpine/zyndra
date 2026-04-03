#!/bin/sh
set -e

QEMU_REPO="https://github.com/Xilinx/qemu.git"
QEMU_BRANCH="xlnx_rel_v2024.2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QEMU_DIR="$SCRIPT_DIR/qemu"
PATCHES_DIR="$SCRIPT_DIR/qemu-patches"

# Clone if not present
if [ ! -d "$QEMU_DIR" ]; then
    echo "Cloning Xilinx QEMU ($QEMU_BRANCH)..."
    git clone --branch "$QEMU_BRANCH" --depth 1 "$QEMU_REPO" "$QEMU_DIR"
fi

# Apply patches (idempotent: reset tracked files first)
cd "$QEMU_DIR"
git checkout -- hw/misc/meson.build
cp "$PATCHES_DIR/ad936x_axi.c" hw/misc/
git apply "$PATCHES_DIR/0001-add-ad936x-axi-device.patch"
echo "Patches applied."

# Configure (only if not already done)
if [ ! -f build/build.ninja ]; then
    echo "Configuring QEMU..."
    ./configure --target-list=arm-softmmu
fi

# Build
echo "Building QEMU..."
make -j$(nproc)
echo "Done. Binary at $QEMU_DIR/build/qemu-system-arm"
