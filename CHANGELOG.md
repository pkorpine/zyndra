# Changelog

## v0.1.0

### FPGA

- Implemented TX path: AXI4 burst read master, async FIFO, LVDS serializer
- Added `core.vhd` splitting design core from top-level for simulation support
- Added `ad936x_axi_pkg.vhd` with register map, control bit constants, and AXI
  record type definitions
- Added `axi_master_rd.vhd` for TX DMA ringbuffer reads
- Improved AXI master write pipelining
- GHDL/VUnit simulation framework with testbenches for ad936x_txrx, ad936x_axi,
  and full core integration
- Behavioral IDDR/ODDR stubs for GHDL compatibility

### Linux / Yocto

- Added `ad936x-axi` kernel driver for DMA ringbuffer management with cached
  memory mapping and explicit cache invalidation
- Added `ad936x-tcp` experimental kernel driver for kernel-space TCP streaming
  (~18 MSPS), mutually exclusive with `ad936x-axi`
- Replaced `ad9361-rx` userspace app with `ad9361-txrx` supporting RX (TCP/UDP)
  and TX (TCP) streaming
- Device tree: added TX buffer reserved memory, `ad936x-axi` device node, and
  default RF/LO/gain/bus-timing configuration for AD9361
- FPGA bitstream loader loads `ad936x-axi` kernel module after bitstream
- Added TFTP boot support for fast development iterations (U-Boot patches,
  `build.sh` deploy script)
- Added `/etc/issue` banner and sysvinit rcS defaults
- Relocated Yocto download and sstate-cache directories to `~/.yocto/`

### Host tools

- Replaced `ad936x-prbs-check` with `ad936x-tool` (Rust) supporting PRBS
  verification and TX IQ streaming

### QEMU

- Added QEMU emulation environment with Xilinx QEMU and custom ad936x_axi
  device
- Rust-based peripheral emulator generating synthetic IQ samples via DMA

## v0.0.1

Initial release with RX-only data path and basic Yocto image.
