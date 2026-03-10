--------------------------------------------------------------------------------
-- Title       : FPGA Top
-- Project     :
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--
-- History :
--  2026-03-09 PKo
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

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

    signal s_gpio_i   : std_logic_vector(63 downto 0);
    signal s_iq_i     : std_logic_vector(11 downto 0);
    signal s_iq_q     : std_logic_vector(11 downto 0);
    signal s_iq_valid : std_logic;
    signal s_gpio_o   : std_logic_vector(63 downto 0);
    signal s_gpio_t   : std_logic_vector(63 downto 0);

    signal s_spi_csn  : std_logic;
    signal s_spi_clk  : std_logic;
    signal s_spi_mosi : std_logic;
    signal s_spi_miso : std_logic;

    signal s_iq_clk       : std_logic;
    signal s_dbg_iq_frame : std_logic;

    -- AXI Slave
    signal s_axi_clk     : std_logic;
    signal s_axi_rstn    : std_logic;
    signal s_axi_araddr  : std_logic_vector(30 downto 0);
    signal s_axi_arprot  : std_logic_vector(2 downto 0);
    signal s_axi_arready : std_logic;
    signal s_axi_arvalid : std_logic;
    signal s_axi_awaddr  : std_logic_vector(30 downto 0);
    signal s_axi_awprot  : std_logic_vector(2 downto 0);
    signal s_axi_awready : std_logic;
    signal s_axi_awvalid : std_logic;
    signal s_axi_bready  : std_logic;
    signal s_axi_bresp   : std_logic_vector(1 downto 0);
    signal s_axi_bvalid  : std_logic;
    signal s_axi_rdata   : std_logic_vector(31 downto 0);
    signal s_axi_rready  : std_logic;
    signal s_axi_rresp   : std_logic_vector(1 downto 0);
    signal s_axi_rvalid  : std_logic;
    signal s_axi_wdata   : std_logic_vector(31 downto 0);
    signal s_axi_wready  : std_logic;
    signal s_axi_wstrb   : std_logic_vector(3 downto 0);
    signal s_axi_wvalid  : std_logic;

    -- AXI Master
    signal s_axim_awaddr  : std_logic_vector(31 downto 0);
    signal s_axim_awlen   : std_logic_vector(7 downto 0);
    signal s_axim_awsize  : std_logic_vector(2 downto 0);
    signal s_axim_awburst : std_logic_vector(1 downto 0);
    signal s_axim_awvalid : std_logic;
    signal s_axim_awready : std_logic;

    -- AXI4 write data channel (W)
    signal s_axim_wdata  : std_logic_vector(63 downto 0);
    signal s_axim_wstrb  : std_logic_vector(7 downto 0);
    signal s_axim_wlast  : std_logic;
    signal s_axim_wvalid : std_logic;
    signal s_axim_wready : std_logic;

    -- AXI4 write response channel (B)
    signal s_axim_bvalid : std_logic;
    signal s_axim_bready : std_logic;
    signal s_axim_bresp  : std_logic_vector(1 downto 0);

    -- AXI-Stream sink (upstream data)
    signal s_axim_tdata  : std_logic_vector(31 downto 0);
    signal s_axim_tvalid : std_logic;
    signal s_axim_tready : std_logic;

