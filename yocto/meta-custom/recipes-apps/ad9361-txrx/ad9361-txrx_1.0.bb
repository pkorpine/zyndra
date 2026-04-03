SUMMARY = "AD9361 TX/RX IQ streaming and test tool"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://ad9361_txrx.c"

S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -o ad9361_txrx ad9361_txrx.c -lrt -lm
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ad9361_txrx ${D}${bindir}/ad9361_txrx
}
