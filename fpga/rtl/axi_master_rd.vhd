--------------------------------------------------------------------------------
-- Title       : AXI Master Reader
-- Project     : Zyndra
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--   AXI4 burst read master. Reads from a DDR ringbuffer via AXI4 bursts and
--   outputs data as AXI-Stream.
--
-- History :
--  2026-03-31 PKo
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity axi_master_rd is
    generic (
        -- AXI burst length in beats (power of 2, 8-256).
        g_burst_len : positive := 16
    );
    port (
        i_aclk    : in    std_logic;
        i_aresetn : in    std_logic;
        i_enable  : in    std_logic; -- 1 = run, 0 = finish current burst then go standby

        -- Control / status
        i_base_addr : in    std_logic_vector(31 downto 0); -- page-aligned base
        i_buf_size  : in    std_logic_vector(31 downto 0); -- buffer length in bytes
        i_wr_ptr    : in    std_logic_vector(31 downto 0); -- write pointer from userspace
        o_rd_ptr    : out   std_logic_vector(31 downto 0); -- read offset relative to latched base

        -- AXI4 read address channel (AR)
        o_araddr  : out   std_logic_vector(31 downto 0);
        o_arlen   : out   std_logic_vector(7 downto 0);
        o_arsize  : out   std_logic_vector(2 downto 0);
        o_arburst : out   std_logic_vector(1 downto 0);
        o_arvalid : out   std_logic;
        i_arready : in    std_logic;

        -- AXI4 read data channel (R)
        i_rdata  : in    std_logic_vector(63 downto 0);
        i_rlast  : in    std_logic;
        i_rvalid : in    std_logic;
        i_rresp  : in    std_logic_vector(1 downto 0); -- ignored
        o_rready : out   std_logic;

        -- AXI-Stream sink (downstream data)
        o_tdata  : out   std_logic_vector(31 downto 0);
        o_tvalid : out   std_logic;
        i_tready : in    std_logic
    );
end entity axi_master_rd;

architecture rtl of axi_master_rd is

    -- Shallow FIFO for bursts
    constant c_fifo_depth : positive := 4 * g_burst_len;

    type t_state is (STANDBY, IDLE, AR_SEND, R_RECV);

    signal s_state   : t_state;
    signal s_rd_ptr  : unsigned(31 downto 0); -- byte offset from s_base_addr, 0-based
    signal s_ar_addr : unsigned(31 downto 0); -- registered AR address, computed in IDLE

    -- Base and size latched at the STANDBY→IDLE transition (i_enable rising).
    -- Using latched values ensures a register write mid-run cannot corrupt the
    -- in-progress pointer arithmetic or wrap calculation.
    signal s_base_addr : unsigned(31 downto 0);
    signal s_top_addr  : unsigned(31 downto 0);
    signal s_buf_size  : unsigned(31 downto 0);

    -- Burst size in bytes
    constant c_burst_bytes : unsigned(31 downto 0) := to_unsigned(g_burst_len * 8, 32);

    -- Data available in ring buffer (wr_ptr - rd_ptr, mod buf_size)
    signal s_data_avail : unsigned(31 downto 0);
    signal s_has_burst  : std_logic;

    -- Active-high reset for XPM FIFO
    signal s_rst : std_logic;

    -- 64→32 unpack toggle: '0' = output low half, '1' = output high half
    signal s_unpack_hi  : std_logic;
    signal s_fifo_empty : std_logic;

    -- Internal FIFO signals
    signal s_fifo_wr          : std_logic;
    signal s_fifo_rd          : std_logic;
    signal s_fifo_dout        : std_logic_vector(63 downto 0);
    signal s_fifo_full        : std_logic;
    signal s_fifo_wr_rst_busy : std_logic;
    signal s_fifo_prog_full   : std_logic;

