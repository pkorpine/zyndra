# ==============================================================================
# XDC Constraints for Zynq-7020 CLG400 + AD9363 SDR Board
# (HamGeek / OpenSDRLab "Fishball"-class Pluto SDR clone)
#
# Target device: xc7z020clg400-1
#
# Source: OpenSDRLab7020_936x_SDR_gpio.pdf schematic (2025-02-15)
#
# Bank VCCO voltages (from schematic page 1):
#   Bank 34: VCC1V8 (1.8V)  — AD9363 LVDS data + control signals
#   Bank 35: VCC1V8 (1.8V)   — Extension header 1.8V IOs, some CTRL pins
#   Bank 13: VCC3V3 (3.3V)  — Extension header 3.3V IOs
#   Bank 500: VCC1V8 (PS MIO 0-15)
#   Bank 501: VCC1V8 (PS MIO 16-53)
# ==============================================================================

# ==============================================================================
# AD9363 LVDS Data Interface (PL - Bank 34, VCCO = 1.8V)
# ==============================================================================
# The AD9363 is connected in LVDS mode with 6 differential data pairs.
# Pin assignments verified against the board schematic (page 5).
#
# IOSTANDARD: LVDS_25 is used here to match the ADI axi_ad9361 HDL reference.
# Bank 34 VCCO is 1.8V, not 2.5V. For LVDS inputs with DIFF_TERM, this works
# because the internal differential termination is VCCO-independent on HR banks.
# For LVDS outputs, the current-mode driver functions at 1.8V VCCO in practice,
# though Xilinx nominally specifies 2.5V.
# [VERIFY] If synthesis/implementation fails, change to DIFF_HSTL_I_18 for
#          inputs and DIFF_HSTL_I_18 for outputs as a 1.8V-compliant alternative.
# ------------------------------------------------------------------------------

# RX data clock (DATA_CLK from AD9363 to FPGA, IO_L12x_T1_MRCC)
set_property -dict {PACKAGE_PIN U18 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_clk_in_p]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_clk_in_n]

# RX frame (from AD9363 to FPGA, IO_L7x_T1)
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_frame_in_p]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_frame_in_n]

# RX data [5:0] (from AD9363 to FPGA)
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_p[0]]  ;# IO_L17P_T2
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_n[0]]  ;# IO_L17N_T2
set_property -dict {PACKAGE_PIN T16 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_p[1]]  ;# IO_L9P_T1_DQS
set_property -dict {PACKAGE_PIN U17 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_n[1]]  ;# IO_L9N_T1_DQS
set_property -dict {PACKAGE_PIN V20 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_p[2]]  ;# IO_L16P_T2
set_property -dict {PACKAGE_PIN W20 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_n[2]]  ;# IO_L16N_T2
set_property -dict {PACKAGE_PIN T17 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_p[3]]  ;# IO_L20P_T3
set_property -dict {PACKAGE_PIN R18 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_n[3]]  ;# IO_L20N_T3
set_property -dict {PACKAGE_PIN T20 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_p[4]]  ;# IO_L15P_T2_DQS
set_property -dict {PACKAGE_PIN U20 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_n[4]]  ;# IO_L15N_T2_DQS
set_property -dict {PACKAGE_PIN W18 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_p[5]]  ;# IO_L22P_T3
set_property -dict {PACKAGE_PIN W19 IOSTANDARD DIFF_HSTL_I_18 DIFF_TERM TRUE} [get_ports rx_data_in_n[5]]  ;# IO_L22N_T3

# TX feedback clock (FB_CLK from FPGA to AD9363, IO_L11x_T1_SRCC)
set_property -dict {PACKAGE_PIN U14 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_clk_out_p]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_clk_out_n]

# TX frame (from FPGA to AD9363, IO_L18x_T2)
set_property -dict {PACKAGE_PIN V16 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_frame_out_p]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_frame_out_n]

