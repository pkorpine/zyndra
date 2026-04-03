-- Behavioral stub for Xilinx IDDR (no VITAL/vpkg dependency)
-- Based on Xilinx functional simulation model, simplified for GHDL.

library ieee;
use ieee.std_logic_1164.all;

entity IDDR is
  generic (
    DDR_CLK_EDGE  : string := "OPPOSITE_EDGE";
    INIT_Q1       : bit    := '0';
    INIT_Q2       : bit    := '0';
    IS_C_INVERTED : bit    := '0';
    IS_D_INVERTED : bit    := '0';
    SRTYPE        : string := "SYNC"
  );
  port (
    Q1 : out std_ulogic;
    Q2 : out std_ulogic;
    C  : in  std_ulogic;
    CE : in  std_ulogic;
    D  : in  std_ulogic;
    R  : in  std_ulogic := '0';
    S  : in  std_ulogic := '0'
  );
end entity IDDR;

architecture behavioral of IDDR is
  signal C_int : std_ulogic;
  signal D_int : std_ulogic;
  signal q1_reg, q2_reg, q3_reg, q4_reg : std_ulogic := '0';
begin

  C_int <= C xor to_x01(IS_C_INVERTED);
  D_int <= D xor to_x01(IS_D_INVERTED);

  process (C_int, R, S) is
  begin
    -- Async reset/set
    if (SRTYPE = "ASYNC" or SRTYPE = "async") and R = '1' then
      q1_reg <= '0'; q2_reg <= '0'; q3_reg <= '0'; q4_reg <= '0';
    elsif (SRTYPE = "ASYNC" or SRTYPE = "async") and S = '1' then
      q1_reg <= '1'; q2_reg <= '1'; q3_reg <= '1'; q4_reg <= '1';
    elsif rising_edge(C_int) then
      if R = '1' then
        q1_reg <= '0'; q3_reg <= '0'; q4_reg <= '0';
      elsif S = '1' then
        q1_reg <= '1'; q3_reg <= '1'; q4_reg <= '1';
      elsif CE = '1' then
        q3_reg <= q1_reg;
        q1_reg <= D_int;
        q4_reg <= q2_reg;
      end if;
    elsif falling_edge(C_int) then
      if R = '1' then
        q2_reg <= '0';
      elsif S = '1' then
        q2_reg <= '1';
      elsif CE = '1' then
        q2_reg <= D_int;
      end if;
    end if;
  end process;

  -- Output mux based on DDR_CLK_EDGE mode
  Q1 <= q1_reg when DDR_CLK_EDGE = "OPPOSITE_EDGE" or DDR_CLK_EDGE = "opposite_edge" else
        q1_reg when DDR_CLK_EDGE = "SAME_EDGE"      or DDR_CLK_EDGE = "same_edge" else
        q3_reg;  -- SAME_EDGE_PIPELINED

  Q2 <= q2_reg when DDR_CLK_EDGE = "OPPOSITE_EDGE" or DDR_CLK_EDGE = "opposite_edge" else
        q4_reg;  -- SAME_EDGE or SAME_EDGE_PIPELINED

end architecture behavioral;
