--------------------------------------------------------------------------------
-- Title       : FPGA Core
-- Project     : Zyndra
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--   Design core: everything except Zynq PS block design and pin-level
--   passthrough (DDR, FIXED_IO, SPI, AD9361 control GPIOs).
--   Instantiated by top.vhd (synthesis) and tb_core.vhd (simulation).
--
-- History :
--  2026-04-01 PKo  Split from top.vhd for simulation support
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use work.ad936x_axi_pkg.all;

entity core is
    port (
        -- AXI clock/reset (from Zynq PS)
        i_axi_clk  : in    std_logic;
        i_axi_rstn : in    std_logic;
        -- AXI4-Lite slave (register interface from PS)
        i_axil : in    t_axi4l_mosi;
        o_axil : out   t_axi4l_miso;
        -- AXI4 master (DMA to DDR via HP port)
        o_axi4 : out   t_axi4_mosi;
        i_axi4 : in    t_axi4_miso;
        -- GPIO to Zynq EMIO (IQ readback)
        o_gpio_i : out   std_logic_vector(63 downto 0);
        -- AD9363 LVDS RX (AD9363 -> FPGA)
        rx_clk_in_p   : in    std_logic;
        rx_clk_in_n   : in    std_logic;
        rx_frame_in_p : in    std_logic;
        rx_frame_in_n : in    std_logic;
        rx_data_in_p  : in    std_logic_vector(5 downto 0);
        rx_data_in_n  : in    std_logic_vector(5 downto 0);
        -- AD9363 LVDS TX (FPGA -> AD9363)
        tx_clk_out_p   : out   std_logic;
        tx_clk_out_n   : out   std_logic;
        tx_frame_out_p : out   std_logic;
        tx_frame_out_n : out   std_logic;
        tx_data_out_p  : out   std_logic_vector(5 downto 0);
        tx_data_out_n  : out   std_logic_vector(5 downto 0);
        -- Ext debug header
        ext_1v8_io1_p : out   std_logic;
        ext_1v8_io1_n : out   std_logic;
        ext_1v8_io3_p : out   std_logic;
        ext_1v8_io3_n : out   std_logic;
        ext_1v8_io5_p : out   std_logic;
        ext_1v8_io5_n : out   std_logic;
        ext_1v8_io7_p : out   std_logic;
        ext_1v8_io7_n : out   std_logic
    );
end entity core;

architecture rtl of core is

    signal s_iq_clk         : std_logic;
    signal s_dbg_iq_frame   : std_logic;
    signal s_rx_iq_i        : std_logic_vector(11 downto 0);
    signal s_rx_iq_q        : std_logic_vector(11 downto 0);
    signal s_rx_iq_valid    : std_logic;
    signal s_tx_iq_i        : std_logic_vector(11 downto 0);
    signal s_tx_iq_q        : std_logic_vector(11 downto 0);
    signal s_tx_iq_valid    : std_logic;
    signal s_tx_iq_rdy      : std_logic;
    signal s_tx_iq_underrun : std_logic;

