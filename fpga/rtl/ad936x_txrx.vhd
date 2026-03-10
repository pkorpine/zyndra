--------------------------------------------------------------------------------
-- Title       : AD936x TXRX
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

library unisim;
use unisim.vcomponents.all;

entity ad936x_txrx is
    port (
        -- LVDS RX (AD9363 -> FPGA)
        rx_clk_p   : in    std_logic;
        rx_clk_n   : in    std_logic;
        rx_frame_p : in    std_logic;
        rx_frame_n : in    std_logic;
        rx_data_p  : in    std_logic_vector(5 downto 0);
        rx_data_n  : in    std_logic_vector(5 downto 0);
        -- LVDS TX (FPGA -> AD9363)
        tx_clk_p   : out   std_logic;
        tx_clk_n   : out   std_logic;
        tx_frame_p : out   std_logic;
        tx_frame_n : out   std_logic;
        tx_data_p  : out   std_logic_vector(5 downto 0);
        tx_data_n  : out   std_logic_vector(5 downto 0);
        -- Deserialized I/Q
        o_iq_clk   : out   std_logic;
        o_iq_i     : out   std_logic_vector(11 downto 0);
        o_iq_q     : out   std_logic_vector(11 downto 0);
        o_iq_valid : out   std_logic;
        -- debug signals
        o_dbg_iq_frame : out   std_logic
    );
end entity ad936x_txrx;

architecture rtl of ad936x_txrx is

    signal s_clk_data    : std_logic;
    signal s_clk_raw     : std_logic;
    signal s_frame_raw   : std_logic;
    signal s_data_raw    : std_logic_vector(5 downto 0);
    signal s_frame_rise  : std_logic;
    signal s_frame_fall  : std_logic; -- unused but IDDR needs both outputs
    signal s_data_rise   : std_logic_vector(5 downto 0);
    signal s_data_fall   : std_logic_vector(5 downto 0);
    signal s_tx_clk_oddr : std_logic;
    signal s_i_msb       : std_logic_vector(5 downto 0);
    signal s_q_msb       : std_logic_vector(5 downto 0);

    signal s_tx_frame   : std_logic;
    signal s_tx_iq_flag : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- TODO 2026-03-03:
    -- 1. Remove BUFG that adds unnecessary latency, and replace with BUFIO
    -- 2. Use IN_FIFO structure to get the data to the system clock domain
    -- -------------------------------------------------------------------------

    -- -------------------------------------------------------------------------
    -- RX clock: IBUFDS -> BUFG
    -- DATA_CLK is an MRCC-capable pin (IO_L12x), suitable for BUFG.
    -- -------------------------------------------------------------------------
    ibufds_clk_inst : component ibufds
        generic map (
            DIFF_TERM => TRUE, IBUF_LOW_PWR => FALSE
        )
        port map (
            I  => rx_clk_p,
            IB => rx_clk_n,
            O  => s_clk_raw
        );

    bufg_inst : component bufg
        port map (
            I => s_clk_raw,
            O => s_clk_data
        );

    o_iq_clk <= s_clk_data;

    -- -------------------------------------------------------------------------
    -- RX frame: IBUFDS -> IDDR
    -- -------------------------------------------------------------------------
    ibufds_frame_inst : component ibufds
        generic map (
            DIFF_TERM => TRUE, IBUF_LOW_PWR => FALSE
        )
        port map (
            I  => rx_frame_p,
            IB => rx_frame_n,
            O  => s_frame_raw
        );

    o_dbg_iq_frame <= s_frame_raw;

    iddr_frame_inst : component iddr
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",
            INIT_Q1      => '0',
            INIT_Q2      => '0',
            SRTYPE       => "SYNC"
        )
        port map (
            Q1 => s_frame_rise,
            Q2 => s_frame_fall,
            C  => s_clk_data,
            CE => '1',
            D  => s_frame_raw,
            R  => '0',
            S  => '0'
        );

    -- -------------------------------------------------------------------------
    -- RX data [5:0]: IBUFDS -> IDDR for each bit
    -- -------------------------------------------------------------------------

    gen_rx_data : for i in 0 to 5 generate

        ibufds_inst : component ibufds
            generic map (
                DIFF_TERM => TRUE, IBUF_LOW_PWR => FALSE
            )
            port map (
                I  => rx_data_p(i),
                IB => rx_data_n(i),
                O  => s_data_raw(i)
            );

        iddr_inst : component iddr
            generic map (
                DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",
                INIT_Q1      => '0',
                INIT_Q2      => '0',
                SRTYPE       => "SYNC"
            )
            port map (
                Q1 => s_data_rise(i),
                Q2 => s_data_fall(i),
                C  => s_clk_data,
                CE => '1',
                D  => s_data_raw(i),
                R  => '0',
                S  => '0'
            );

    end generate gen_rx_data;

    -- -------------------------------------------------------------------------
    -- Deserializer
    -- -------------------------------------------------------------------------
    process (s_clk_data) is
    begin
        if rising_edge(s_clk_data) then
            case s_frame_rise & s_frame_fall is

                when "11" => -- i_msb | q_msb

                    o_iq_valid          <= '0';
                    o_iq_i(11 downto 6) <= s_data_rise;
                    o_iq_q(11 downto 6) <= s_data_fall;

                when "00" => -- i_lsb | q_lsb

                    o_iq_valid         <= '1';
                    o_iq_i(5 downto 0) <= s_data_rise;
                    o_iq_q(5 downto 0) <= s_data_fall;

                when "10" => -- q_msb | i_lsb

                    o_iq_valid          <= '0';
                    o_iq_q(11 downto 6) <= s_data_rise;
                    o_iq_i(11 downto 6) <= s_i_msb;
                    o_iq_i(5 downto 0)  <= s_data_fall;

                when "01" => -- q_lsb | i_msb

                    o_iq_valid         <= '1';
                    o_iq_q(5 downto 0) <= s_data_rise;
                    s_i_msb            <= s_data_fall;

                when others =>

                    o_iq_valid <= '0';
            end case;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- TX feedback clock (FB_CLK)
    -- AD9363 requires FB_CLK to be driven. Use ODDR to generate a clean
    -- 50% duty-cycle output from s_clk_data (D1='1', D2='0').
    -- -------------------------------------------------------------------------
    oddr_txclk_inst : component oddr
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC"
        )
        port map (
            Q  => s_tx_clk_oddr,
            C  => s_clk_data,
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => '0',
            S  => '0'
        );

    obufds_txclk_inst : component obufds
        port map (
            I  => s_tx_clk_oddr,
            O  => tx_clk_p,
            OB => tx_clk_n
        );

    -- TX frame and data

    -- Generate IQ toggling
    process (s_clk_data) is
    begin
        if rising_edge(s_clk_data) then
            s_tx_iq_flag <= not s_tx_iq_flag;
        end if;
    end process;

    oddr_txframe_inst : component oddr
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC"
        )
        port map (
            Q  => s_tx_frame,
            C  => s_clk_data,
            CE => '1',
            D1 => s_tx_iq_flag,
            D2 => s_tx_iq_flag,
            R  => '0',
            S  => '0'
        );

    obufds_txframe_inst : component obufds
        port map (
            I  => s_tx_frame,
            O  => tx_frame_p,
            OB => tx_frame_n
        );

    gen_tx_data : for i in 0 to 5 generate

        obufds_inst : component obufds
            port map (
                I  => '0',
                O  => tx_data_p(i),
                OB => tx_data_n(i)
            );

    end generate gen_tx_data;

end architecture rtl;