# TX data [5:0] (from FPGA to AD9363)
set_property -dict {PACKAGE_PIN V15 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_p[0]]  ;# IO_L10P_T1
set_property -dict {PACKAGE_PIN W15 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_n[0]]  ;# IO_L10N_T1
set_property -dict {PACKAGE_PIN V12 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_p[1]]  ;# IO_L4P_T0
set_property -dict {PACKAGE_PIN W13 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_n[1]]  ;# IO_L4N_T0
set_property -dict {PACKAGE_PIN W14 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_p[2]]  ;# IO_L8P_T1
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_n[2]]  ;# IO_L8N_T1
set_property -dict {PACKAGE_PIN T12 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_p[3]]  ;# IO_L2P_T0
set_property -dict {PACKAGE_PIN U12 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_n[3]]  ;# IO_L2N_T0
set_property -dict {PACKAGE_PIN T11 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_p[4]]  ;# IO_L1P_T0
set_property -dict {PACKAGE_PIN T10 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_n[4]]  ;# IO_L1N_T0
set_property -dict {PACKAGE_PIN U13 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_p[5]]  ;# IO_L3P_T0_DQS
set_property -dict {PACKAGE_PIN V13 IOSTANDARD DIFF_HSTL_I_18} [get_ports tx_data_out_n[5]]  ;# IO_L3N_T0_DQS

# ==============================================================================
# AD9363 Control Signals (Bank 34, single-ended, VCCO = 1.8V)
# ==============================================================================
# These pins are single-ended regardless of LVDS/CMOS data mode.
# Pin assignments verified against the board schematic (page 5).
# ------------------------------------------------------------------------------

# AD9363 ENABLE and TXNRX mode control
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS18} [get_ports enable]       ;# IO_L5N_T0
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS18} [get_ports txnrx]        ;# IO_L23N_T3

# AD9363 AGC and RESETB
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS18} [get_ports gpio_en_agc]  ;# IO_L14N_T2_SRCC
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS18} [get_ports gpio_resetb]  ;# IO_0

# AD9363 CLKOUT (40 MHz reference clock output)
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS18} [get_ports clk_out]      ;# IO_L19P_T3

# AD9363 SYNC input (directly active-low)
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS18} [get_ports gpio_sync]    ;# IO_25 (Bank 34)

# PTT IO (active-low, drives optocoupler K1 AQY-221N2VW via MOSFET Q3)
# set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS18} [get_ports gpio_ptt]     ;# IO_L6P_T0

# ==============================================================================
# AD9363 CTRL_OUT Status Pins (active-low, from AD9363)
# ==============================================================================
# These pins are split across Bank 34 (VCCO=1.8V) and Bank 35 (VCCO=1.8V).
# Pin assignments verified against the board schematic (page 5).
# ------------------------------------------------------------------------------

# Bank 35 CTRL_OUT pins (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS18} [get_ports gpio_status[0]]  ;# Bank 35, IO_L9N
# set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS18} [get_ports gpio_status[1]]  ;# Bank 35, IO_L9P
# set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS18} [get_ports gpio_status[2]]  ;# Bank 35, IO_L10P

# Bank 34 CTRL_OUT pins (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS18} [get_ports gpio_status[3]]  ;# Bank 34, IO_L5P_T0
# set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS18} [get_ports gpio_status[4]]  ;# Bank 34, IO_L24P_T3

# Bank 35 CTRL_OUT pins (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS18} [get_ports gpio_status[5]]  ;# Bank 35, IO_L7N
# set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS18} [get_ports gpio_status[6]]  ;# Bank 35, IO_L7P

# Bank 34 CTRL_OUT pin (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS18} [get_ports gpio_status[7]]  ;# Bank 34, IO_L14P_T2_SRCC

# ==============================================================================
# AD9363 CTRL_IN Control Pins
# ==============================================================================
# Also split across Bank 34 and Bank 35.
# Pin assignments verified against the board schematic (page 5).
# ------------------------------------------------------------------------------

# Bank 35 CTRL_IN pins (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[0]]  ;# Bank 35, IO_L10N
# set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[1]]  ;# Bank 35, IO_L20P

# Bank 34 CTRL_IN pin (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[2]]  ;# Bank 34, IO_L6N_T0_VREF

# Bank 35 CTRL_IN pin (VCCO = 1.8V)
# set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[3]]  ;# Bank 35, IO_L17P

# ==============================================================================
# AD9363 SPI Interface (Bank 34, VCCO = 1.8V)
# ==============================================================================
# AD9363 SPI directly from FPGA PL fabric via PS7 SPI0 EMIO.
# Active-low chip select.
# Pin assignments verified against the board schematic (page 5).
# ------------------------------------------------------------------------------

