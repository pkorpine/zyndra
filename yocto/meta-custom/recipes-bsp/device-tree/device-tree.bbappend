FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://system-user.dtsi"

do_configure:append() {
    cp ${WORKDIR}/system-user.dtsi ${B}/device-tree/
    echo "#include \"system-user.dtsi\"" >> ${B}/device-tree//system-top.dts
}
