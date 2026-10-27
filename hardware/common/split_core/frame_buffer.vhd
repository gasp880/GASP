-- Single-write, synchronous-read frame bank. No reset on stored data.
library ieee;
use ieee.std_logic_1164.all;
use work.network_types.all;

entity frame_buffer is
  generic (MAX_BYTES : positive := 128);
  port (clk, write_enable, read_enable : in std_logic;
    write_address, read_address : in natural range 0 to MAX_BYTES-1;
    write_data : in byte_t; read_data : out byte_t);
end entity;

architecture rtl of frame_buffer is
  type memory_t is array(0 to MAX_BYTES-1) of byte_t;
  signal memory : memory_t;
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if write_enable = '1' then memory(write_address) <= write_data; end if;
      if read_enable = '1' then read_data <= memory(read_address); end if;
    end if;
  end process;
end architecture;
