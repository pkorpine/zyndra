#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."

# Build the Rust peripheral emulation library
echo "Building ad936x-emu..."
cargo build --release --manifest-path "$SCRIPT_DIR/ad936x-emu/Cargo.toml"

export AD936X_LIB="$SCRIPT_DIR/ad936x-emu/target/release/libad936x_emu.so"

DTB="-dtb $REPO_ROOT/yocto/build/tmp/deploy/images/zynq-generic/system.dtb"
#DTB=""
ZIMAGE="$REPO_ROOT/yocto/build/tmp/deploy/images/zynq-generic/zImage"
INITRD="$REPO_ROOT/yocto/build/tmp/deploy/images/zynq-generic/core-image-minimal-zynq-generic.rootfs.cpio.gz"


# The loader params are used to preload the SCLR registers
"$SCRIPT_DIR/qemu/build/qemu-system-arm" -M arm-generic-fdt-7series -m 1024 \
        -serial null -serial mon:stdio -nodefaults \
        -device loader,addr=0xf8000008,data=0xDF0D,data-len=4 \
        -device loader,addr=0xf8000140,data=0x00500801,data-len=4 \
        -device loader,addr=0xf800012c,data=0x1ed044d,data-len=4 \
        -device loader,addr=0xf8000108,data=0x0001e008,data-len=4 \
        -device loader,addr=0xF8000910,data=0xF,data-len=0x4 \
        -machine linux=on \
        -kernel "$ZIMAGE" \
        $DTB \
        -initrd "$INITRD" \
        -append "console=ttyPS0,115200 earlyprintk root=/dev/ram rw"
