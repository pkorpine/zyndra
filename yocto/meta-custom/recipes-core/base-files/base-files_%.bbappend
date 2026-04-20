FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
BASEFILESISSUEINSTALL = ""
ZYNDRA_VERSION ?= "unknown"

do_install:append() {
    install -m 0644 ${WORKDIR}/issue ${D}${sysconfdir}/issue
    echo " ${ZYNDRA_VERSION}" >> ${D}${sysconfdir}/issue
    echo >> ${D}${sysconfdir}/issue
}