begin

    -- -------------------------------------------------------------------------
    -- Fixed AXI4 burst attributes (never change)
    -- -------------------------------------------------------------------------
    o_arlen   <= std_logic_vector(to_unsigned(g_burst_len - 1, 8));
    o_arsize  <= "011"; -- 8 bytes per beat
    o_arburst <= "01";  -- INCR

    -- -------------------------------------------------------------------------
    -- AXI read data → FIFO write
    -- -------------------------------------------------------------------------
    s_fifo_wr <= i_rvalid and o_rready;

    -- -------------------------------------------------------------------------
    -- Combinatorial outputs
    -- -------------------------------------------------------------------------

    o_araddr  <= std_logic_vector(s_ar_addr);
    o_arvalid <= '1' when s_state = AR_SEND else
                 '0';
    o_rd_ptr  <= std_logic_vector(s_rd_ptr);

    -- Accept read data while receiving a burst.
    o_rready <= '1' when s_state = R_RECV else
                '0';

    -- Ring buffer data availability: distance from rd_ptr to wr_ptr
    s_data_avail <= unsigned(i_wr_ptr) - s_rd_ptr when unsigned(i_wr_ptr) >= s_rd_ptr else
                    s_buf_size - s_rd_ptr + unsigned(i_wr_ptr);
    s_has_burst  <= '1' when s_data_avail >= c_burst_bytes else
                    '0';

    -- -------------------------------------------------------------------------
    -- 64→32 unpack: FIFO FWFT output to AXI-Stream source
    -- -------------------------------------------------------------------------
    -- s_unpack_hi='0': output low half first, '1': output high half
    o_tdata  <= s_fifo_dout(31 downto 0) when s_unpack_hi = '0' else
                s_fifo_dout(63 downto 32);
    o_tvalid <= not s_fifo_empty;

    -- Advance FIFO after the high half is consumed.
    s_fifo_rd <= not s_fifo_empty and i_tready and s_unpack_hi;

    -- -------------------------------------------------------------------------
    -- State machine
    -- -------------------------------------------------------------------------
    proc_sm : process (i_aclk) is
    begin
        if rising_edge(i_aclk) then
            case s_state is

                when STANDBY =>

                    if i_enable then
                        s_base_addr <= unsigned(i_base_addr);
                        s_ar_addr   <= unsigned(i_base_addr);
                        s_top_addr  <= unsigned(i_base_addr) + unsigned(i_buf_size);
                        s_buf_size  <= unsigned(i_buf_size);
                        s_state     <= IDLE;
                    end if;

                when IDLE =>

                    if not i_enable then
                        s_state <= STANDBY;
                    elsif s_fifo_prog_full = '0' and s_has_burst = '1' then
                        -- FIFO has room and userspace has written enough data
                        s_state <= AR_SEND;
                    end if;

                when AR_SEND =>

                    if i_arready then
                        s_state <= R_RECV;
                        -- Pre-calculate address for the next burst
                        s_ar_addr <= s_ar_addr + g_burst_len * 8;
                    end if;

                when R_RECV =>

                    if i_rvalid and i_rlast then
                        -- Check for ringbuffer wrap, s_buf_size is always multiple of 8*g_burst_len
                        if s_ar_addr >= s_top_addr then
                            s_ar_addr <= s_base_addr;
                        end if;

                        if s_fifo_prog_full = '0' and s_has_burst = '1' then
                            -- FIFO has room and data available
                            s_state <= AR_SEND;
                        else
                            -- Wait for FIFO to drain or more data from userspace
                            s_state <= IDLE;
                        end if;
                    end if;

            end case;

            if not i_aresetn then
                s_state     <= STANDBY;
                s_ar_addr   <= (others => '0');
                s_base_addr <= (others => '0');
                s_buf_size  <= (others => '0');
                s_top_addr  <= (others => '0');
            end if;
        end if;
    end process;

    -- Toggle between low and high halves of FIFO output
    process (i_aclk) is
    begin
        if rising_edge(i_aclk) then
            if not i_aresetn then
                s_unpack_hi <= '0';
            elsif not s_fifo_empty and i_tready then
                s_unpack_hi <= not s_unpack_hi;
            end if;
        end if;
    end process;

    -- Track read pointer: advance by one burst worth of bytes per completed burst
    process (i_aclk) is
        variable v_next : unsigned(s_rd_ptr'range);
    begin
        if rising_edge(i_aclk) then
            if not i_aresetn then
                s_rd_ptr <= (others => '0');
            elsif s_state = STANDBY and i_enable = '1' then
                s_rd_ptr <= (others => '0');
            elsif s_state = R_RECV and i_rvalid = '1' and i_rlast = '1' then
                v_next := s_rd_ptr + g_burst_len * 8;
                if v_next >= s_buf_size then
                    s_rd_ptr <= (others => '0');
                else
                    s_rd_ptr <= v_next;
                end if;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- Shallow synchronous FIFO (distributed RAM, single-clock domain)
    -- USE_ADV_FEATURES bit 1 enables prog_full; all other advanced ports unused.
    -- -------------------------------------------------------------------------
    s_rst <= not i_aresetn;

    xpm_fifo_sync_inst : component xpm_fifo_sync
        generic map (
            CASCADE_HEIGHT      => 0,
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "distributed",
            FIFO_READ_LATENCY   => 0,
            FIFO_WRITE_DEPTH    => c_fifo_depth,
            FULL_RESET_VALUE    => 1,
            PROG_EMPTY_THRESH   => 10,
            PROG_FULL_THRESH    => 3 * g_burst_len,
            RD_DATA_COUNT_WIDTH => 1,
            READ_DATA_WIDTH     => 64,
            READ_MODE           => "fwft",
            SIM_ASSERT_CHK      => 0,
            USE_ADV_FEATURES    => "0002",
            WAKEUP_TIME         => 0,
            WRITE_DATA_WIDTH    => 64,
            WR_DATA_COUNT_WIDTH => 1
        )
        port map (
            injectdbiterr => '0',
            injectsbiterr => '0',
            sbiterr       => open,
            dbiterr       => open,
            sleep         => '0',

            wr_clk        => i_aclk,
            rst           => s_rst,
            wr_en         => s_fifo_wr,
            wr_ack        => open,
            din           => i_rdata,
            almost_full   => open,
            full          => s_fifo_full,
            overflow      => open,
            prog_full     => s_fifo_prog_full,
            wr_data_count => open,
            wr_rst_busy   => s_fifo_wr_rst_busy,

            rd_en         => s_fifo_rd,
            data_valid    => open,
            dout          => s_fifo_dout,
            almost_empty  => open,
            empty         => s_fifo_empty,
            underflow     => open,
            rd_data_count => open,
            prog_empty    => open,
            rd_rst_busy   => open
        );

end architecture rtl;
