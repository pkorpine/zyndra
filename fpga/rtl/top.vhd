--------------------------------------------------------------------------------
-- Title       : FPGA Top
-- Project     : Zyndra
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--   Top-level wrapper: connects core (FPGA logic) to zynq_bd (PS7 block
--   design). Handles AXI3/AXI4 adaptation, DDR/FIXED_IO passthrough,
--   SPI passthrough, and AD9361 control GPIO routing.
--
-- History :
--  2026-03-09 PKo
--  2026-04-01 PKo  Split logic into core.vhd
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use work.ad936x_axi_pkg.all;

entity top is
    port (
        -- PS
        ddr_addr          : inout std_logic_vector(14 downto 0);
        ddr_ba            : inout std_logic_vector(2 downto 0);
        ddr_cas_n         : inout std_logic;
        ddr_ck_n          : inout std_logic;
        ddr_ck_p          : inout std_logic;
        ddr_cke           : inout std_logic;
        ddr_cs_n          : inout std_logic;
        ddr_dm            : inout std_logic_vector(3 downto 0);
        ddr_dq            : inout std_logic_vector(31 downto 0);
        ddr_dqs_n         : inout std_logic_vector(3 downto 0);
        ddr_dqs_p         : inout std_logic_vector(3 downto 0);
        ddr_odt           : inout std_logic;
        ddr_ras_n         : inout std_logic;
        ddr_reset_n       : inout std_logic;
        ddr_we_n          : inout std_logic;
        fixed_io_ddr_vrn  : inout std_logic;
        fixed_io_ddr_vrp  : inout std_logic;
        fixed_io_mio      : inout std_logic_vector(53 downto 0);
        fixed_io_ps_clk   : inout std_logic;
        fixed_io_ps_porb  : inout std_logic;
        fixed_io_ps_srstb : inout std_logic;
        -- Ext header
        ext_1v8_io1_p : out   std_logic;
        ext_1v8_io1_n : out   std_logic;
        ext_1v8_io3_p : out   std_logic;
        ext_1v8_io3_n : out   std_logic;
        ext_1v8_io5_p : out   std_logic;
        ext_1v8_io5_n : out   std_logic;
        ext_1v8_io7_p : out   std_logic;
        ext_1v8_io7_n : out   std_logic;
        -- AD9363 LVDS data interface RX (AD9363 -> FPGA)
        rx_clk_in_p   : in    std_logic;
        rx_clk_in_n   : in    std_logic;
        rx_frame_in_p : in    std_logic;
        rx_frame_in_n : in    std_logic;
        rx_data_in_p  : in    std_logic_vector(5 downto 0);
        rx_data_in_n  : in    std_logic_vector(5 downto 0);
        -- AD9363 LVDS data interface TX (FPGA -> AD9363)
        tx_clk_out_p   : out   std_logic;
        tx_clk_out_n   : out   std_logic;
        tx_frame_out_p : out   std_logic;
        tx_frame_out_n : out   std_logic;
        tx_data_out_p  : out   std_logic_vector(5 downto 0);
        tx_data_out_n  : out   std_logic_vector(5 downto 0);
        -- AD9361 Extra
        clk_out   : in    std_logic;
        gpio_sync : out   std_logic;
        -- AD9361 Control
        enable      : out   std_logic;
        txnrx       : out   std_logic;
        gpio_en_agc : out   std_logic;
        gpio_resetb : out   std_logic;
        spi_csn     : out   std_logic;
        spi_clk     : out   std_logic;
        spi_mosi    : out   std_logic;
        spi_miso    : in    std_logic
    );
end entity top;

architecture rtl of top is

    signal s_axil_mosi : t_axi4l_mosi;
    signal s_axil_miso : t_axi4l_miso;
    signal s_axi4_mosi : t_axi4_mosi;
    signal s_axi4_miso : t_axi4_miso;

    signal s_gpio_i : std_logic_vector(63 downto 0);
    signal s_gpio_o : std_logic_vector(63 downto 0);
    signal s_gpio_t : std_logic_vector(63 downto 0);

    signal s_spi_csn  : std_logic;
    signal s_spi_clk  : std_logic;
    signal s_spi_mosi : std_logic;
    signal s_spi_miso : std_logic;

    signal s_axi_clk  : std_logic;
    signal s_axi_rstn : std_logic;

