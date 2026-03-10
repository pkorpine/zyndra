SUMMARY = "FPGA bitstream for runtime loading via FPGA manager"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Pull in the bitstream extracted from XSA and bootgen for conversion
DEPENDS += "virtual/bitstream bootgen-native"

# This recipe is board-specific
PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = "file://load-fpga.sh"

inherit update-rc.d

INITSCRIPT_NAME = "load-fpga.sh"
INITSCRIPT_PARAMS = "start 80 S ."

do_compile() {
    # The .bit file is in the sysroot from virtual/bitstream
    BIT_FILE=$(ls ${RECIPE_SYSROOT}/boot/bitstream/*.bit 2>/dev/null | head -1)

    if [ -z "$BIT_FILE" ] || [ ! -s "$BIT_FILE" ]; then
        bbfatal "No bitstream .bit file found in sysroot"
    fi

    # Create a temporary .bif for bootgen conversion
    echo "all: { ${BIT_FILE} }" > ${B}/bitstream.bif

    # Convert .bit to .bin (bit-swapped binary for FPGA manager)
    bootgen -image ${B}/bitstream.bif -arch zynq -process_bitstream bin -w -o ${B}/design.bit
    cp "${BIT_FILE}.bin" ${B}/design.bin
}

do_install() {
    # Install bitstream to /lib/firmware
    install -d ${D}/lib/firmware
    install -m 0644 ${B}/design.bin ${D}/lib/firmware/design.bin

    # Install init script
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/load-fpga.sh ${D}${sysconfdir}/init.d/load-fpga.sh
}

FILES:${PN} = "/lib/firmware/design.bin ${sysconfdir}/init.d/load-fpga.sh"
