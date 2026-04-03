-- Behavioral stub for Xilinx ODDR (no VITAL/vpkg dependency)
-- Based on Xilinx functional simulation model, simplified for GHDL.

library ieee;
use ieee.std_logic_1164.all;

entity ODDR is
  generic (
    DDR_CLK_EDGE   : string := "OPPOSITE_EDGE";
    INIT           : bit    := '0';
    IS_C_INVERTED  : bit    := '0';
    IS_D1_INVERTED : bit    := '0';
    IS_D2_INVERTED : bit    := '0';
    SRTYPE         : string := "SYNC"
  );
  port (
    Q  : out std_ulogic;
    C  : in  std_ulogic;
    CE : in  std_ulogic;
    D1 : in  std_ulogic;
    D2 : in  std_ulogic;
    R  : in  std_ulogic := '0';
    S  : in  std_ulogic := '0'
  );
end entity ODDR;

architecture behavioral of ODDR is
  signal C_int  : std_ulogic;
  signal D1_int : std_ulogic;
  signal D2_int : std_ulogic;
  signal Q_int  : std_ulogic := to_x01(INIT);
  signal D2_latched : std_ulogic := to_x01(INIT);
begin

  C_int  <= C  xor to_x01(IS_C_INVERTED);
  D1_int <= D1 xor to_x01(IS_D1_INVERTED);
  D2_int <= D2 xor to_x01(IS_D2_INVERTED);

  process (C_int, R, S) is
  begin
    -- Async reset/set
    if (SRTYPE = "ASYNC" or SRTYPE = "async") and R = '1' then
      Q_int <= '0'; D2_latched <= '0';
    elsif (SRTYPE = "ASYNC" or SRTYPE = "async") and S = '1' then
      Q_int <= '1'; D2_latched <= '1';
    elsif rising_edge(C_int) then
      if R = '1' then
        Q_int <= '0'; D2_latched <= '0';
      elsif S = '1' then
        Q_int <= '1'; D2_latched <= '1';
      elsif CE = '1' then
        Q_int      <= D1_int;
        D2_latched <= D2_int;
      elsif CE = '0' then
        D2_latched <= Q_int;
      end if;
    elsif falling_edge(C_int) then
      if R = '1' then
        Q_int <= '0';
      elsif S = '1' then
        Q_int <= '1';
      elsif CE = '1' then
        if DDR_CLK_EDGE = "OPPOSITE_EDGE" or DDR_CLK_EDGE = "opposite_edge" then
          Q_int <= D2_int;
        else -- SAME_EDGE
          Q_int <= D2_latched;
        end if;
      end if;
    end if;
  end process;

  Q <= Q_int;

end architecture behavioral;
