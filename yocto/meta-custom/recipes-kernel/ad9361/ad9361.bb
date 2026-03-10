SUMMARY = "AD9361 IIO SPI driver (out-of-tree)"
DESCRIPTION = "AD9361/AD9363 RF transceiver driver from ADI linux (analogdevicesinc/linux commit 538699ea)"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://ad9361_main.c;beginline=1;endline=5;md5=55600657734ef765291b8b27edfa7377"

inherit module

do_compile[depends] += "virtual/kernel:do_compile"

# NOTE: ad9361.c renamed to ad9361_main.c to avoid conflicting names during compilation

SRC_URI = " \
    file://ad9361_main.c \
    file://ad9361.h \
    file://ad9361_regs.h \
    file://ad9361_private.h \
    file://ad9361_conv.c \
    file://Makefile \
"

S = "${WORKDIR}"

RPROVIDES:${PN} += "kernel-module-ad9361"

# Prevent udev from autoloading before the FPGA bitstream is loaded.
# The init script (load-fpga.sh) loads the module explicitly after the bitstream.
KERNEL_MODULE_PROBECONF += "ad9361"
module_conf_ad9361 = "blacklist ad9361"
