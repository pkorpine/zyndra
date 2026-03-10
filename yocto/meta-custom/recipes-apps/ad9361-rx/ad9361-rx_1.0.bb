SUMMARY = "AD9361 IQ capture via EMIO GPIO, outputs cs16 to stdout"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://ad9361_rx.c"

S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -o ad9361_rx ad9361_rx.c -lrt
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ad9361_rx ${D}${bindir}/ad9361_rx
}
