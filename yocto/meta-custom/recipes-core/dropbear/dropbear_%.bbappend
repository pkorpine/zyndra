FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://authorized_keys \
            file://dropbear_rsa_host_key"

do_install:append() {
    install -d ${D}/etc/dropbear
    install -m 0600 ${WORKDIR}/dropbear_rsa_host_key ${D}/etc/dropbear/dropbear_rsa_host_key

    install -d ${D}/home/root/.ssh
    install -m 0600 ${WORKDIR}/authorized_keys ${D}/home/root/.ssh/authorized_keys
}

FILES:${PN} += "/home/root/.ssh/authorized_keys"
