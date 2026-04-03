FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
BASEFILESISSUEINSTALL = ""

def get_build_timestamp(d):
    import datetime
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M')

do_install:append() {
    install -m 0644 ${WORKDIR}/issue ${D}${sysconfdir}/issue
    BUILD_TS="${@get_build_timestamp(d)}"
    sed -i "s/@BUILD_TIMESTAMP@/${BUILD_TS}/" ${D}${sysconfdir}/issue
}
