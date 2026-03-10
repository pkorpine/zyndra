--------------------------------------------------------------------------------
-- Title       : AD936x AXI
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
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity ad936x_axi is
    port (
        -- AXI4-Lite Bus
        aclk    : in    std_logic;
        aresetn : in    std_logic;
        -- Write
        awvalid : in    std_logic;
        awaddr  : in    std_logic_vector;
        awprot  : in    std_logic_vector; -- unused
        awready : out   std_logic;
        wvalid  : in    std_logic;
        wdata   : in    std_logic_vector(31 downto 0);
        wready  : out   std_logic;
        bvalid  : out   std_logic;
        bready  : in    std_logic;
        bresp   : out   std_logic_vector(1 downto 0);
        -- Read
        arvalid : in    std_logic;
        arready : out   std_logic;
        araddr  : in    std_logic_vector;
        arprot  : in    std_logic_vector;             -- unused
        rvalid  : out   std_logic;
        rready  : in    std_logic;
        rdata   : out   std_logic_vector(31 downto 0);
        rresp   : out   std_logic_vector(1 downto 0); -- unused
        --- AXI4 Master
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
        o_tready : out   std_logic;
        --
        i_iq_clk   : in    std_logic;
        i_iq_valid : in    std_logic;
        i_iq_i     : in    std_logic_vector(11 downto 0);
        i_iq_q     : in    std_logic_vector(11 downto 0)
    );
end entity ad936x_axi;

architecture rtl of ad936x_axi is

    subtype t_regaddr is unsigned(7 downto 0);

    constant c_reg_info        : t_regaddr := 8x"00";
    constant c_reg_fifo        : t_regaddr := 8x"04";
    constant c_reg_ctrl        : t_regaddr := 8x"08";
    constant c_reg_drop_cnt    : t_regaddr := 8x"0C";
    constant c_reg_rx_buf_base : t_regaddr := 8x"10";
    constant c_reg_rx_buf_size : t_regaddr := 8x"14";
    constant c_reg_rx_buf_wr   : t_regaddr := 8x"1C";

    signal s_wen   : std_logic_vector(1 downto 0);
    signal s_waddr : t_regaddr;
    signal s_wdata : std_logic_vector(31 downto 0);

    signal s_ren   : std_logic;
    signal s_rack  : std_logic;
    signal s_raddr : t_regaddr;
    signal s_rdata : std_logic_vector(31 downto 0);

    -- Registers (ACLK domain)
    signal s_enable     : std_logic;
    signal s_reset      : std_logic;
    signal s_fifo_rd    : std_logic;
    signal s_rd_data    : std_logic_vector(31 downto 0);
    signal s_fifo_empty : std_logic;

    signal s_rx_buf_base : std_logic_vector(31 downto 0);
    signal s_rx_buf_size : std_logic_vector(31 downto 0);
    signal s_rx_buf_wr   : std_logic_vector(31 downto 0);

    -- AXIS from RX to AXI writer
    signal s_axis_data  : std_logic_vector(31 downto 0);
    signal s_axis_valid : std_logic;
    signal s_axis_ready : std_logic;

    -- Registers (i_iq_clk domain)
    signal s_iq_rst    : std_logic;
    signal s_iq_enable : std_logic;
    signal s_wr_data   : std_logic_vector(31 downto 0);
    signal s_fifo_wr   : std_logic;
    signal s_fifo_full : std_logic;

    signal s_sample_drop     : std_logic;
    signal s_sample_drop_cdc : std_logic;

    signal s_fifo_drop_cnt : unsigned(31 downto 0);

