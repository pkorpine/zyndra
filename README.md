# Zyndra

Zyndra is a custom firmware for a Pluto-SDR clone (Zynq-7020 + AD936x). This is
my take on implementing it from scratch as a learning experience in AD936x,
creating an efficient IQ data pipeline, and processing IQ data on FPGA.

The FPGA design is done from scratch for Zynq-7020 and AD936x chip using Vivado
2024.2.

The Linux is built using Yocto Scarthgap. This is reusing ADI's ad936x kernel
driver. Other parts are implemented from scratch.

## Current status

- Uses ad936x IIO driver for configuring the chip.
- Data bus operates at 1R1T, but only receive part is implemented.
- RX data is streamed to a ringbuffer in DDR reserved memory.
- Since the ringbuffer memory is marked as non-cached (so that no need to yet
  mind about cache coherency), the streaming performance is limited to roughly
  13 MSPS on TCP and 11 MSPS on UDP.
- FPGA bitstream loaded using a service during kernel boot

## Running instructions

- Login: root (no password)
- IP: 192.168.133.134 (static, configure in
  `yocto/meta-custom/recipes-core/init-ifupdown/files/interfaces`)
- SSH service running
- SD card partitioning (wic image handles this)
  - boot partition (fat)
  - root filesystem (ext4)

### Configuring AD936x

```sh
# Set sampling rate first (reconfigures digital chain)
echo 2500000 > /sys/bus/iio/devices/iio:device1/in_voltage_sampling_frequency

# Set analog RF bandwidth to match your signal
echo 2000000 > /sys/bus/iio/devices/iio:device1/in_voltage_rf_bandwidth

# Then LO and gain
echo 433920000 > /sys/bus/iio/devices/iio:device1/out_altvoltage0_RX_LO_frequency
echo manual > /sys/bus/iio/devices/iio:device1/in_voltage0_gain_control_mode
echo 30 > /sys/bus/iio/devices/iio:device1/in_voltage0_hardwaregain
```

### Streaming

```sh
# Send data out via UDP
ad9361_rx --udp 192.168.133.1:1234

# Serve data out on TCP
ad9361_rx --tcp 1234
```

## Building instructions

### Requirements

- Host: Linux with Podman (for Yocto build)
- FPGA tools: Vivado 2024.2
- Hardware: Pluto-SDR clone with Zynq-7020 and AD936x

### Code style checks

```sh
# VHDL
cd fpga
uv run vsg -c vsg_config.yaml --fix

# Run all checks
pre-commit run --all-files
```

### FPGA compilation

Uses Vivado 2024.2.

```sh
cd fpga

# Load environment
source /tools/Xilinx/Vivado/2024.2/settings64.sh

# Create Vivado project to `vivado` directory
./create_vivado_project.sh

# Compile
./compile_vivado_project.sh
```

### Yocto

Uses Yocto Scarthgap which is compatible with Vivado 2024.2.

```sh
# Build the container image
yocto/container/build.sh
```

```sh
# Run bitbake in container
yocto/run.sh bitbake core-image-minimal

# A .wic image will appear. Burn it to SD card using `dd` or Balena Etcher
ls -l yocto/build/tmp/deploy/images/zynq-generic/core-image-minimal-zynq-generic.rootfs.wic
```

## Testing

### PRBS

Configure AD936x to PRBS mode

```sh
# Set sample rate
echo 2500000 > /sys/bus/iio/devices/iio:device1/in_voltage_sampling_frequency

# Set PRBS mode
echo 0x3f5 0x40 > /sys/kernel/debug/iio/iio:device1/direct_reg_access
echo 0x3f4 0x09 > /sys/kernel/debug/iio/iio:device1/direct_reg_access

# Set RX bus delays
echo 0x006 0x00 > /sys/kernel/debug/iio/iio:device1/direct_reg_access

# Start transmitting
ad9361_rx --tcp 1234
```

Run on the host

```sh
cd host/ad936x-prbs-check
cargo run --release
```

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for
details.

The AD936x IIO kernel driver (`drivers/iio/adc/ad9361*`) is Copyright (C) Analog
Devices Inc. and licensed under GPL-2.0. See the
[ADI driver source](https://github.com/analogdevicesinc/linux/tree/main/drivers/iio/adc)
for details.
