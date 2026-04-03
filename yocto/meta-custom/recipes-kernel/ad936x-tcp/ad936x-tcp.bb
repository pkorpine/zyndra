SUMMARY = "AD936x TCP streaming kernel driver"
DESCRIPTION = "Kernel-side TCP server that streams AD936x IQ data directly \
from the DMA ring buffer, bypassing userspace for zero-copy networking."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://ad936x-tcp.c;beginline=1;endline=1;md5=fcab174c20ea2e2bc0be64b493708266"

inherit module

do_compile[depends] += "virtual/kernel:do_compile"

SRC_URI = " \
    file://ad936x-tcp.c \
    file://Makefile \
"

S = "${WORKDIR}"

RPROVIDES:${PN} += "kernel-module-ad936x-tcp"

KERNEL_MODULE_PROBECONF += "ad936x-tcp"
module_conf_ad936x-tcp = "blacklist ad936x-tcp"
