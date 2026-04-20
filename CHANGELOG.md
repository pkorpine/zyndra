# Changelog

## [v0.2.0] - 2026-04-20

Simultaneous TX+RX.

### Yocto

- `ad9361-txrx`: refactor, added simultaneous TX+RX operation support

### Host tools

- `ad936x-tool`: added PRBS transmitter mode

## [v0.1.0] - 2026-04-03

TX support, kernel drivers, simulation, QEMU.

### FPGA

- Implemented TX path: AXI4 burst read master, async FIFO, LVDS serializer
- Improved AXI master write pipelining
- GHDL/VUnit simulation framework with testbenches

### Yocto

- Added `ad936x-axi` kernel driver for DMA ringbuffer TX/RX
- Added `ad936x-tcp` experimental kernel driver for kernel-space TCP streaming (~18 MSPS)
- Added TFTP boot support for fast development iterations
- Replaced `ad9361-rx` with `ad9361-txrx` supporting RX (TCP/UDP) and TX (TCP)

### Host tools

- Replaced `ad936x-prbs-check` with `ad936x-tool` supporting PRBS and TX IQ streaming

### QEMU

- Added QEMU emulation with Xilinx QEMU and Rust-based ad936x peripheral emulator

## [v0.0.1] - 2026-03-10

Initial release with RX-only data path and basic Yocto image.
