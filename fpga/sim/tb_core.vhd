library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.vc_context;

use work.ad936x_axi_pkg.all;

entity tb_core is
    generic (
        runner_cfg : string
    );
end entity tb_core;

architecture sim of tb_core is

    constant ACLK_PERIOD    : time    := 10 ns;   -- 100 MHz AXI clock
    constant DATACLK_PERIOD : time    := 20 ns;   -- 50 MHz AD9363 DATA_CLK
    constant BUF_SIZE       : natural := 4096;
    constant IQ_OFFSET      : natural := 100;

    -- Register address helper
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

    -- AXI records
    signal s_axil_mosi : t_axi4l_mosi;
    signal s_axil_miso : t_axi4l_miso;
    signal s_axi4_mosi : t_axi4_mosi;
    signal s_axi4_miso : t_axi4_miso;

    -- GPIO
    signal gpio_i : std_logic_vector(63 downto 0);

    -- LVDS RX (testbench → DUT)
    signal rx_clk_se   : std_logic := '0';
    signal rx_frame_se : std_logic := '0';
    signal rx_data_se  : std_logic_vector(5 downto 0) := (others => '0');
    signal rx_clk_p, rx_clk_n     : std_logic;
    signal rx_frame_p, rx_frame_n : std_logic;
    signal rx_data_p, rx_data_n   : std_logic_vector(5 downto 0);

    -- LVDS TX (DUT → testbench)
    signal tx_clk_p, tx_clk_n     : std_logic;
    signal tx_frame_p, tx_frame_n : std_logic;
    signal tx_data_p, tx_data_n   : std_logic_vector(5 downto 0);

    -- Debug header (unused in TB)
    signal ext_io1_p, ext_io1_n : std_logic;
    signal ext_io3_p, ext_io3_n : std_logic;
    signal ext_io5_p, ext_io5_n : std_logic;
    signal ext_io7_p, ext_io7_n : std_logic;

    -- Loopback control
    signal loopback_en : std_logic := '0';

    -- AXI slave IDs
    signal wr_slave_bid : std_logic_vector(0 downto 0);
    signal rd_slave_rid : std_logic_vector(0 downto 0);

