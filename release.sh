#!/bin/bash
set -e

DIR=$(readlink -f $(dirname "$0"))

# --- Version
VERSION=$(git describe --tags --abbrev=8 2>/dev/null \
    | sed 's|.*v||; s/-\([0-9]*\)-g/+\1./')

echo "Release version: $VERSION"
echo "Output file:     zyndra-fw-${VERSION}.wic.gz"
echo
read -p "Press Enter to continue or Ctrl-C to abort..."

# --- Vivado
echo "==> Creating Vivado project..."
(cd "${DIR}/fpga" && bash create_vivado_project.sh)

echo "==> Compiling Vivado project..."
(cd "${DIR}/fpga" && bash compile_vivado_project.sh)

# --- Yocto
echo "==> Building Yocto..."
"${DIR}/yocto/build.sh"

# --- Package
echo "==> Compressing..."
WIC="${DIR}/yocto/build/tmp/deploy/images/zynq-generic/core-image-minimal-zynq-generic.rootfs.wic"
OUT="${DIR}/zyndra-fw-${VERSION}.wic.gz"
gzip -c "$WIC" > "$OUT"

echo "Done: $OUT"
