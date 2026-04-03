library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.vc_context;

use work.ad936x_axi_pkg.all;

entity tb_ad936x_axi is
    generic (
        runner_cfg : string
    );
end entity tb_ad936x_axi;

architecture sim of tb_ad936x_axi is

    constant ACLK_PERIOD   : time    := 10 ns;  -- 100 MHz
    constant IQ_CLK_PERIOD : time    := 16 ns;  -- ~62.5 MHz
    constant BUF_SIZE      : natural := 4096;
    constant IQ_OFFSET     : natural := 100;

    -- Register addresses (from ad936x_axi_pkg, padded to 32-bit for write_bus)
    function reg(addr : t_regaddr) return std_logic_vector is
    begin
        return std_logic_vector(resize(addr, 32));
    end function;

    -- VUnit verification components
    constant memory       : memory_t     := new_memory;
    constant axi_wr_slave : axi_slave_t  := new_axi_slave(
        memory => memory, address_fifo_depth => 8);
    constant axi_rd_slave : axi_slave_t  := new_axi_slave(
        memory => memory, address_fifo_depth => 8);
    constant bus_handle   : bus_master_t := new_bus(
        data_length => 32, address_length => 32);

    -- Clocks and reset
    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';
    signal iq_clk  : std_logic := '0';

    -- AXI-Lite (VUnit master ↔ DUT slave)
    signal axil_arvalid : std_logic;
    signal axil_arready : std_logic;
    signal axil_araddr  : std_logic_vector(31 downto 0);
    signal axil_rvalid  : std_logic;
    signal axil_rready  : std_logic;
    signal axil_rdata   : std_logic_vector(31 downto 0);
    signal axil_rresp   : std_logic_vector(1 downto 0);
    signal axil_awvalid : std_logic;
    signal axil_awready : std_logic;
    signal axil_awaddr  : std_logic_vector(31 downto 0);
    signal axil_wvalid  : std_logic;
    signal axil_wready  : std_logic;
    signal axil_wdata   : std_logic_vector(31 downto 0);
    signal axil_wstrb   : std_logic_vector(3 downto 0);
    signal axil_bvalid  : std_logic;
    signal axil_bready  : std_logic;
    signal axil_bresp   : std_logic_vector(1 downto 0);

    -- AXI4 write master (DUT → VUnit DDR write slave)
    signal m_awaddr  : std_logic_vector(31 downto 0);
    signal m_awlen   : std_logic_vector(7 downto 0);
    signal m_awsize  : std_logic_vector(2 downto 0);
    signal m_awburst : std_logic_vector(1 downto 0);
    signal m_awvalid : std_logic;
    signal m_awready : std_logic;
    signal m_wdata   : std_logic_vector(63 downto 0);
    signal m_wstrb   : std_logic_vector(7 downto 0);
    signal m_wlast   : std_logic;
    signal m_wvalid  : std_logic;
    signal m_wready  : std_logic;
    signal m_bvalid  : std_logic;
    signal m_bready  : std_logic;
    signal m_bresp   : std_logic_vector(1 downto 0);

    -- AXI4 read master (DUT ← VUnit DDR read slave)
    signal m_araddr  : std_logic_vector(31 downto 0);
    signal m_arlen   : std_logic_vector(7 downto 0);
    signal m_arsize  : std_logic_vector(2 downto 0);
    signal m_arburst : std_logic_vector(1 downto 0);
    signal m_arvalid : std_logic;
    signal m_arready : std_logic;
    signal m_rdata   : std_logic_vector(63 downto 0);
    signal m_rlast   : std_logic;
    signal m_rvalid  : std_logic;
    signal m_rresp   : std_logic_vector(1 downto 0);
    signal m_rready  : std_logic;

    -- IQ interface
    signal i_rx_iq_valid    : std_logic := '0';
    signal i_rx_iq_i       : std_logic_vector(11 downto 0) := (others => '0');
    signal i_rx_iq_q       : std_logic_vector(11 downto 0) := (others => '0');
    signal o_tx_iq_i       : std_logic_vector(11 downto 0);
    signal o_tx_iq_q       : std_logic_vector(11 downto 0);
    signal o_tx_iq_valid    : std_logic;
    signal i_tx_iq_rdy      : std_logic := '0';
    signal i_tx_iq_underrun : std_logic := '0';

    -- AXI slave ID (unconstrained ports need a signal)
    signal wr_slave_bid : std_logic_vector(0 downto 0);
    signal rd_slave_rid : std_logic_vector(0 downto 0);

    -- Loopback / stimulus control
    signal loopback_en  : std_logic := '0';
    signal ext_iq_valid : std_logic := '0';
    signal ext_iq_i     : std_logic_vector(11 downto 0) := (others => '0');
    signal ext_iq_q     : std_logic_vector(11 downto 0) := (others => '0');