set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS18 PULLTYPE PULLUP} [get_ports spi_csn]   ;# IO_L19N_T3_VREF
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS18}                 [get_ports spi_clk]   ;# IO_L21P_T3_DQS
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS18}                 [get_ports spi_mosi]  ;# IO_L24N_T3
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS18}                 [get_ports spi_miso]  ;# IO_L21N_T3

# ==============================================================================
# PL 50 MHz Clock (Bank 34, VCCO = 1.8V)
# ==============================================================================
# 50 MHz oscillator Y1 (50M_1V8) via 33R series resistor R63.
# Connected to IO_L13P_T2_MRCC — a multi-region clock-capable input.
# Pin assignment verified against the board schematic (page 5).
# ------------------------------------------------------------------------------

# set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS18} [get_ports pl_gclk]  ;# IO_L13P_T2_MRCC

# ==============================================================================
# AD9363 Reference Clock (FPGA_CLK, Bank 35, VCCO = 1.8V)
# ==============================================================================
# Clock output from AD9363 routed to FPGA via R110 (33R/NC — may not be
# populated). Connected to IO_L12P_T1_MRCC on Bank 35.
# [VERIFY] Check if R110 is populated on your board. If not, this signal
#          is not connected and should remain commented out.
# ------------------------------------------------------------------------------

# set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS18} [get_ports fpga_clk]  ;# Bank 35, IO_L12P_T1_MRCC

# ==============================================================================
# Extension Header JP5 (20-pin)
# ==============================================================================
# Pinout from schematic page 13:
#   Pin 1:  VCC1V8          Pin 2:  GND
#   Pin 3:  3V3_IO1         Pin 4:  1V8_IO1_P
#   Pin 5:  VCC3V3          Pin 6:  1V8_IO1_N
#   Pin 7:  3V3_IO2         Pin 8:  1V8_IO3_P
#   Pin 9:  VCC5V           Pin 10: 1V8_IO3_N
#   Pin 11: 3V3_IO3         Pin 12: 1V8_IO5_P
#   Pin 13: 3V3_IO4         Pin 14: 1V8_IO5_N
#   Pin 15: XTAL_VTC        Pin 16: 1V8_IO7_P
#   Pin 17: PTT             Pin 18: 1V8_IO7_N
#   Pin 19: AD936X_SYNC     Pin 20: GND
#
# Bank 35 differential pairs (VCCO = 1.8V):
# Bank 13 single-ended (VCCO = 3.3V):
#   Using LVCMOS33.
# Pin assignments verified against the board schematic (page 5).
# ------------------------------------------------------------------------------

# Bank 35 differential IO pairs (active as single-ended or differential)
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io1_p]  ;# JP5.4,  IO_L18P_T2
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io1_n]  ;# JP5.6,  IO_L18N_T2
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io3_p]  ;# JP5.8,  IO_L14P_T2_SRCC
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io3_n]  ;# JP5.10, IO_L14N_T2_SRCC
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io5_p]  ;# JP5.12, IO_L13P_T2_MRCC
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io5_n]  ;# JP5.14, IO_L13N_T2_MRCC
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io7_p]  ;# JP5.16, IO_L22P_T3
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS18} [get_ports ext_1v8_io7_n]  ;# JP5.18, IO_L22N_T3

# Bank 13 single-ended IOs (VCCO = 3.3V)
# set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports ext_3v3_io1]  ;# JP5.3,  IO_L20N
# set_property -dict {PACKAGE_PIN U9  IOSTANDARD LVCMOS33} [get_ports ext_3v3_io2]  ;# JP5.7,  IO_L16P
# set_property -dict {PACKAGE_PIN U10 IOSTANDARD LVCMOS33} [get_ports ext_3v3_io3]  ;# JP5.11, IO_L12N
# set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports ext_3v3_io4]  ;# JP5.13, IO_L12P

# ==============================================================================
# Timing Constraints
# ==============================================================================

# AD9363 RX clock (LVDS DDR)
# DATA_CLK = 2x sample rate = 2 x 30.72 MHz = 61.44 MHz -> period = 16.276 ns
create_clock -name rx_clk -period 16.276 [get_ports rx_clk_in_p]

# PL 50 MHz oscillator clock
# create_clock -name pl_gclk -period 20.0 [get_ports pl_gclk]