begin

    -- GPIO_I: route IQ samples to EMIO for PS readback
    -- EMIO[4:15]  = I[11:0]  (0xE000A068 bits[15:4])
    -- EMIO[16:27] = Q[11:0]  (0xE000A068 bits[27:16])
    o_gpio_i(3 downto 0)   <= (others => '0');
    o_gpio_i(15 downto 4)  <= s_rx_iq_i;
    o_gpio_i(27 downto 16) <= s_rx_iq_q;
    o_gpio_i(63 downto 28) <= (others => '0');

    gen_debug_spi : if false generate
        ext_1v8_io1_p <= '0';
        ext_1v8_io1_n <= '0';
        ext_1v8_io3_p <= '0';
        ext_1v8_io3_n <= '0';
        ext_1v8_io5_p <= '0';
        ext_1v8_io5_n <= '0';
        ext_1v8_io7_p <= '0';
        ext_1v8_io7_n <= '0';
    end generate gen_debug_spi;

    gen_debug_databus : if true generate
        ext_1v8_io1_p <= s_iq_clk;
        ext_1v8_io1_n <= s_rx_iq_valid;
        ext_1v8_io3_p <= s_rx_iq_i(0);
        ext_1v8_io3_n <= s_rx_iq_q(0);
        ext_1v8_io5_p <= '0';
        ext_1v8_io5_n <= '0';
        ext_1v8_io7_p <= '0';
        ext_1v8_io7_n <= '0';
    end generate gen_debug_databus;

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
            o_clk          => s_iq_clk,
            o_rx_i         => s_rx_iq_i,
            o_rx_q         => s_rx_iq_q,
            o_rx_valid     => s_rx_iq_valid,
            i_tx_i         => s_tx_iq_i,
            i_tx_q         => s_tx_iq_q,
            i_tx_valid     => s_tx_iq_valid,
            o_tx_rdy       => s_tx_iq_rdy,
            o_tx_underrun  => s_tx_iq_underrun,
            o_dbg_rx_frame => s_dbg_iq_frame
        );

    -- AD936x AXI register + DMA interface
    ad936x_axi_inst : entity work.ad936x_axi
        port map (
            -- AXI4-Lite
            aclk    => i_axi_clk,
            aresetn => i_axi_rstn,
            awvalid => i_axil.awvalid,
            awaddr  => i_axil.awaddr,
            awprot  => i_axil.awprot,
            awready => o_axil.awready,
            wvalid  => i_axil.wvalid,
            wdata   => i_axil.wdata,
            wready  => o_axil.wready,
            bvalid  => o_axil.bvalid,
            bready  => i_axil.bready,
            bresp   => o_axil.bresp,
            arvalid => i_axil.arvalid,
            arready => o_axil.arready,
            araddr  => i_axil.araddr,
            arprot  => i_axil.arprot,
            rvalid  => o_axil.rvalid,
            rready  => i_axil.rready,
            rdata   => o_axil.rdata,
            rresp   => o_axil.rresp,
            -- AXI4 master
            o_awaddr  => o_axi4.awaddr,
            o_awlen   => o_axi4.awlen,
            o_awsize  => o_axi4.awsize,
            o_awburst => o_axi4.awburst,
            o_awvalid => o_axi4.awvalid,
            i_awready => i_axi4.awready,
            o_wdata   => o_axi4.wdata,
            o_wstrb   => o_axi4.wstrb,
            o_wlast   => o_axi4.wlast,
            o_wvalid  => o_axi4.wvalid,
            i_wready  => i_axi4.wready,
            i_bvalid  => i_axi4.bvalid,
            o_bready  => o_axi4.bready,
            i_bresp   => i_axi4.bresp,
            o_araddr  => o_axi4.araddr,
            o_arlen   => o_axi4.arlen,
            o_arsize  => o_axi4.arsize,
            o_arburst => o_axi4.arburst,
            o_arvalid => o_axi4.arvalid,
            i_arready => i_axi4.arready,
            i_rdata   => i_axi4.rdata,
            i_rlast   => i_axi4.rlast,
            i_rvalid  => i_axi4.rvalid,
            i_rresp   => i_axi4.rresp,
            o_rready  => o_axi4.rready,
            -- IQ
            i_iq_clk         => s_iq_clk,
            i_rx_iq_valid    => s_rx_iq_valid,
            i_rx_iq_i        => s_rx_iq_i,
            i_rx_iq_q        => s_rx_iq_q,
            o_tx_iq_i        => s_tx_iq_i,
            o_tx_iq_q        => s_tx_iq_q,
            o_tx_iq_valid    => s_tx_iq_valid,
            i_tx_iq_rdy      => s_tx_iq_rdy,
            i_tx_iq_underrun => s_tx_iq_underrun
        );

end architecture rtl;
