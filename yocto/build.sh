#!/bin/sh
set -e
DIR=$(readlink -f $(dirname "$0"))

# Generate version information
GIT_VERSION=$(git -C "${DIR}/.." describe --tags --dirty --always 2>/dev/null || echo "unknown")
BUILD_TS=$(date '+%Y-%m-%d %H:%M')
echo "ZYNDRA_VERSION = \"${GIT_VERSION} (${BUILD_TS})\"" > "${DIR}/build/conf/version.conf"

${DIR}/run.sh bitbake core-image-minimal

DEPLOY=${DIR}/build/tmp/deploy/images/zynq-generic
TFTP=/var/lib/tftpboot

if [ -d "$TFTP" ]; then
    cp $DEPLOY/{uImage,system.dtb,boot.bin,boot.scr} $TFTP/
    cp $DEPLOY/core-image-minimal-zynq-generic.rootfs.cpio.gz.u-boot $TFTP/rootfs.cpio.gz.u-boot
    echo
    echo "Deployed to TFTP"
fi
