library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

entity tb_ad936x_txrx is
    generic (
        runner_cfg : string
    );
end entity tb_ad936x_txrx;

architecture sim of tb_ad936x_txrx is

    constant CLK_PERIOD  : time := 20 ns; -- 50 MHz DATA_CLK
    constant IQ_OFFSET   : unsigned(11 downto 0) := to_unsigned(100, 12);
    constant NUM_SAMPLES : integer := 20;

    -- DUT ports
    signal rx_clk_p, rx_clk_n     : std_logic;
    signal rx_frame_p, rx_frame_n : std_logic;
    signal rx_data_p, rx_data_n   : std_logic_vector(5 downto 0);
    signal tx_clk_p, tx_clk_n     : std_logic;
    signal tx_frame_p, tx_frame_n : std_logic;
    signal tx_data_p, tx_data_n   : std_logic_vector(5 downto 0);
    signal i_tx_i                 : std_logic_vector(11 downto 0) := (others => '0');
    signal i_tx_q                 : std_logic_vector(11 downto 0) := (others => '0');
    signal i_tx_valid             : std_logic := '0';
    signal o_tx_rdy               : std_logic;
    signal o_tx_underrun          : std_logic;
    signal o_clk               : std_logic;
    signal o_rx_i                 : std_logic_vector(11 downto 0);
    signal o_rx_q                 : std_logic_vector(11 downto 0);
    signal o_rx_valid             : std_logic;
    signal o_dbg_rx_frame         : std_logic;

    -- Single-ended stimulus signals (before differential conversion)
    signal rx_clk_se   : std_logic := '0';
    signal rx_frame_se : std_logic := '0';
    signal rx_data_se  : std_logic_vector(5 downto 0) := (others => '0');

    -- Loopback control
    signal loopback_en : std_logic := '0';

    -- TX stimulus counter
    signal tx_sample_count : unsigned(11 downto 0) := (others => '0');