# PS7 FCLK clocks (from PS7 PLL)
# create_clock -name clk_fpga_0 -period 10.0 [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[0]"]
# create_clock -name clk_fpga_1 -period  5.0 [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[1]"]

# PS7 SPI0 clock (EMIO - for AD9363 SPI)
# create_clock -name spi0_clk -period 40 [get_pins -hier */EMIOSPI0SCLKO]

# set_input_jitter clk_fpga_0 0.3
# set_input_jitter clk_fpga_1 0.15

# ==============================================================================
# False Paths
# ==============================================================================
# GPIO output registers in the ADI axi_ad9361 IP are asynchronous
# to the data path and do not need timing closure.

# set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_rx/i_up_adc_common/up_adc_gpio_out_int_reg[0]/C}]
# set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_tx/i_up_dac_common/up_dac_gpio_out_int_reg[0]/C}]

# ==============================================================================
# PS7 MIO Pin Reference (for documentation only)
# ==============================================================================
# PS MIO pins are configured via PS7 IP block, NOT via XDC constraints.
# From schematic pages 2 and 6:
#
# Bank 500 (VCCO = 1.8V):
#   MIO[ 0]     : GPIO (LED, active-low white LED via R17)
#   MIO[ 1]     : QSPI CS
#   MIO[ 2]     : QSPI D0 (IO0/DI)
#   MIO[ 3]     : QSPI D1
#   MIO[ 4]     : QSPI D2
#   MIO[ 5]     : QSPI D3
#   MIO[ 6]     : QSPI SCK
#   MIO[ 7]     : GPIO (PS_MIO7)
#   MIO[ 8]     : UART1 TX (UART_TXD, to FT2232HL BDBUS1/FTDI_RXD)
#   MIO[ 9]     : UART1 RX (UART_RXD, from FT2232HL BDBUS0/FTDI_TXD)
#   MIO[10-15]  : GPIO
#
# Bank 501 (VCCO = 1.8V):
#   MIO[16]     : Ethernet RGMII TX CLK (PHY_TXCLK)
#   MIO[17]     : Ethernet RGMII TXD0
#   MIO[18]     : Ethernet RGMII TXD1
#   MIO[19]     : Ethernet RGMII TXD2
#   MIO[20]     : Ethernet RGMII TXD3
#   MIO[21]     : Ethernet RGMII TX CTL
#   MIO[22]     : Ethernet RGMII RX CLK (PHY_RXCLK)
#   MIO[23]     : Ethernet RGMII RXD0
#   MIO[24]     : Ethernet RGMII RXD1
#   MIO[25]     : Ethernet RGMII RXD2
#   MIO[26]     : Ethernet RGMII RXD3
#   MIO[27]     : Ethernet RGMII RX CTL
#   MIO[28]     : USB0 DATA4
#   MIO[29]     : USB0 DIR
#   MIO[30]     : USB0 STP
#   MIO[31]     : USB0 NXT
#   MIO[32]     : USB0 DATA0
#   MIO[33]     : USB0 DATA1
#   MIO[34]     : USB0 DATA2
#   MIO[35]     : USB0 DATA3
#   MIO[36]     : USB0 CLK
#   MIO[37]     : USB0 DATA5
#   MIO[38]     : USB0 DATA6
#   MIO[39]     : USB0 DATA7
#   MIO[40]     : SD0 CLK
#   MIO[41]     : SD0 CMD
#   MIO[42]     : SD0 D0
#   MIO[43]     : SD0 D1
#   MIO[44]     : SD0 D2
#   MIO[45]     : SD0 D3
#   MIO[46]     : USB PHY Reset (OTG_RST)
#   MIO[47-51]  : GPIO
#   MIO[52]     : Ethernet MDIO MDC (PHY_MDC)
#   MIO[53]     : Ethernet MDIO MDIO (PHY_MDIO)
#
# PS DDR: 32-bit DDR3 (2x MT41K256M16, 1GB total, Bank 502)
# PS CLK: 33.33 MHz oscillator Y2 (33.33M_3V3) via 33R R80
# ==============================================================================

# ==============================================================================
# DRC Severity Overrides
# ==============================================================================
# Suppress warnings for unconstrained pins during initial development.
# Remove these once all pins are properly constrained.

# set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
# set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
