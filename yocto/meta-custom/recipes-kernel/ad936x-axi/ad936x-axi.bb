SUMMARY = "AD936x AXI DMA kernel driver"
DESCRIPTION = "Platform driver for the custom AD936x AXI FPGA peripheral. \
Provides cached mmap access to the RX DDR buffer and read-based cache invalidation."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://ad936x-axi.c;beginline=1;endline=1;md5=fcab174c20ea2e2bc0be64b493708266"

inherit module

do_compile[depends] += "virtual/kernel:do_compile"

SRC_URI = " \
    file://ad936x-axi.c \
    file://Makefile \
"

S = "${WORKDIR}"

RPROVIDES:${PN} += "kernel-module-ad936x-axi"

KERNEL_MODULE_PROBECONF += "ad936x-axi"
module_conf_ad936x-axi = "blacklist ad936x-axi"