begin

    -- =========================================================================
    -- Clock generation (always from testbench, never looped back)
    -- =========================================================================
    rx_clk_se <= not rx_clk_se after CLK_PERIOD / 2;

    rx_clk_p <= rx_clk_se;
    rx_clk_n <= not rx_clk_se;

    -- =========================================================================
    -- RX input mux: external DDR generator or TX loopback
    -- =========================================================================
    rx_frame_p <= tx_frame_p       when loopback_en = '1' else rx_frame_se;
    rx_frame_n <= tx_frame_n       when loopback_en = '1' else not rx_frame_se;
    rx_data_p  <= tx_data_p        when loopback_en = '1' else rx_data_se;
    rx_data_n  <= tx_data_n        when loopback_en = '1' else not rx_data_se;

    -- =========================================================================
    -- DUT
    -- =========================================================================
    dut : entity work.ad936x_txrx
        port map (
            rx_clk_p       => rx_clk_p,
            rx_clk_n       => rx_clk_n,
            rx_frame_p     => rx_frame_p,
            rx_frame_n     => rx_frame_n,
            rx_data_p      => rx_data_p,
            rx_data_n      => rx_data_n,
            tx_clk_p       => tx_clk_p,
            tx_clk_n       => tx_clk_n,
            tx_frame_p     => tx_frame_p,
            tx_frame_n     => tx_frame_n,
            tx_data_p      => tx_data_p,
            tx_data_n      => tx_data_n,
            i_tx_i         => i_tx_i,
            i_tx_q         => i_tx_q,
            i_tx_valid     => i_tx_valid,
            o_tx_rdy       => o_tx_rdy,
            o_tx_underrun  => o_tx_underrun,
            o_clk       => o_clk,
            o_rx_i         => o_rx_i,
            o_rx_q         => o_rx_q,
            o_rx_valid     => o_rx_valid,
            o_dbg_rx_frame => o_dbg_rx_frame
        );

    -- =========================================================================
    -- RX DDR Stimulus Generator (active when loopback_en = '0')
    --
    -- Mimics AD9361 DDR output. Each IQ sample takes 2 DATA_CLK cycles:
    --   Cycle 0 (frame=1): rise = I[11:6], fall = Q[11:6]
    --   Cycle 1 (frame=0): rise = I[5:0],  fall = Q[5:0]
    --
    -- Data is set up after the opposite edge so it is stable at the
    -- sampling edge. I increments each sample, Q = I + IQ_OFFSET.
    -- =========================================================================
    p_rx_stimulus : process
        variable v_count : unsigned(11 downto 0) := (others => '0');
        variable v_i     : std_logic_vector(11 downto 0);
        variable v_q     : std_logic_vector(11 downto 0);
    begin
        -- Align to first falling edge
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
    -- TX IQ Stimulus
    -- Presents new data only when o_tx_rdy = '1'.
    -- I increments, Q = I + IQ_OFFSET.
    -- =========================================================================
    p_tx_stimulus : process
    begin
        wait until rising_edge(o_clk);
        if o_tx_rdy = '1' and i_tx_valid = '1' then
            tx_sample_count <= tx_sample_count + 1;
        end if;
        i_tx_i <= std_logic_vector(tx_sample_count);
        i_tx_q <= std_logic_vector(tx_sample_count + IQ_OFFSET);
    end process p_tx_stimulus;

    -- =========================================================================
    -- Main test process
    -- =========================================================================
    p_main : process
        variable v_expected_count : unsigned(11 downto 0);
        variable v_expected_i     : std_logic_vector(11 downto 0);
        variable v_expected_q     : std_logic_vector(11 downto 0);
        variable v_samples        : integer := 0;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- =================================================================
            -- Test: RX deserialize (external DDR stimulus)
            -- =================================================================
            if run("rx_deserialize") then
                info("Starting RX deserialization check");
                loopback_en <= '0';
                i_tx_valid  <= '0';

                wait for 20 * CLK_PERIOD;
                wait until rising_edge(o_clk) and o_rx_valid = '1';
                v_expected_count := unsigned(o_rx_i) + 1;

                v_samples := 0;
                while v_samples < NUM_SAMPLES loop
                    wait until rising_edge(o_clk) and o_rx_valid = '1';

                    v_expected_i := std_logic_vector(v_expected_count);
                    v_expected_q := std_logic_vector(v_expected_count + IQ_OFFSET);

                    check_equal(o_rx_i, v_expected_i,
                        "Sample " & integer'image(v_samples) & " I mismatch");
                    check_equal(o_rx_q, v_expected_q,
                        "Sample " & integer'image(v_samples) & " Q mismatch");

                    v_expected_count := v_expected_count + 1;
                    v_samples := v_samples + 1;
                end loop;

                info("RX check passed: " & integer'image(v_samples) & " samples OK");
            end if;

            -- =================================================================
            -- Test: TX loopback (TX -> LVDS -> RX, verify round-trip)
            -- =================================================================
            if run("tx_loopback") then
                info("Starting TX loopback check");
                loopback_en <= '1';
                i_tx_valid  <= '1';

                -- Wait for pipeline warmup
                wait for 20 * CLK_PERIOD;

                -- Sync to first valid output
                wait until rising_edge(o_clk) and o_rx_valid = '1';
                v_expected_count := unsigned(o_rx_i) + 1;

                -- Verify consecutive samples
                v_samples := 0;
                while v_samples < NUM_SAMPLES loop
                    wait until rising_edge(o_clk) and o_rx_valid = '1';

                    v_expected_i := std_logic_vector(v_expected_count);
                    v_expected_q := std_logic_vector(v_expected_count + IQ_OFFSET);

                    check_equal(o_rx_i, v_expected_i,
                        "TX loopback sample " & integer'image(v_samples) & " I mismatch");
                    check_equal(o_rx_q, v_expected_q,
                        "TX loopback sample " & integer'image(v_samples) & " Q mismatch");
                    check_equal(o_tx_underrun, '0',
                        "TX underrun during sample " & integer'image(v_samples));

                    v_expected_count := v_expected_count + 1;
                    v_samples := v_samples + 1;
                end loop;

                info("TX loopback passed: " & integer'image(v_samples) & " samples OK");
            end if;

            -- =================================================================
            -- Test: TX underrun (pause valid, verify underrun pulse + repeat)
            -- =================================================================
            if run("tx_underrun") then
                info("Starting TX underrun check");
                loopback_en <= '1';
                i_tx_valid  <= '1';

                -- Let a few samples through
                wait for 20 * CLK_PERIOD;
                wait until rising_edge(o_clk) and o_rx_valid = '1';
                wait until rising_edge(o_clk) and o_rx_valid = '1';

                -- Deassert valid to cause underrun
                i_tx_valid <= '0';

                -- Wait for underrun to appear
                wait until rising_edge(o_clk) and o_tx_underrun = '1';
                info("Underrun detected");

                -- Wait for pipeline to flush (ODDR+OBUFDS+IBUFDS+IDDR+deser)
                for i in 0 to 3 loop
                    wait until rising_edge(o_clk) and o_rx_valid = '1';
                end loop;

                -- Now capture a sample — should be the repeated value
                v_expected_i := o_rx_i;
                v_expected_q := o_rx_q;

                -- Verify the NEXT sample is the same (held/repeated)
                wait until rising_edge(o_clk) and o_rx_valid = '1';
                check_equal(o_rx_i, v_expected_i, "Sample should repeat after underrun (I)");
                check_equal(o_rx_q, v_expected_q, "Sample should repeat after underrun (Q)");

                -- Re-enable valid, verify recovery
                i_tx_valid <= '1';
                wait for 10 * CLK_PERIOD;
                wait until rising_edge(o_clk) and o_rx_valid = '1';
                check_equal(o_tx_underrun, '0', "No underrun after recovery");

                info("TX underrun check passed");
            end if;

        end loop;

        test_runner_cleanup(runner);
    end process p_main;

    -- Watchdog: fail if test hangs
    test_runner_watchdog(runner, 100 us);

end architecture sim;
