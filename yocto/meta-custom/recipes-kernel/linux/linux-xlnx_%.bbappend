FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI += "\
    file://bootargs.cfg \
    file://zynq-slim.cfg \
    file://spidev.cfg \
    file://debugfs.cfg \
    "