begin

    -- Route IQ samples into EMIO GPIO_I so Linux can read via /dev/mem.
    -- For EMIO, GPIO_I and GPIO_O are separate unidirectional PS7 ports.
    -- DATA_RO (0xE000A068) always reads GPIO_I regardless of direction setting,
    -- so all 64 bits are readable. We leave [3:0] as zero to avoid unexpected
    -- readback on the RESETB/ENABLE/TXNRX/EN_AGC bits (cosmetic only).
    -- EMIO[4:15]  = I[11:0]  (0xE000A068 bits[15:4])
    -- EMIO[16:27] = Q[11:0]  (0xE000A068 bits[27:16])
    s_gpio_i(3 downto 0)   <= (others => '0');
    s_gpio_i(15 downto 4)  <= s_iq_i;
    s_gpio_i(27 downto 16) <= s_iq_q;
    s_gpio_i(63 downto 28) <= (others => '0');

    gen_debug_spi : if false generate
        -- Mirror SPI to the ext header
        ext_1v8_io1_p <= s_spi_csn;
        ext_1v8_io1_n <= s_spi_clk;
        ext_1v8_io3_p <= s_spi_mosi;
        ext_1v8_io3_n <= s_spi_miso;
        ext_1v8_io5_p <= '0';
        ext_1v8_io5_n <= '0';
        ext_1v8_io7_p <= '0';
        ext_1v8_io7_n <= '0';
    end generate gen_debug_spi;

    gen_debug_databus : if true generate
        -- Mirror databus signals to the ext header
        ext_1v8_io1_p <= s_iq_clk;
        ext_1v8_io1_n <= s_iq_valid;
        ext_1v8_io3_p <= s_iq_i(0);
        ext_1v8_io3_n <= s_iq_q(0);
        ext_1v8_io5_p <= '0';
        ext_1v8_io5_n <= '0';
        ext_1v8_io7_p <= '0';
        ext_1v8_io7_n <= '0';
    end generate gen_debug_databus;

    -- AD9361 control
    gpio_sync   <= '0'; -- ??
    gpio_resetb <= s_gpio_o(0);
    enable      <= s_gpio_o(1);
    txnrx       <= s_gpio_o(2);
    gpio_en_agc <= s_gpio_o(3);

    spi_csn    <= s_spi_csn;
    spi_clk    <= s_spi_clk;
    spi_mosi   <= s_spi_mosi;
    s_spi_miso <= spi_miso;

    -- AD9363 LVDS interface
    ad936x_txrx_inst : entity work.ad936x_txrx
        port map (
            rx_clk_p       => rx_clk_in_p,
            rx_clk_n       => rx_clk_in_n,
            rx_frame_p     => rx_frame_in_p,
            rx_frame_n     => rx_frame_in_n,
            rx_data_p      => rx_data_in_p,
            rx_data_n      => rx_data_in_n,
            tx_clk_p       => tx_clk_out_p,
            tx_clk_n       => tx_clk_out_n,
            tx_frame_p     => tx_frame_out_p,
            tx_frame_n     => tx_frame_out_n,
            tx_data_p      => tx_data_out_p,
            tx_data_n      => tx_data_out_n,
            o_iq_clk       => s_iq_clk,
            o_iq_i         => s_iq_i,
            o_iq_q         => s_iq_q,
            o_iq_valid     => s_iq_valid,
            o_dbg_iq_frame => s_dbg_iq_frame
        );

    -- AD9363 AXI interface
    ad936x_axi_inst : entity work.ad936x_axi
        port map (
            -- AXI4-Lite Bus
            ACLK    => s_axi_clk,
            ARESETn => s_axi_rstn,
            -- Write
            AWVALID => s_axi_awvalid,
            AWADDR  => s_axi_awaddr,
            AWPROT  => s_axi_awprot,
            AWREADY => s_axi_awready,
            WVALID  => s_axi_wvalid,
            WDATA   => s_axi_wdata,
            WREADY  => s_axi_wready,
            BVALID  => s_axi_bvalid,
            BREADY  => s_axi_bready,
            BRESP   => s_axi_bresp,
            -- Read
            ARVALID => s_axi_arvalid,
            ARREADY => s_axi_arready,
            ARADDR  => s_axi_araddr,
            ARPROT  => s_axi_arprot,
            RVALID  => s_axi_rvalid,
            RREADY  => s_axi_rready,
            RDATA   => s_axi_rdata,
            RRESP   => s_axi_rresp,
            -- AXI Master
            o_awaddr  => s_axim_awaddr,
            o_awlen   => s_axim_awlen,
            o_awsize  => s_axim_awsize,
            o_awburst => s_axim_awburst,
            o_awvalid => s_axim_awvalid,
            i_awready => s_axim_awready,

            -- AXI4 write data channel (W)
            o_wdata  => s_axim_wdata,
            o_wstrb  => s_axim_wstrb,
            o_wlast  => s_axim_wlast,
            o_wvalid => s_axim_wvalid,
            i_wready => s_axim_wready,

            -- AXI4 write response channel (B)
            i_bvalid => s_axim_bvalid,
            o_bready => s_axim_bready,
            i_bresp  => s_axim_bresp,

            -- AXI-Stream sink (upstream data)
            i_tdata  => s_axim_tdata,
            i_tvalid => s_axim_tvalid,
            o_tready => s_axim_tready,
            --
            i_iq_clk   => s_iq_clk,
            i_iq_valid => s_iq_valid,
            i_iq_i     => s_iq_i,
            i_iq_q     => s_iq_q
        );

    -- PS
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
            -- AXI Slave
            M00_AXI_0_araddr  => s_axi_araddr,
            M00_AXI_0_arprot  => s_axi_arprot,
            M00_AXI_0_arready => s_axi_arready,
            M00_AXI_0_arvalid => s_axi_arvalid,
            M00_AXI_0_awaddr  => s_axi_awaddr,
            M00_AXI_0_awprot  => s_axi_awprot,
            M00_AXI_0_awready => s_axi_awready,
            M00_AXI_0_awvalid => s_axi_awvalid,
            M00_AXI_0_bready  => s_axi_bready,
            M00_AXI_0_bresp   => s_axi_bresp,
            M00_AXI_0_bvalid  => s_axi_bvalid,
            M00_AXI_0_rdata   => s_axi_rdata,
            M00_AXI_0_rready  => s_axi_rready,
            M00_AXI_0_rresp   => s_axi_rresp,
            M00_AXI_0_rvalid  => s_axi_rvalid,
            M00_AXI_0_wdata   => s_axi_wdata,
            M00_AXI_0_wready  => s_axi_wready,
            M00_AXI_0_wstrb   => s_axi_wstrb,
            M00_AXI_0_wvalid  => s_axi_wvalid,
            AXI_CLK           => s_axi_clk,
            AXI_RSTN(0)       => s_axi_rstn,
            -- AXI3 Master
            S_AXI_HP0_0_araddr  => (others => '0'),
            S_AXI_HP0_0_arburst => (others => '0'),
            S_AXI_HP0_0_arcache => (others => '0'),
            S_AXI_HP0_0_arid    => (others => '0'),
            S_AXI_HP0_0_arlen   => (others => '0'),
            S_AXI_HP0_0_arlock  => (others => '0'),
            S_AXI_HP0_0_arprot  => (others => '0'),
            S_AXI_HP0_0_arqos   => (others => '0'),
            S_AXI_HP0_0_arready => open,
            S_AXI_HP0_0_arsize  => (others => '0'),
            S_AXI_HP0_0_arvalid => '0',

            S_AXI_HP0_0_awaddr  => s_axim_awaddr,
            S_AXI_HP0_0_awburst => s_axim_awburst,
            S_AXI_HP0_0_awcache => (others => '0'),
            S_AXI_HP0_0_awid    => (others => '0'),
            S_AXI_HP0_0_awlen   => s_axim_awlen(3 downto 0),
            S_AXI_HP0_0_awlock  => (others => '0'),
            S_AXI_HP0_0_awprot  => (others => '0'),
            S_AXI_HP0_0_awqos   => (others => '0'),
            S_AXI_HP0_0_awready => s_axim_awready,
            S_AXI_HP0_0_awsize  => s_axim_awsize,
            S_AXI_HP0_0_awvalid => s_axim_awvalid,

            S_AXI_HP0_0_bid    => open,
            S_AXI_HP0_0_bready => s_axim_bready,
            S_AXI_HP0_0_bresp  => s_axim_bresp,
            S_AXI_HP0_0_bvalid => s_axim_bvalid,

            S_AXI_HP0_0_rdata  => open,
            S_AXI_HP0_0_rid    => open,
            S_AXI_HP0_0_rlast  => open,
            S_AXI_HP0_0_rready => '0',
            S_AXI_HP0_0_rresp  => open,
            S_AXI_HP0_0_rvalid => open,

            S_AXI_HP0_0_wdata  => s_axim_wdata,
            S_AXI_HP0_0_wid    => (others => '0'),
            S_AXI_HP0_0_wlast  => s_axim_wlast,
            S_AXI_HP0_0_wready => s_axim_wready,
            S_AXI_HP0_0_wstrb  => s_axim_wstrb,
            S_AXI_HP0_0_wvalid => s_axim_wvalid,
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
