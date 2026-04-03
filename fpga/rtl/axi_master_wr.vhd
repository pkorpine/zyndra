--------------------------------------------------------------------------------
-- Title       : AXI Master Writer
-- Project     : Zyndra
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--   AXI4 burst write master. Accepts AXI-Stream input, buffers in an internal
--   FIFO, and writes to DDR via AXI4 bursts into a ringbuffer.
--
-- History :
--  2026-03-09 PKo
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity axi_master_wr is
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
        o_wr_ptr    : out   std_logic_vector(31 downto 0); -- write offset relative to latched base

        -- AXI4 write address channel (AW)
        o_awaddr  : out   std_logic_vector(31 downto 0);
        o_awlen   : out   std_logic_vector(7 downto 0);
        o_awsize  : out   std_logic_vector(2 downto 0);
        o_awburst : out   std_logic_vector(1 downto 0);
        o_awvalid : out   std_logic;
        i_awready : in    std_logic;

        -- AXI4 write data channel (W)
        o_wdata  : out   std_logic_vector(63 downto 0);
        o_wstrb  : out   std_logic_vector(7 downto 0);
        o_wlast  : out   std_logic;
        o_wvalid : out   std_logic;
        i_wready : in    std_logic;

        -- AXI4 write response channel (B)
        i_bvalid : in    std_logic;
        o_bready : out   std_logic;
        i_bresp  : in    std_logic_vector(1 downto 0); -- ignored

        -- AXI-Stream sink (upstream data)
        i_tdata  : in    std_logic_vector(31 downto 0);
        i_tvalid : in    std_logic;
        o_tready : out   std_logic
    );
end entity axi_master_wr;

