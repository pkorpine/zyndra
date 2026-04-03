#ifndef __ZYNQ_TFTP_ENV_H
#define __ZYNQ_TFTP_ENV_H

#define TFTP_ENV_SETTINGS \
	"tftpboot_cmd=tftpboot ${kernel_addr_r} uImage; " \
		"tftpboot ${fdt_addr_r} system.dtb; " \
		"tftpboot ${ramdisk_addr_r} rootfs.cpio.gz.u-boot; " \
		"bootm ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}\0" \
	"use_tftpboot=fatwrite mmc 0:1 ${loadaddr} tftpboot.flag 0; reset\0" \
	"use_sdboot=fatrm mmc 0:1 tftpboot.flag; reset\0" \
	"update_boot=tftpboot ${loadaddr} boot.bin; " \
		"fatwrite mmc 0:1 ${loadaddr} boot.bin ${filesize}; " \
		"tftpboot ${loadaddr} boot.scr; " \
		"fatwrite mmc 0:1 ${loadaddr} boot.scr ${filesize}; " \
		"echo Boot files updated.\0"

#endif