begin

    --
    -- AXI4-Lite Write
    --
    bresp <= "00"; -- OKAY
    rresp <= "00"; -- OKAY

    awready <= '1';
    wready  <= '1';

    proc_axi_write : process (aclk) is
    begin
        if rising_edge(aclk) then
            if awvalid then
                s_waddr  <= unsigned(awaddr(s_waddr'range));
                s_wen(0) <= '1';
            end if;

            if wvalid then
                s_wdata  <= wdata;
                s_wen(1) <= '1';
            end if;

            if not aresetn then
                bvalid <= '0';
                s_wen  <= "00";
            elsif s_wen = "11" then
                bvalid <= '1';
                s_wen  <= "00";
            elsif bvalid and bready then
                bvalid <= '0';
            end if;
        end if;
    end process;

    proc_axi_read : process (aclk) is
    begin
        if rising_edge(aclk) then
            s_ren   <= '0';
            arready <= '0';

            if arvalid and not arready then
                s_ren   <= '1';
                s_raddr <= unsigned(araddr(s_raddr'range));
                arready <= '1';
            end if;

            if s_rack then
                rvalid <= '1';
                rdata  <= s_rdata;
            elsif rvalid and rready then
                rvalid <= '0';
            end if;

            if not aresetn then
                rvalid <= '0';
            end if;
        end if;
    end process;

    --
    -- Registers
    --
    proc_reg_write : process (aclk) is
    begin
        if rising_edge(aclk) then
            if s_wen = "11" then
                case s_waddr is

                    when c_reg_ctrl =>

                        s_enable <= s_wdata(0);
                        s_reset  <= s_wdata(1);

                    when c_reg_rx_buf_base =>

                        s_rx_buf_base <= s_wdata;

                    when c_reg_rx_buf_size =>

                        s_rx_buf_size <= s_wdata;

                    when others =>

                        null;
                end case;
            end if;

            if not aresetn then
                s_enable      <= '0';
                s_reset       <= '1';
                s_rx_buf_base <= (others => '0');
                s_rx_buf_size <= (others => '0');
            end if;
        end if;
    end process;

    proc_reg_read : process (aclk) is
    begin
        if rising_edge(aclk) then
            s_rack <= '0';
            -- s_fifo_rd <= '0';
            if s_ren then
                report to_hstring(s_raddr);
                s_rack  <= '1';
                s_rdata <= (others => '0');
                case s_raddr is

                    when c_reg_info =>

                        s_rdata <= 16x"CAFE" & 16x"0000";

                    when c_reg_ctrl =>

                        s_rdata(0) <= s_enable;
                        s_rdata(1) <= s_reset;

                    -- when c_REG_FIFO =>
                    --     s_rdata <= s_rd_data(31 downto 1) & s_fifo_empty;
                    --     s_fifo_rd <= not s_fifo_empty;
                    when c_reg_drop_cnt =>

                        s_rdata <= std_logic_vector(s_fifo_drop_cnt);

                    when c_reg_rx_buf_base =>

                        s_rdata <= s_rx_buf_base;

                    when c_reg_rx_buf_size =>

                        s_rdata <= s_rx_buf_size;

                    when c_reg_rx_buf_wr =>

                        s_rdata <= s_rx_buf_wr;

                    when others =>

                        s_rdata <= 32x"DEADBEEF";
                end case;
            end if;
        end if;
    end process;

    --
    -- Drop counter
    --
    cdc_drop_inst : component xpm_cdc_pulse
        generic map (
            DEST_SYNC_FF   => 4,
            INIT_SYNC_FF   => 1,
            REG_OUTPUT     => 1,
            RST_USED       => 1,
            SIM_ASSERT_CHK => 0
        )
        port map (
            src_clk    => i_iq_clk,
            src_rst    => s_iq_rst,
            src_pulse  => s_sample_drop,
            dest_clk   => aclk,
            dest_rst   => not aresetn,
            dest_pulse => s_sample_drop_cdc
        );

    process (aclk) is
    begin
        if rising_edge(aclk) then
            if not aresetn then
                s_fifo_drop_cnt <= (others => '0');
            elsif s_sample_drop_cdc then
                s_fifo_drop_cnt <= s_fifo_drop_cnt + 1;
            end if;
        end if;
    end process;

    --
    -- FIFO
    --
    xpm_fifo_async_inst : component xpm_fifo_async
        generic map (
            CASCADE_HEIGHT      => 0,
            CDC_SYNC_STAGES     => 2,
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            EN_SIM_ASSERT_ERR   => "warning",
            FIFO_MEMORY_TYPE    => "auto",
            FIFO_READ_LATENCY   => 0,
            FIFO_WRITE_DEPTH    => 8192 * 8,
            FULL_RESET_VALUE    => 1,
            PROG_EMPTY_THRESH   => 10,
            PROG_FULL_THRESH    => 10,
            RD_DATA_COUNT_WIDTH => 1,
            READ_DATA_WIDTH     => 32,
            READ_MODE           => "fwft",
            RELATED_CLOCKS      => 0,
            SIM_ASSERT_CHK      => 0,
            USE_ADV_FEATURES    => "0707",
            WAKEUP_TIME         => 0,
            WRITE_DATA_WIDTH    => 32,
            WR_DATA_COUNT_WIDTH => 1
        )
        port map (
            injectdbiterr => '0',
            injectsbiterr => '0',
            sbiterr       => open,
            dbiterr       => open,
            sleep         => '0',

            -- Write clock
            wr_clk        => i_iq_clk,
            rst           => s_iq_rst,
            wr_en         => s_fifo_wr,
            wr_ack        => open,
            din           => s_wr_data,
            almost_full   => open,
            full          => s_fifo_full,
            overflow      => open,
            prog_full     => open,
            wr_data_count => open,
            wr_rst_busy   => open,

            -- Read clock
            rd_clk        => aclk,
            rd_en         => s_fifo_rd,
            data_valid    => open,
            dout          => s_rd_data,
            almost_empty  => open,
            empty         => s_fifo_empty,
            prog_empty    => open,
            underflow     => open,
            rd_data_count => open,
            rd_rst_busy   => open
        );

    cdc_enable_inst : component xpm_cdc_single
        generic map (
            DEST_SYNC_FF   => 4,
            INIT_SYNC_FF   => 0,
            SIM_ASSERT_CHK => 0,
            SRC_INPUT_REG  => 1
        )
        port map (
            src_clk  => aclk,
            src_in   => s_enable,
            dest_clk => i_iq_clk,
            dest_out => s_iq_enable
        );

    cdc_reset_inst : component xpm_cdc_single
        generic map (
            DEST_SYNC_FF   => 4,
            INIT_SYNC_FF   => 1,
            SIM_ASSERT_CHK => 0,
            SRC_INPUT_REG  => 1
        )
        port map (
            src_clk  => aclk,
            src_in   => s_reset,
            dest_clk => i_iq_clk,
            dest_out => s_iq_rst
        );

    -- Writer
    process (i_iq_clk) is
    begin
        if rising_edge(i_iq_clk) then
            s_fifo_wr     <= '0';
            s_sample_drop <= '0';
            if s_iq_enable and not s_iq_rst then
                if i_iq_valid then
                    if s_fifo_full then
                        s_sample_drop <= '1';
                    else
                        s_wr_data <= i_iq_q & "0000" & i_iq_i & "0000";
                        s_fifo_wr <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Reader
    s_fifo_rd    <= s_axis_ready and not s_fifo_empty;
    s_axis_valid <= not s_fifo_empty;
    s_axis_data  <= s_rd_data;

    axi_master_wr_inst : entity work.axi_master_wr
        generic map (
            -- AXI burst length in beats (power of 2, 8-256).
            -- Note: Zynq-7000 has AXI3 which is limited to 16.
            g_burst_len => 16
        )
        port map (
            i_aclk    => aclk,
            i_aresetn => aresetn and not s_reset,
            i_enable  => s_enable,

            -- Control / status
            i_base_addr => s_rx_buf_base,
            i_buf_size  => s_rx_buf_size,
            o_wr_ptr    => s_rx_buf_wr,

            -- AXI4 write address channel (AW)
            o_awaddr  => o_awaddr,
            o_awlen   => o_awlen,
            o_awsize  => o_awsize,
            o_awburst => o_awburst,
            o_awvalid => o_awvalid,
            i_awready => i_awready,

            -- AXI4 write data channel (W)
            o_wdata  => o_wdata,
            o_wstrb  => o_wstrb,
            o_wlast  => o_wlast,
            o_wvalid => o_wvalid,
            i_wready => i_wready,

            -- AXI4 write response channel (B)
            i_bvalid => i_bvalid,
            o_bready => o_bready,
            i_bresp  => i_bresp,

            -- AXI-Stream sink (upstream data)
            i_tdata  => s_axis_data,
            i_tvalid => s_axis_valid,
            o_tready => s_axis_ready
        );

end architecture rtl;