architecture rtl of axi_master_wr is

    -- Shallow FIFO for bursts
    constant c_fifo_depth : positive := 4 * g_burst_len;

    type t_state is (STANDBY, IDLE, AW_SEND, W_SEND, WAIT_OUTSTANDING);

    signal s_state    : t_state;
    signal s_beat_cnt : integer range 0 to g_burst_len - 1;
    signal s_wr_ptr   : unsigned(31 downto 0); -- byte offset from s_base_addr, 0-based
    signal s_aw_addr  : unsigned(31 downto 0); -- registered AW address, computed in IDLE

    -- Base and size latched at the STANDBY→IDLE transition (i_enable rising).
    -- Using latched values ensures a register write mid-run cannot corrupt the
    -- in-progress pointer arithmetic or wrap calculation.
    signal s_base_addr : unsigned(31 downto 0);
    signal s_top_addr  : unsigned(31 downto 0);
    signal s_buf_size  : unsigned(31 downto 0);

    -- Active-high reset for XPM FIFO
    signal s_rst : std_logic;

    signal s_prev_tvalid : std_logic;
    signal s_prev_tdata  : std_logic_vector(31 downto 0);

    -- Keep track of outstandings transactions
    signal s_pending_cnt : unsigned(3 downto 0); -- HP has cap of 8

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
    o_awlen   <= std_logic_vector(to_unsigned(g_burst_len - 1, 8));
    o_awsize  <= "011";  -- 8 bytes per beat
    o_awburst <= "01";   -- INCR
    o_wstrb   <= 8x"FF"; -- all byte lanes active

    -- -------------------------------------------------------------------------
    -- AXI-Stream sink: accept data when running and the FIFO is open
    -- -------------------------------------------------------------------------
    s_fifo_wr <= s_prev_tvalid and i_tvalid and o_tready;
    o_tready  <= '0' when s_state = STANDBY else
                 '1' when s_prev_tvalid = '0' else
                 not s_fifo_full and not s_fifo_wr_rst_busy;

    -- -------------------------------------------------------------------------
    -- Combinatorial outputs — driven directly from state and FIFO
    -- -------------------------------------------------------------------------

    o_awaddr <= std_logic_vector(s_aw_addr);
    o_wr_ptr <= std_logic_vector(s_wr_ptr);

    -- Address valid only while we are sending the AW beat.
    o_awvalid <= '1' when s_state = AW_SEND else
                 '0';

    -- FWFT: head of FIFO appears on dout combinatorially when non-empty.
    -- We know the FIFO is non-empty throughout W_SEND (we started only after
    -- prog_full, which guarantees ≥ g_burst_len words are present).
    o_wdata  <= s_fifo_dout;
    o_wvalid <= '1' when s_state = W_SEND else
                '0';
    o_wlast  <= '1' when s_state = W_SEND and s_beat_cnt = g_burst_len - 1 else
                '0';

    -- Response channel: always ready, we use this only to track on-going transactions
    o_bready <= '1';

    -- Advance the FIFO by one word for each beat accepted by the slave.
    s_fifo_rd <= '1' when s_state = W_SEND and i_wready = '1' else
                 '0';

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
                        s_aw_addr   <= unsigned(i_base_addr);
                        s_top_addr  <= unsigned(i_base_addr) + unsigned(i_buf_size);
                        s_buf_size  <= unsigned(i_buf_size);
                        s_state     <= IDLE;
                    end if;

                when IDLE =>

                    if not i_enable then
                        s_state <= WAIT_OUTSTANDING;
                    elsif s_fifo_prog_full then
                        s_state <= AW_SEND;
                    end if;

                when AW_SEND =>

                    if i_awready then
                        s_beat_cnt <= 0;
                        s_state    <= W_SEND;
                        -- Pre-calculate address for the next burst
                        s_aw_addr <= s_aw_addr + g_burst_len * 8;
                    end if;

                when W_SEND =>

                    if i_wready then
                        if s_beat_cnt = g_burst_len - 1 then
                            -- Check for ringbuffer wrap, s_buf_size is always multiple of 8*g_burst_len
                            if s_aw_addr >= s_top_addr then
                                s_aw_addr <= s_base_addr;
                            end if;

                            if s_fifo_prog_full then
                                -- Start a new transaction
                                s_state <= AW_SEND;
                            else
                                -- Not enough data available, take a break
                                s_state <= IDLE;
                            end if;
                        else
                            s_beat_cnt <= s_beat_cnt + 1;
                        end if;
                    end if;

                when WAIT_OUTSTANDING =>

                    -- Wait that all outstanding requests complete
                    if s_pending_cnt = 0 then
                        s_state <= STANDBY;
                    end if;

            end case;

            if not i_aresetn then
                s_state     <= STANDBY;
                s_beat_cnt  <= 0;
                s_aw_addr   <= (others => '0');
                s_base_addr <= (others => '0');
                s_buf_size  <= (others => '0');
                s_top_addr  <= (others => '0');
            end if;
        end if;
    end process;

    -- Keep track of pending transactions
    process (i_aclk) is
        variable v_req  : std_logic;
        variable v_rsp  : std_logic;
        variable v_next : unsigned(s_wr_ptr'range);
    begin
        if rising_edge(i_aclk) then
            v_req := o_awvalid and i_awready;
            v_rsp := i_bvalid and o_bready;

            if not i_aresetn then
                s_pending_cnt <= (others => '0');
            elsif v_req and not v_rsp then
                s_pending_cnt <= s_pending_cnt + 1;
            elsif not v_req and v_rsp then
                s_pending_cnt <= s_pending_cnt - 1;
            end if;

            if s_state = STANDBY and i_enable = '1' then
                s_wr_ptr <= (others => '0');
            elsif v_rsp then
                -- Burst completed, report back the write pointer
                v_next := s_wr_ptr + g_burst_len * 8;
                if v_next >= s_buf_size then
                    s_wr_ptr <= (others => '0');
                else
                    s_wr_ptr <= v_next;
                end if;
            end if;
        end if;
    end process;

    -- Pack two 32-bit words into one 64-bit word
    process (i_aclk) is
    begin
        if rising_edge(i_aclk) then
            if not i_aresetn then
                s_prev_tvalid <= '0';
            elsif i_tvalid and o_tready then
                if s_prev_tvalid then
                    s_prev_tvalid <= '0';
                else
                    s_prev_tvalid <= '1';
                    s_prev_tdata  <= i_tdata;
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
            PROG_FULL_THRESH    => g_burst_len,
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
            din           => i_tdata & s_prev_tdata,
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
            empty         => open,
            underflow     => open,
            rd_data_count => open,
            prog_empty    => open,
            rd_rst_busy   => open
        );

end architecture rtl;