begin

    -- =========================================================================
    -- Clock generation
    -- =========================================================================
    aclk   <= not aclk   after ACLK_PERIOD / 2;
    iq_clk <= not iq_clk after IQ_CLK_PERIOD / 2;

    -- Mimic ad936x_txrx serializer: ready every other iq_clk
    process (iq_clk)
    begin
        if rising_edge(iq_clk) then
            i_tx_iq_rdy <= not i_tx_iq_rdy;
        end if;
    end process;

    -- =========================================================================
    -- Loopback mux: TX output → RX input
    -- =========================================================================
    i_rx_iq_i    <= o_tx_iq_i                 when loopback_en = '1' else ext_iq_i;
    i_rx_iq_q    <= o_tx_iq_q                 when loopback_en = '1' else ext_iq_q;
    i_rx_iq_valid <= o_tx_iq_valid and i_tx_iq_rdy when loopback_en = '1' else ext_iq_valid;

    -- =========================================================================
    -- RX IQ stimulus (external, incrementing)
    -- =========================================================================
    p_rx_stimulus : process
        variable v_count : unsigned(11 downto 0) := (others => '0');
    begin
        wait until rising_edge(iq_clk);
        if loopback_en = '0' and aresetn = '1' then
            ext_iq_valid <= '1';
            ext_iq_i     <= std_logic_vector(v_count);
            ext_iq_q     <= std_logic_vector(v_count + IQ_OFFSET);
            v_count      := v_count + 1;
        else
            ext_iq_valid <= '0';
        end if;
    end process;

    -- =========================================================================
    -- DUT
    -- =========================================================================
    dut : entity work.ad936x_axi
        port map (
            aclk      => aclk,
            aresetn   => aresetn,
            awvalid   => axil_awvalid,
            awaddr    => axil_awaddr,
            awprot    => "000",
            awready   => axil_awready,
            wvalid    => axil_wvalid,
            wdata     => axil_wdata,
            wready    => axil_wready,
            bvalid    => axil_bvalid,
            bready    => axil_bready,
            bresp     => axil_bresp,
            arvalid   => axil_arvalid,
            arready   => axil_arready,
            araddr    => axil_araddr,
            arprot    => "000",
            rvalid    => axil_rvalid,
            rready    => axil_rready,
            rdata     => axil_rdata,
            rresp     => axil_rresp,
            o_awaddr  => m_awaddr,
            o_awlen   => m_awlen,
            o_awsize  => m_awsize,
            o_awburst => m_awburst,
            o_awvalid => m_awvalid,
            i_awready => m_awready,
            o_wdata   => m_wdata,
            o_wstrb   => m_wstrb,
            o_wlast   => m_wlast,
            o_wvalid  => m_wvalid,
            i_wready  => m_wready,
            i_bvalid  => m_bvalid,
            o_bready  => m_bready,
            i_bresp   => m_bresp,
            o_araddr  => m_araddr,
            o_arlen   => m_arlen,
            o_arsize  => m_arsize,
            o_arburst => m_arburst,
            o_arvalid => m_arvalid,
            i_arready => m_arready,
            i_rdata   => m_rdata,
            i_rlast   => m_rlast,
            i_rvalid  => m_rvalid,
            i_rresp   => m_rresp,
            o_rready  => m_rready,
            i_iq_clk      => iq_clk,
            i_rx_iq_valid    => i_rx_iq_valid,
            i_rx_iq_i       => i_rx_iq_i,
            i_rx_iq_q       => i_rx_iq_q,
            o_tx_iq_i       => o_tx_iq_i,
            o_tx_iq_q       => o_tx_iq_q,
            o_tx_iq_valid    => o_tx_iq_valid,
            i_tx_iq_rdy      => i_tx_iq_rdy,
            i_tx_iq_underrun => i_tx_iq_underrun
        );

    -- =========================================================================
    -- VUnit AXI-Lite master (register access)
    -- =========================================================================
    axil_master_inst : entity vunit_lib.axi_lite_master
        generic map (bus_handle => bus_handle)
        port map (
            aclk    => aclk,
            arvalid => axil_arvalid,
            arready => axil_arready,
            araddr  => axil_araddr,
            rvalid  => axil_rvalid,
            rready  => axil_rready,
            rdata   => axil_rdata,
            rresp   => axil_rresp,
            awvalid => axil_awvalid,
            awready => axil_awready,
            awaddr  => axil_awaddr,
            wvalid  => axil_wvalid,
            wready  => axil_wready,
            wdata   => axil_wdata,
            wstrb   => axil_wstrb,
            bvalid  => axil_bvalid,
            bready  => axil_bready,
            bresp   => axil_bresp
        );

    -- =========================================================================
    -- VUnit AXI write slave (DDR model, receives RX DMA writes)
    -- =========================================================================
    axi_wr_slave_inst : entity vunit_lib.axi_write_slave
        generic map (axi_slave => axi_wr_slave)
        port map (
            aclk    => aclk,
            awvalid => m_awvalid,
            awready => m_awready,
            awid    => "0",
            awaddr  => m_awaddr,
            awlen   => m_awlen,
            awsize  => m_awsize,
            awburst => m_awburst,
            wvalid  => m_wvalid,
            wready  => m_wready,
            wdata   => m_wdata,
            wstrb   => m_wstrb,
            wlast   => m_wlast,
            bvalid  => m_bvalid,
            bready  => m_bready,
            bid     => wr_slave_bid,
            bresp   => m_bresp
        );

    -- =========================================================================
    -- VUnit AXI read slave (DDR model, serves TX DMA reads)
    -- =========================================================================
    axi_rd_slave_inst : entity vunit_lib.axi_read_slave
        generic map (axi_slave => axi_rd_slave)
        port map (
            aclk    => aclk,
            arvalid => m_arvalid,
            arready => m_arready,
            arid    => "0",
            araddr  => m_araddr,
            arlen   => m_arlen,
            arsize  => m_arsize,
            arburst => m_arburst,
            rvalid  => m_rvalid,
            rready  => m_rready,
            rid     => rd_slave_rid,
            rdata   => m_rdata,
            rresp   => m_rresp,
            rlast   => m_rlast
        );

    -- =========================================================================
    -- Main test process
    -- =========================================================================
    p_main : process
        variable data   : std_logic_vector(31 downto 0);
        variable rx_buf : buffer_t;
        variable tx_buf : buffer_t;
        variable v_word : std_logic_vector(31 downto 0);
        variable v_i    : unsigned(11 downto 0);
        variable v_q    : unsigned(11 downto 0);
        variable v_base : unsigned(11 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);

        -- Reset
        aresetn <= '0';
        wait for 5 * ACLK_PERIOD;
        aresetn <= '1';
        wait for 5 * ACLK_PERIOD;

        while test_suite loop

            -- =================================================================
            -- Test: register read/write
            -- =================================================================
            if run("register_rw") then
                info("Register read/write test");

                check_bus(net, bus_handle, reg(c_reg_info),
                    x"AD930001", "INFO");

                -- Write/read CTRL (keep reset=1 so DMA engines stay idle)
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000007");
                check_bus(net, bus_handle, reg(c_reg_ctrl),
                    x"00000007", "CTRL all bits");

                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000001");

                -- RX buffer registers
                write_bus(net, bus_handle, reg(c_reg_rx_buf_base), x"10000000");
                check_bus(net, bus_handle, reg(c_reg_rx_buf_base),
                    x"10000000", "RX_BUF_BASE");

                write_bus(net, bus_handle, reg(c_reg_rx_buf_size), x"00001000");
                check_bus(net, bus_handle, reg(c_reg_rx_buf_size),
                    x"00001000", "RX_BUF_SIZE");

                -- TX buffer registers
                write_bus(net, bus_handle, reg(c_reg_tx_buf_base), x"20000000");
                check_bus(net, bus_handle, reg(c_reg_tx_buf_base),
                    x"20000000", "TX_BUF_BASE");

                write_bus(net, bus_handle, reg(c_reg_tx_buf_size), x"00002000");
                check_bus(net, bus_handle, reg(c_reg_tx_buf_size),
                    x"00002000", "TX_BUF_SIZE");

                check_bus(net, bus_handle, reg(c_reg_tx_buf_rd),
                    x"00000000", "TX_BUF_RD idle");

                -- TX write pointer (SW → HW)
                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr), x"00000100");
                check_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    x"00000100", "TX_BUF_WR");

                -- Unknown register
                check_bus(net, bus_handle, x"000000FC",
                    x"DEADBEEF", "Unknown reg");

                info("Register test passed");
            end if;

            -- =================================================================
            -- Test: RX capture (IQ → RX FIFO → axi_master_wr → DDR)
            -- =================================================================
            if run("rx_capture") then
                info("RX capture test");
                loopback_en <= '0';

                rx_buf := allocate(memory, BUF_SIZE, alignment => 4096);

                write_bus(net, bus_handle, reg(c_reg_rx_buf_base),
                    std_logic_vector(to_unsigned(base_address(rx_buf), 32)));
                write_bus(net, bus_handle, reg(c_reg_rx_buf_size),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Deassert reset, let FIFOs settle, then enable RX
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait for 20 * ACLK_PERIOD;
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000002");
                wait_until_idle(net, bus_handle);

                -- Wait for several DMA bursts to complete
                -- 16 beats × 8 bytes = 128 bytes/burst, 2 samples/beat → 32 samples/burst
                wait for 300 * IQ_CLK_PERIOD;

                -- Disable (assert reset)
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000001");
                wait for 50 * ACLK_PERIOD;

                -- Check write pointer advanced
                read_bus(net, bus_handle, reg(c_reg_rx_buf_wr), data);
                check(unsigned(data) > 0,
                    "RX wr_ptr should advance, got " & to_hstring(data));
                info("RX wr_ptr = 0x" & to_hstring(data));

                -- Verify DDR data: incrementing I, Q = I + IQ_OFFSET
                -- First sample should now be valid (no reset-recovery garbage)
                -- Packing: Q[11:0] & "0000" & I[11:0] & "0000"
                v_word := read_word(memory, base_address(rx_buf), 4);
                v_base := unsigned(v_word(15 downto 4));
                check(v_word /= x"00000000",
                    "First RX word should be non-zero");
                info("RX first sample I = " & integer'image(to_integer(v_base)));

                for i in 1 to 7 loop
                    v_word := read_word(memory,
                        base_address(rx_buf) + i * 4, 4);
                    v_i := unsigned(v_word(15 downto 4));
                    v_q := unsigned(v_word(31 downto 20));
                    check_equal(v_i, v_base + i,
                        "RX sample " & integer'image(i) & " I");
                    check_equal(v_q, v_base + i + IQ_OFFSET,
                        "RX sample " & integer'image(i) & " Q");
                end loop;

                info("RX capture passed");
            end if;

            -- =================================================================
            -- Test: TX playback (DDR → axi_master_rd → TX FIFO → IQ out)
            -- =================================================================
            if run("tx_playback") then
                info("TX playback test");
                loopback_en <= '0';

                tx_buf := allocate(memory, BUF_SIZE, alignment => 4096);

                -- Pre-fill TX buffer with incrementing IQ pattern
                for i in 0 to BUF_SIZE / 4 - 1 loop
                    v_i := to_unsigned(i mod 4096, 12);
                    v_q := to_unsigned((i + IQ_OFFSET) mod 4096, 12);
                    v_word := std_logic_vector(v_q) & "0000"
                            & std_logic_vector(v_i) & "0000";
                    write_word(memory,
                        base_address(tx_buf) + i * 4, v_word);
                end loop;

                write_bus(net, bus_handle, reg(c_reg_tx_buf_base),
                    std_logic_vector(to_unsigned(base_address(tx_buf), 32)));
                write_bus(net, bus_handle, reg(c_reg_tx_buf_size),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Tell FPGA all data is available
                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Enable TX, deassert reset
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait for 20 * ACLK_PERIOD;
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000004");
                wait_until_idle(net, bus_handle);

                -- Wait for pipeline to fill
                wait for 200 * ACLK_PERIOD;

                -- Sync: capture first valid sample, then check consecutive
                wait until rising_edge(iq_clk)
                    and i_tx_iq_rdy = '1' and o_tx_iq_valid = '1';
                v_base := unsigned(o_tx_iq_i);

                for i in 1 to 15 loop
                    wait until rising_edge(iq_clk)
                        and i_tx_iq_rdy = '1' and o_tx_iq_valid = '1';
                    check_equal(o_tx_iq_i,
                        std_logic_vector(v_base + i),
                        "TX sample " & integer'image(i) & " I");
                    check_equal(o_tx_iq_q,
                        std_logic_vector(v_base + i + IQ_OFFSET),
                        "TX sample " & integer'image(i) & " Q");
                end loop;

                info("TX playback passed");
            end if;

            -- =================================================================
            -- Test: loopback (DDR TX → IQ → DDR RX)
            -- =================================================================
            if run("loopback") then
                info("Loopback test");
                loopback_en <= '1';

                tx_buf := allocate(memory, BUF_SIZE, alignment => 4096);
                rx_buf := allocate(memory, BUF_SIZE, alignment => 4096);

                -- Pre-fill TX buffer
                for i in 0 to BUF_SIZE / 4 - 1 loop
                    v_i := to_unsigned(i mod 4096, 12);
                    v_q := to_unsigned((i + IQ_OFFSET) mod 4096, 12);
                    v_word := std_logic_vector(v_q) & "0000"
                            & std_logic_vector(v_i) & "0000";
                    write_word(memory,
                        base_address(tx_buf) + i * 4, v_word);
                end loop;

                -- Configure both paths
                write_bus(net, bus_handle, reg(c_reg_tx_buf_base),
                    std_logic_vector(to_unsigned(base_address(tx_buf), 32)));
                write_bus(net, bus_handle, reg(c_reg_tx_buf_size),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));
                write_bus(net, bus_handle, reg(c_reg_rx_buf_base),
                    std_logic_vector(to_unsigned(base_address(rx_buf), 32)));
                write_bus(net, bus_handle, reg(c_reg_rx_buf_size),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Tell FPGA all TX data is available
                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Deassert reset, let FIFOs settle, then enable both
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait for 20 * ACLK_PERIOD;
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000006");
                wait_until_idle(net, bus_handle);

                -- Wait for data to flow through full pipeline
                wait for 500 * IQ_CLK_PERIOD;

                -- Disable (assert reset)
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000001");
                wait for 100 * ACLK_PERIOD;

                -- Check RX write pointer advanced
                read_bus(net, bus_handle, reg(c_reg_rx_buf_wr), data);
                check(unsigned(data) > 0,
                    "Loopback: RX wr_ptr should advance, got " & to_hstring(data));
                info("Loopback: RX wr_ptr = 0x" & to_hstring(data));

                -- Verify RX buffer: first word should be non-zero now
                v_word := read_word(memory, base_address(rx_buf), 4);
                v_base := unsigned(v_word(15 downto 4));
                check(v_word /= x"00000000",
                    "Loopback: first RX word should be non-zero");
                info("Loopback: first RX sample I = " &
                    integer'image(to_integer(v_base)));

                for i in 1 to 7 loop
                    v_word := read_word(memory,
                        base_address(rx_buf) + i * 4, 4);
                    v_i := unsigned(v_word(15 downto 4));
                    v_q := unsigned(v_word(31 downto 20));
                    check_equal(v_i, v_base + i,
                        "Loopback sample " & integer'image(i) & " I");
                    check_equal(v_q, v_base + i + IQ_OFFSET,
                        "Loopback sample " & integer'image(i) & " Q");
                end loop;

                info("Loopback test passed");
            end if;

            -- =================================================================
            -- Test: TX disabled outputs zero
            -- =================================================================
            if run("tx_disabled_output_zero") then
                info("TX disabled output zero test");
                loopback_en <= '0';

                tx_buf := allocate(memory, BUF_SIZE, alignment => 4096);

                -- Pre-fill TX buffer with non-zero IQ pattern
                for i in 0 to BUF_SIZE / 4 - 1 loop
                    v_i := to_unsigned((i mod 4096) + 1, 12);
                    v_q := to_unsigned(((i + IQ_OFFSET) mod 4096) + 1, 12);
                    v_word := std_logic_vector(v_q) & "0000"
                            & std_logic_vector(v_i) & "0000";
                    write_word(memory,
                        base_address(tx_buf) + i * 4, v_word);
                end loop;

                write_bus(net, bus_handle, reg(c_reg_tx_buf_base),
                    std_logic_vector(to_unsigned(base_address(tx_buf), 32)));
                write_bus(net, bus_handle, reg(c_reg_tx_buf_size),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));
                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Enable TX
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait for 20 * ACLK_PERIOD;
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000004");
                wait_until_idle(net, bus_handle);

                -- Wait for data to flow
                wait for 200 * ACLK_PERIOD;

                -- Verify non-zero output while TX is enabled
                wait until rising_edge(iq_clk)
                    and i_tx_iq_rdy = '1' and o_tx_iq_valid = '1';
                check(unsigned(o_tx_iq_i) /= 0 or unsigned(o_tx_iq_q) /= 0,
                    "TX output should be non-zero while enabled");
                info("Confirmed non-zero TX output while enabled");

                -- Disable TX (clear TX_ENABLE, keep reset deasserted)
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait_until_idle(net, bus_handle);

                -- Wait for CDC to propagate (4 sync FFs + margin)
                wait for 20 * IQ_CLK_PERIOD;

                -- Verify TX outputs zero IQ with valid asserted
                -- (valid='1' + zero data forces serializer to latch zeros)
                for i in 0 to 15 loop
                    wait until rising_edge(iq_clk) and i_tx_iq_rdy = '1';
                    check_equal(o_tx_iq_valid, '1',
                        "TX valid should be 1 (feeding zeros) when disabled (cycle " &
                        integer'image(i) & ")");
                    check_equal(o_tx_iq_i, std_logic_vector'(x"000"),
                        "TX I should be zero when disabled (cycle " &
                        integer'image(i) & ")");
                    check_equal(o_tx_iq_q, std_logic_vector'(x"000"),
                        "TX Q should be zero when disabled (cycle " &
                        integer'image(i) & ")");
                end loop;

                info("TX disabled output zero test passed");
            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

    test_runner_watchdog(runner, 500 us);

end architecture sim;
