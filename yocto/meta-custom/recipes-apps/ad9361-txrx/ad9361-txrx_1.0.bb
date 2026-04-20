SUMMARY = "AD9361 TX/RX IQ streaming and test tool"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ad9361_txrx.c \
    file://cli.h \
    file://driver.c file://driver.h \
    file://net.c    file://net.h \
    file://prbs.c   file://prbs.h \
    file://stats.c  file://stats.h \
    file://rx.c     file://rx.h \
    file://tx.c     file://tx.h \
    file://diag.c   file://diag.h \
"

S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -o ad9361_txrx \
        ad9361_txrx.c driver.c net.c prbs.c stats.c rx.c tx.c diag.c \
        -lrt -lm -lpthread
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ad9361_txrx ${D}${bindir}/ad9361_txrx
}