begin

    -- =========================================================================
    -- Clock generation
    -- =========================================================================
    aclk      <= not aclk      after ACLK_PERIOD / 2;
    rx_clk_se <= not rx_clk_se after DATACLK_PERIOD / 2;

    -- Differential conversion
    rx_clk_p <= rx_clk_se;
    rx_clk_n <= not rx_clk_se;

    -- RX input mux: external DDR stimulus or TX loopback
    rx_frame_p <= tx_frame_p       when loopback_en = '1' else rx_frame_se;
    rx_frame_n <= tx_frame_n       when loopback_en = '1' else not rx_frame_se;
    rx_data_p  <= tx_data_p        when loopback_en = '1' else rx_data_se;
    rx_data_n  <= tx_data_n        when loopback_en = '1' else not rx_data_se;

    -- Default AXI-Lite prot (not driven by VUnit master)
    s_axil_mosi.awprot <= "000";
    s_axil_mosi.arprot <= "000";

    -- =========================================================================
    -- DUT
    -- =========================================================================
    dut : entity work.core
        port map (
            i_axi_clk  => aclk,
            i_axi_rstn => aresetn,
            i_axil     => s_axil_mosi,
            o_axil     => s_axil_miso,
            o_axi4     => s_axi4_mosi,
            i_axi4     => s_axi4_miso,
            o_gpio_i   => gpio_i,
            -- LVDS RX
            rx_clk_in_p   => rx_clk_p,
            rx_clk_in_n   => rx_clk_n,
            rx_frame_in_p => rx_frame_p,
            rx_frame_in_n => rx_frame_n,
            rx_data_in_p  => rx_data_p,
            rx_data_in_n  => rx_data_n,
            -- LVDS TX
            tx_clk_out_p   => tx_clk_p,
            tx_clk_out_n   => tx_clk_n,
            tx_frame_out_p => tx_frame_p,
            tx_frame_out_n => tx_frame_n,
            tx_data_out_p  => tx_data_p,
            tx_data_out_n  => tx_data_n,
            -- Debug header
            ext_1v8_io1_p => ext_io1_p,
            ext_1v8_io1_n => ext_io1_n,
            ext_1v8_io3_p => ext_io3_p,
            ext_1v8_io3_n => ext_io3_n,
            ext_1v8_io5_p => ext_io5_p,
            ext_1v8_io5_n => ext_io5_n,
            ext_1v8_io7_p => ext_io7_p,
            ext_1v8_io7_n => ext_io7_n
        );

    -- =========================================================================
    -- VUnit AXI-Lite master (register access)
    -- =========================================================================
    axil_master_inst : entity vunit_lib.axi_lite_master
        generic map (bus_handle => bus_handle)
        port map (
            aclk    => aclk,
            arvalid => s_axil_mosi.arvalid,
            arready => s_axil_miso.arready,
            araddr  => s_axil_mosi.araddr,
            rvalid  => s_axil_miso.rvalid,
            rready  => s_axil_mosi.rready,
            rdata   => s_axil_miso.rdata,
            rresp   => s_axil_miso.rresp,
            awvalid => s_axil_mosi.awvalid,
            awready => s_axil_miso.awready,
            awaddr  => s_axil_mosi.awaddr,
            wvalid  => s_axil_mosi.wvalid,
            wready  => s_axil_miso.wready,
            wdata   => s_axil_mosi.wdata,
            wstrb   => s_axil_mosi.wstrb,
            bvalid  => s_axil_miso.bvalid,
            bready  => s_axil_mosi.bready,
            bresp   => s_axil_miso.bresp
        );

    -- =========================================================================
    -- VUnit AXI write slave (DDR model, receives RX DMA writes)
    -- =========================================================================
    axi_wr_slave_inst : entity vunit_lib.axi_write_slave
        generic map (axi_slave => axi_wr_slave)
        port map (
            aclk    => aclk,
            awvalid => s_axi4_mosi.awvalid,
            awready => s_axi4_miso.awready,
            awid    => "0",
            awaddr  => s_axi4_mosi.awaddr,
            awlen   => s_axi4_mosi.awlen,
            awsize  => s_axi4_mosi.awsize,
            awburst => s_axi4_mosi.awburst,
            wvalid  => s_axi4_mosi.wvalid,
            wready  => s_axi4_miso.wready,
            wdata   => s_axi4_mosi.wdata,
            wstrb   => s_axi4_mosi.wstrb,
            wlast   => s_axi4_mosi.wlast,
            bvalid  => s_axi4_miso.bvalid,
            bready  => s_axi4_mosi.bready,
            bid     => wr_slave_bid,
            bresp   => s_axi4_miso.bresp
        );

    -- =========================================================================
    -- VUnit AXI read slave (DDR model, serves TX DMA reads)
    -- =========================================================================
    axi_rd_slave_inst : entity vunit_lib.axi_read_slave
        generic map (axi_slave => axi_rd_slave)
        port map (
            aclk    => aclk,
            arvalid => s_axi4_mosi.arvalid,
            arready => s_axi4_miso.arready,
            arid    => "0",
            araddr  => s_axi4_mosi.araddr,
            arlen   => s_axi4_mosi.arlen,
            arsize  => s_axi4_mosi.arsize,
            arburst => s_axi4_mosi.arburst,
            rvalid  => s_axi4_miso.rvalid,
            rready  => s_axi4_mosi.rready,
            rid     => rd_slave_rid,
            rdata   => s_axi4_miso.rdata,
            rresp   => s_axi4_miso.rresp,
            rlast   => s_axi4_miso.rlast
        );

    -- =========================================================================
    -- RX DDR Stimulus Generator (mimics AD9363 DDR output)
    --
    -- Each IQ sample takes 2 DATA_CLK cycles:
    --   Cycle 0 (frame=1): rise = I[11:6], fall = Q[11:6]
    --   Cycle 1 (frame=0): rise = I[5:0],  fall = Q[5:0]
    -- =========================================================================
    p_rx_stimulus : process
        variable v_count : unsigned(11 downto 0) := (others => '0');
        variable v_i     : std_logic_vector(11 downto 0);
        variable v_q     : std_logic_vector(11 downto 0);
    begin
        wait until falling_edge(rx_clk_se);

        loop
            v_i := std_logic_vector(v_count);
            v_q := std_logic_vector(v_count + IQ_OFFSET);

            -- MSB cycle: frame = 1
            rx_data_se  <= v_i(11 downto 6);
            rx_frame_se <= '1';
            wait until rising_edge(rx_clk_se);

            rx_data_se <= v_q(11 downto 6);
            wait until falling_edge(rx_clk_se);

            -- LSB cycle: frame = 0
            rx_data_se  <= v_i(5 downto 0);
            rx_frame_se <= '0';
            wait until rising_edge(rx_clk_se);

            rx_data_se <= v_q(5 downto 0);
            wait until falling_edge(rx_clk_se);

            v_count := v_count + 1;
        end loop;
    end process p_rx_stimulus;

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

                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000007");
                check_bus(net, bus_handle, reg(c_reg_ctrl),
                    x"00000007", "CTRL all bits");

                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000001");

                write_bus(net, bus_handle, reg(c_reg_rx_buf_base), x"10000000");
                check_bus(net, bus_handle, reg(c_reg_rx_buf_base),
                    x"10000000", "RX_BUF_BASE");

                write_bus(net, bus_handle, reg(c_reg_rx_buf_size), x"00001000");
                check_bus(net, bus_handle, reg(c_reg_rx_buf_size),
                    x"00001000", "RX_BUF_SIZE");

                write_bus(net, bus_handle, reg(c_reg_tx_buf_base), x"20000000");
                check_bus(net, bus_handle, reg(c_reg_tx_buf_base),
                    x"20000000", "TX_BUF_BASE");

                write_bus(net, bus_handle, reg(c_reg_tx_buf_size), x"00002000");
                check_bus(net, bus_handle, reg(c_reg_tx_buf_size),
                    x"00002000", "TX_BUF_SIZE");

                check_bus(net, bus_handle, reg(c_reg_tx_buf_rd),
                    x"00000000", "TX_BUF_RD idle");

                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr), x"00000100");
                check_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    x"00000100", "TX_BUF_WR");

                check_bus(net, bus_handle, x"000000FC",
                    x"DEADBEEF", "Unknown reg");

                info("Register test passed");
            end if;

            -- =================================================================
            -- Test: RX capture (LVDS → ad936x_txrx → ad936x_axi → DDR)
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

                -- Wait for DMA bursts (LVDS is slower: ~25 MHz sample rate)
                wait for 600 * DATACLK_PERIOD;

                -- Disable
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000001");
                wait for 50 * ACLK_PERIOD;

                -- Check write pointer advanced
                read_bus(net, bus_handle, reg(c_reg_rx_buf_wr), data);
                check(unsigned(data) > 0,
                    "RX wr_ptr should advance, got " & to_hstring(data));
                info("RX wr_ptr = 0x" & to_hstring(data));

                -- Verify DDR data: incrementing I, Q = I + IQ_OFFSET
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
            -- Test: TX playback (DDR → axi_master_rd → TX FIFO → LVDS)
            -- =================================================================
            if run("tx_playback") then
                info("TX playback test");
                loopback_en <= '0';

                tx_buf := allocate(memory, BUF_SIZE, alignment => 4096);

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
                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Enable TX
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait for 20 * ACLK_PERIOD;
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000004");
                wait_until_idle(net, bus_handle);

                -- Wait for TX pipeline to fill and LVDS output to start
                wait for 400 * ACLK_PERIOD;

                -- Check TX read pointer advanced
                read_bus(net, bus_handle, reg(c_reg_tx_buf_rd), data);
                check(unsigned(data) > 0,
                    "TX rd_ptr should advance, got " & to_hstring(data));
                info("TX rd_ptr = 0x" & to_hstring(data));

                info("TX playback passed");
            end if;

            -- =================================================================
            -- Test: loopback (DDR TX → LVDS → DDR RX)
            -- =================================================================
            if run("loopback") then
                info("Loopback test");
                loopback_en <= '1';

                tx_buf := allocate(memory, BUF_SIZE, alignment => 4096);
                rx_buf := allocate(memory, BUF_SIZE, alignment => 4096);

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
                write_bus(net, bus_handle, reg(c_reg_rx_buf_base),
                    std_logic_vector(to_unsigned(base_address(rx_buf), 32)));
                write_bus(net, bus_handle, reg(c_reg_rx_buf_size),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));
                write_bus(net, bus_handle, reg(c_reg_tx_buf_wr),
                    std_logic_vector(to_unsigned(BUF_SIZE, 32)));

                -- Enable both TX and RX
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000000");
                wait for 20 * ACLK_PERIOD;
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000006");
                wait_until_idle(net, bus_handle);

                -- Wait for full pipeline (TX DMA → TX FIFO → LVDS → RX FIFO → RX DMA)
                wait for 1000 * DATACLK_PERIOD;

                -- Disable
                write_bus(net, bus_handle, reg(c_reg_ctrl), x"00000001");
                wait for 100 * ACLK_PERIOD;

                -- Check RX write pointer advanced
                read_bus(net, bus_handle, reg(c_reg_rx_buf_wr), data);
                check(unsigned(data) > 0,
                    "Loopback: RX wr_ptr should advance, got " & to_hstring(data));
                info("Loopback: RX wr_ptr = 0x" & to_hstring(data));

                -- Find first non-zero sample (skip pipeline warmup zeros)
                -- Note: I=0 Q=IQ_OFFSET is a valid first sample, so check
                -- for non-zero word, not non-zero I.
                for s in 0 to 63 loop
                    v_word := read_word(memory,
                        base_address(rx_buf) + s * 4, 4);
                    if v_word /= x"00000000" then
                        v_base := unsigned(v_word(15 downto 4));
                        info("Loopback: first valid sample at offset " &
                            integer'image(s) & ", I = " &
                            integer'image(to_integer(v_base)));
                        -- Verify 7 consecutive samples from here
                        for i in 1 to 7 loop
                            v_word := read_word(memory,
                                base_address(rx_buf) + (s + i) * 4, 4);
                            v_i := unsigned(v_word(15 downto 4));
                            v_q := unsigned(v_word(31 downto 20));
                            check_equal(v_i, v_base + i,
                                "Loopback sample " & integer'image(i) & " I");
                            check_equal(v_q, v_base + i + IQ_OFFSET,
                                "Loopback sample " & integer'image(i) & " Q");
                        end loop;
                        exit;
                    end if;
                    check(s < 63,
                        "Loopback: should find non-zero sample in first 64 words");
                end loop;

                info("Loopback test passed");
            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

    test_runner_watchdog(runner, 1 ms);

end architecture sim;
