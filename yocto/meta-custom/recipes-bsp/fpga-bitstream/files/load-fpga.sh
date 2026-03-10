#!/bin/sh
FIRMWARE="design.bin"

case "$1" in
    start)
        echo "Loading FPGA bitstream..."
        echo 0 > /sys/class/fpga_manager/fpga0/flags
        mkdir -p /lib/firmware
        echo ${FIRMWARE} > /sys/class/fpga_manager/fpga0/firmware

        if [ "$(cat /sys/class/fpga_manager/fpga0/state)" = "operating" ]; then
            echo "FPGA loaded successfully"

            echo "Loading AD9361 driver"
            modprobe ad9361

            # Cycle ENSM alert -> fdd to arm the LVDS data interface.
            # Normally ad9361_post_setup() in the AXI driver does this, but
            # without an AXI ADC/DAC IP core we must replicate it manually.
            ENSM=$(find /sys/bus/iio/devices -name ensm_mode 2>/dev/null | head -n 1)
            if [ -n "$ENSM" ]; then
                echo "Cycling AD9361 ENSM: alert -> fdd"
                echo alert > "$ENSM"
                echo fdd   > "$ENSM"
            else
                echo "Warning: ensm_mode not found, LVDS data interface may not be armed"
            fi
        else
            echo "FPGA load failed: $(cat /sys/class/fpga_manager/fpga0/state)"
        fi
        ;;
    stop)
        rmmod ad9361
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac

exit 0