begin

    -- AD9361 control (from Zynq GPIO_O)
    gpio_sync   <= '0';
    gpio_resetb <= s_gpio_o(0);
    enable      <= s_gpio_o(1);
    txnrx       <= s_gpio_o(2);
    gpio_en_agc <= s_gpio_o(3);

    -- SPI passthrough
    spi_csn    <= s_spi_csn;
    spi_clk    <= s_spi_clk;
    spi_mosi   <= s_spi_mosi;
    s_spi_miso <= spi_miso;

    -- FPGA design core
    core_inst : entity work.core
        port map (
            i_axi_clk  => s_axi_clk,
            i_axi_rstn => s_axi_rstn,
            i_axil     => s_axil_mosi,
            o_axil     => s_axil_miso,
            o_axi4     => s_axi4_mosi,
            i_axi4     => s_axi4_miso,
            o_gpio_i   => s_gpio_i,
            -- LVDS
            rx_clk_in_p    => rx_clk_in_p,
            rx_clk_in_n    => rx_clk_in_n,
            rx_frame_in_p  => rx_frame_in_p,
            rx_frame_in_n  => rx_frame_in_n,
            rx_data_in_p   => rx_data_in_p,
            rx_data_in_n   => rx_data_in_n,
            tx_clk_out_p   => tx_clk_out_p,
            tx_clk_out_n   => tx_clk_out_n,
            tx_frame_out_p => tx_frame_out_p,
            tx_frame_out_n => tx_frame_out_n,
            tx_data_out_p  => tx_data_out_p,
            tx_data_out_n  => tx_data_out_n,
            -- Debug header
            ext_1v8_io1_p => ext_1v8_io1_p,
            ext_1v8_io1_n => ext_1v8_io1_n,
            ext_1v8_io3_p => ext_1v8_io3_p,
            ext_1v8_io3_n => ext_1v8_io3_n,
            ext_1v8_io5_p => ext_1v8_io5_p,
            ext_1v8_io5_n => ext_1v8_io5_n,
            ext_1v8_io7_p => ext_1v8_io7_p,
            ext_1v8_io7_n => ext_1v8_io7_n
        );

    -- Zynq PS7 block design
    zynq_bd_inst : entity work.zynq_bd
        port map (
            DDR_addr(14 downto 0)     => ddr_addr(14 downto 0),
            DDR_ba(2 downto 0)        => ddr_ba(2 downto 0),
            DDR_cas_n                 => ddr_cas_n,
            DDR_ck_n                  => ddr_ck_n,
            DDR_ck_p                  => ddr_ck_p,
            DDR_cke                   => ddr_cke,
            DDR_cs_n                  => ddr_cs_n,
            DDR_dm(3 downto 0)        => ddr_dm(3 downto 0),
            DDR_dq(31 downto 0)       => ddr_dq(31 downto 0),
            DDR_dqs_n(3 downto 0)     => ddr_dqs_n(3 downto 0),
            DDR_dqs_p(3 downto 0)     => ddr_dqs_p(3 downto 0),
            DDR_odt                   => ddr_odt,
            DDR_ras_n                 => ddr_ras_n,
            DDR_reset_n               => ddr_reset_n,
            DDR_we_n                  => ddr_we_n,
            FIXED_IO_ddr_vrn          => fixed_io_ddr_vrn,
            FIXED_IO_ddr_vrp          => fixed_io_ddr_vrp,
            FIXED_IO_mio(53 downto 0) => fixed_io_mio(53 downto 0),
            FIXED_IO_ps_clk           => fixed_io_ps_clk,
            FIXED_IO_ps_porb          => fixed_io_ps_porb,
            FIXED_IO_ps_srstb         => fixed_io_ps_srstb,
            -- AXI-Lite (PS master → FPGA slave)
            M00_AXI_0_araddr  => s_axil_mosi.araddr(30 downto 0),
            M00_AXI_0_arprot  => s_axil_mosi.arprot,
            M00_AXI_0_arready => s_axil_miso.arready,
            M00_AXI_0_arvalid => s_axil_mosi.arvalid,
            M00_AXI_0_awaddr  => s_axil_mosi.awaddr(30 downto 0),
            M00_AXI_0_awprot  => s_axil_mosi.awprot,
            M00_AXI_0_awready => s_axil_miso.awready,
            M00_AXI_0_awvalid => s_axil_mosi.awvalid,
            M00_AXI_0_bready  => s_axil_mosi.bready,
            M00_AXI_0_bresp   => s_axil_miso.bresp,
            M00_AXI_0_bvalid  => s_axil_miso.bvalid,
            M00_AXI_0_rdata   => s_axil_miso.rdata,
            M00_AXI_0_rready  => s_axil_mosi.rready,
            M00_AXI_0_rresp   => s_axil_miso.rresp,
            M00_AXI_0_rvalid  => s_axil_miso.rvalid,
            M00_AXI_0_wdata   => s_axil_mosi.wdata,
            M00_AXI_0_wready  => s_axil_miso.wready,
            M00_AXI_0_wstrb   => s_axil_mosi.wstrb,
            M00_AXI_0_wvalid  => s_axil_mosi.wvalid,
            AXI_CLK           => s_axi_clk,
            AXI_RSTN(0)       => s_axi_rstn,
            -- AXI3 HP slave (FPGA master → DDR)
            S_AXI_HP0_0_araddr  => s_axi4_mosi.araddr,
            S_AXI_HP0_0_arburst => s_axi4_mosi.arburst,
            S_AXI_HP0_0_arcache => "0011",
            S_AXI_HP0_0_arid    => (others => '0'),
            S_AXI_HP0_0_arlen   => s_axi4_mosi.arlen(3 downto 0),
            S_AXI_HP0_0_arlock  => (others => '0'),
            S_AXI_HP0_0_arprot  => (others => '0'),
            S_AXI_HP0_0_arqos   => (others => '0'),
            S_AXI_HP0_0_arready => s_axi4_miso.arready,
            S_AXI_HP0_0_arsize  => s_axi4_mosi.arsize,
            S_AXI_HP0_0_arvalid => s_axi4_mosi.arvalid,

            S_AXI_HP0_0_awaddr  => s_axi4_mosi.awaddr,
            S_AXI_HP0_0_awburst => s_axi4_mosi.awburst,
            S_AXI_HP0_0_awcache => "0011",
            S_AXI_HP0_0_awid    => (others => '0'),
            S_AXI_HP0_0_awlen   => s_axi4_mosi.awlen(3 downto 0),
            S_AXI_HP0_0_awlock  => (others => '0'),
            S_AXI_HP0_0_awprot  => (others => '0'),
            S_AXI_HP0_0_awqos   => (others => '0'),
            S_AXI_HP0_0_awready => s_axi4_miso.awready,
            S_AXI_HP0_0_awsize  => s_axi4_mosi.awsize,
            S_AXI_HP0_0_awvalid => s_axi4_mosi.awvalid,

            S_AXI_HP0_0_bid    => open,
            S_AXI_HP0_0_bready => s_axi4_mosi.bready,
            S_AXI_HP0_0_bresp  => s_axi4_miso.bresp,
            S_AXI_HP0_0_bvalid => s_axi4_miso.bvalid,

            S_AXI_HP0_0_rdata  => s_axi4_miso.rdata,
            S_AXI_HP0_0_rid    => open,
            S_AXI_HP0_0_rlast  => s_axi4_miso.rlast,
            S_AXI_HP0_0_rready => s_axi4_mosi.rready,
            S_AXI_HP0_0_rresp  => s_axi4_miso.rresp,
            S_AXI_HP0_0_rvalid => s_axi4_miso.rvalid,

            S_AXI_HP0_0_wdata  => s_axi4_mosi.wdata,
            S_AXI_HP0_0_wid    => (others => '0'),
            S_AXI_HP0_0_wlast  => s_axi4_mosi.wlast,
            S_AXI_HP0_0_wready => s_axi4_miso.wready,
            S_AXI_HP0_0_wstrb  => s_axi4_mosi.wstrb,
            S_AXI_HP0_0_wvalid => s_axi4_mosi.wvalid,
            -- GPIO
            GPIO_I(63 downto 0) => s_gpio_i,
            GPIO_O(63 downto 0) => s_gpio_o,
            GPIO_T(63 downto 0) => s_gpio_t,
            -- SPI
            SPI0_CSN  => s_spi_csn,
            SPI0_MISO => s_spi_miso,
            SPI0_MOSI => s_spi_mosi,
            SPI0_SCLK => s_spi_clk
        );

end architecture rtl;
