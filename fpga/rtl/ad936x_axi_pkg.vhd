--------------------------------------------------------------------------------
-- Title       : AD936x AXI Package
-- Project     : Zyndra
-- Author      : Pekka Korpinen <pekka.korpinen@iki.fi>
-- License     : MIT
--------------------------------------------------------------------------------
-- Description :
--   Register address map, control bit constants, and AXI record type
--   definitions for the ad936x_axi peripheral.
--
-- History :
--  2026-03-09 PKo
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package ad936x_axi_pkg is

    subtype t_regaddr is unsigned(7 downto 0);

    constant c_reg_info : t_regaddr := 8x"00"; -- R   : magic 0xAD93_<VERSION>
    constant c_reg_ctrl : t_regaddr := 8x"04"; -- R/W : [0] reset, [1] rx_enable, [2] tx_enable

    -- CTRL register bit positions
    constant c_ctrl_reset      : natural   := 0;
    constant c_ctrl_rx_enable  : natural   := 1;
    constant c_ctrl_tx_enable  : natural   := 2;
    constant c_reg_tx_underrun : t_regaddr := 8x"08"; -- R   : TX underrun counter
    constant c_reg_rx_overflow : t_regaddr := 8x"0C"; -- R   : RX overflow (drop) counter
    constant c_reg_rx_buf_base : t_regaddr := 8x"10"; -- R/W : RX ring buffer base address
    constant c_reg_rx_buf_size : t_regaddr := 8x"14"; -- R/W : RX ring buffer size in bytes
    constant c_reg_rx_buf_wr   : t_regaddr := 8x"1C"; -- R   : RX write pointer (HW → SW)
    constant c_reg_tx_buf_base : t_regaddr := 8x"20"; -- R/W : TX ring buffer base address
    constant c_reg_tx_buf_size : t_regaddr := 8x"24"; -- R/W : TX ring buffer size in bytes
    constant c_reg_tx_buf_rd   : t_regaddr := 8x"28"; -- R   : TX read pointer (HW → SW)
    constant c_reg_tx_buf_wr   : t_regaddr := 8x"2C"; -- R/W : TX write pointer (SW → HW)

    ---------------------------------------------------------------------------
    -- AXI4-Lite record types (mosi = master-out/slave-in, miso = reverse)
    ---------------------------------------------------------------------------
    type t_axi4l_mosi is record
        awaddr  : std_logic_vector(31 downto 0);
        awprot  : std_logic_vector(2 downto 0);
        awvalid : std_logic;
        wdata   : std_logic_vector(31 downto 0);
        wstrb   : std_logic_vector(3 downto 0);
        wvalid  : std_logic;
        bready  : std_logic;
        araddr  : std_logic_vector(31 downto 0);
        arprot  : std_logic_vector(2 downto 0);
        arvalid : std_logic;
        rready  : std_logic;
    end record t_axi4l_mosi;

    type t_axi4l_miso is record
        awready : std_logic;
        wready  : std_logic;
        bvalid  : std_logic;
        bresp   : std_logic_vector(1 downto 0);
        arready : std_logic;
        rvalid  : std_logic;
        rdata   : std_logic_vector(31 downto 0);
        rresp   : std_logic_vector(1 downto 0);
    end record t_axi4l_miso;

    ---------------------------------------------------------------------------
    -- AXI4 record types (64-bit data, burst)
    ---------------------------------------------------------------------------
    type t_axi4_mosi is record
        awaddr  : std_logic_vector(31 downto 0);
        awlen   : std_logic_vector(7 downto 0);
        awsize  : std_logic_vector(2 downto 0);
        awburst : std_logic_vector(1 downto 0);
        awvalid : std_logic;
        wdata   : std_logic_vector(63 downto 0);
        wstrb   : std_logic_vector(7 downto 0);
        wlast   : std_logic;
        wvalid  : std_logic;
        bready  : std_logic;
        araddr  : std_logic_vector(31 downto 0);
        arlen   : std_logic_vector(7 downto 0);
        arsize  : std_logic_vector(2 downto 0);
        arburst : std_logic_vector(1 downto 0);
        arvalid : std_logic;
        rready  : std_logic;
    end record t_axi4_mosi;

    type t_axi4_miso is record
        awready : std_logic;
        wready  : std_logic;
        bvalid  : std_logic;
        bresp   : std_logic_vector(1 downto 0);
        arready : std_logic;
        rdata   : std_logic_vector(63 downto 0);
        rlast   : std_logic;
        rvalid  : std_logic;
        rresp   : std_logic_vector(1 downto 0);
    end record t_axi4_miso;

end package ad936x_axi_pkg;
