--------------------------------------------------------------------------------
-- Title       : AD936x TXRX
-- Project     : Zyndra
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--   AD936x LVDS transceiver for 1R1T mode. Handles IBUFDS/OBUFDS, IDDR/ODDR
--   primitives, and IQ (de)serialization on the 2x DATA_CLK.
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
        -- Clock output (recovered from AD9363 DATA_CLK)
        o_clk : out   std_logic;
        -- RX IQ output (AD9363 -> system)
        o_rx_i     : out   std_logic_vector(11 downto 0);
        o_rx_q     : out   std_logic_vector(11 downto 0);
        o_rx_valid : out   std_logic;
        -- TX IQ input (system -> AD9363)
        i_tx_i        : in    std_logic_vector(11 downto 0);
        i_tx_q        : in    std_logic_vector(11 downto 0);
        i_tx_valid    : in    std_logic;
        o_tx_rdy      : out   std_logic;
        o_tx_underrun : out   std_logic;
        -- Debug
        o_dbg_rx_frame : out   std_logic
    );
end entity ad936x_txrx;

architecture rtl of ad936x_txrx is

    signal s_clk_data : std_logic;
    signal s_clk_raw  : std_logic;

    -- RX Path
    signal s_rx_frame_raw  : std_logic;
    signal s_rx_frame_rise : std_logic;
    signal s_rx_frame_fall : std_logic;
    signal s_rx_data_rise  : std_logic_vector(5 downto 0);
    signal s_rx_data_fall  : std_logic_vector(5 downto 0);
    signal s_rx_i_msb      : std_logic_vector(5 downto 0);
    signal s_rx_q_msb      : std_logic_vector(5 downto 0);

    -- TX Path
    signal s_tx_clk_oddr   : std_logic;
    signal s_tx_iq_flag    : std_logic                     := '0';
    signal s_tx_frame      : std_logic;
    signal s_tx_data_rise  : std_logic_vector(5 downto 0);
    signal s_tx_data_fall  : std_logic_vector(5 downto 0);
    signal s_tx_frame_rise : std_logic;
    signal s_tx_frame_fall : std_logic;
    signal s_tx_i_lat      : std_logic_vector(11 downto 0) := (others => '0');
    signal s_tx_q_lat      : std_logic_vector(11 downto 0) := (others => '0');

begin

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

    o_clk <= s_clk_data;

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
            O  => s_rx_frame_raw
        );

    o_dbg_rx_frame <= s_rx_frame_raw;

    iddr_frame_inst : component iddr
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",
            INIT_Q1      => '0',
            INIT_Q2      => '0',
            SRTYPE       => "SYNC"
        )
        port map (
            Q1 => s_rx_frame_rise,
            Q2 => s_rx_frame_fall,
            C  => s_clk_data,
            CE => '1',
            D  => s_rx_frame_raw,
            R  => '0',
            S  => '0'
        );

    -- -------------------------------------------------------------------------
    -- RX data [5:0]: IBUFDS -> IDDR for each bit
    -- -------------------------------------------------------------------------

    gen_rx_data : for i in 0 to 5 generate
        signal sg_data : std_logic;
    begin

        ibufds_inst : component ibufds
            generic map (
                DIFF_TERM => TRUE, IBUF_LOW_PWR => FALSE
            )
            port map (
                I  => rx_data_p(i),
                IB => rx_data_n(i),
                O  => sg_data
            );

        iddr_inst : component iddr
            generic map (
                DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",
                INIT_Q1      => '0',
                INIT_Q2      => '0',
                SRTYPE       => "SYNC"
            )
            port map (
                Q1 => s_rx_data_rise(i),
                Q2 => s_rx_data_fall(i),
                C  => s_clk_data,
                CE => '1',
                D  => sg_data,
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
            case s_rx_frame_rise & s_rx_frame_fall is

                when "11" => -- i_msb | q_msb

                    o_rx_valid          <= '0';
                    o_rx_i(11 downto 6) <= s_rx_data_rise;
                    o_rx_q(11 downto 6) <= s_rx_data_fall;

                when "00" => -- i_lsb | q_lsb

                    o_rx_valid         <= '1';
                    o_rx_i(5 downto 0) <= s_rx_data_rise;
                    o_rx_q(5 downto 0) <= s_rx_data_fall;

                when "10" => -- q_msb | i_lsb

                    o_rx_valid          <= '0';
                    o_rx_q(11 downto 6) <= s_rx_data_rise;
                    o_rx_i(11 downto 6) <= s_rx_i_msb;
                    o_rx_i(5 downto 0)  <= s_rx_data_fall;

                when "01" => -- q_lsb | i_msb

                    o_rx_valid         <= '1';
                    o_rx_q(5 downto 0) <= s_rx_data_rise;
                    s_rx_i_msb         <= s_rx_data_fall;

                when others =>

                    o_rx_valid <= '0';
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

    -- TX IQ serializer
    -- MSB phase (flag=0): accept new sample if valid, else repeat last and
    --                      pulse underrun. Output I/Q MSBs with frame='1'.
    -- LSB phase (flag=1): output I/Q LSBs from latched data, frame='0'.
    process (s_clk_data) is
    begin
        if rising_edge(s_clk_data) then
            s_tx_iq_flag  <= not s_tx_iq_flag;
            o_tx_underrun <= '0';

            if s_tx_iq_flag = '0' then
                -- MSB phase: latch new sample or repeat last
                if i_tx_valid = '1' then
                    s_tx_i_lat     <= i_tx_i;
                    s_tx_q_lat     <= i_tx_q;
                    s_tx_data_rise <= i_tx_i(11 downto 6);
                    s_tx_data_fall <= i_tx_q(11 downto 6);
                else
                    o_tx_underrun  <= '1';
                    s_tx_data_rise <= s_tx_i_lat(11 downto 6);
                    s_tx_data_fall <= s_tx_q_lat(11 downto 6);
                end if;

                s_tx_frame_rise <= '1';
                s_tx_frame_fall <= '1';
            else
                -- LSB phase: output from latched registers
                s_tx_data_rise  <= s_tx_i_lat(5 downto 0);
                s_tx_data_fall  <= s_tx_q_lat(5 downto 0);
                s_tx_frame_rise <= '0';
                s_tx_frame_fall <= '0';
            end if;
        end if;
    end process;

    o_tx_rdy <= not s_tx_iq_flag;

    oddr_txframe_inst : component oddr
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC"
        )
        port map (
            Q  => s_tx_frame,
            C  => s_clk_data,
            CE => '1',
            D1 => s_tx_frame_rise,
            D2 => s_tx_frame_fall,
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
        signal sg_data : std_logic;
    begin

        oddr_inst : component oddr
            generic map (
                DDR_CLK_EDGE => "SAME_EDGE", INIT => '0', SRTYPE => "SYNC"
            )
            port map (
                Q  => sg_data,
                C  => s_clk_data,
                CE => '1',
                D1 => s_tx_data_rise(i),
                D2 => s_tx_data_fall(i),
                R  => '0',
                S  => '0'
            );

        obufds_inst : component obufds
            port map (
                I  => sg_data,
                O  => tx_data_p(i),
                OB => tx_data_n(i)
            );

    end generate gen_tx_data;

end architecture rtl;
