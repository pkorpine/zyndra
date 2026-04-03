FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI:append = " \
    file://tftp-env.cfg \
    file://zynq-tftp-env.h;subdir=git/include/configs \
    file://0001-zynq-include-tftp-env.patch \
"
