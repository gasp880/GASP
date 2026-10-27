library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package network_types is
  subtype byte_t is std_logic_vector(7 downto 0);
  type natural_array is array (natural range <>) of natural;
  type hash_array is array (natural range <>) of unsigned(31 downto 0);
  type frame_config is record
    source, destination : natural range 0 to 4;
    period_ticks, offset_ticks, deadline_ticks : natural;
    length_bytes : natural;
    critical : std_logic;
    refresh_crc : std_logic;
  end record;
  type config_array is array (natural range <>) of frame_config;
  constant EMPTY_CONFIG : frame_config := (0, 1, 1, 0, 1, 64, '1', '1');
  function hash_byte(h : unsigned(31 downto 0); b : byte_t) return unsigned;
  function crc_byte(crc : unsigned(31 downto 0); b : byte_t) return unsigned;
end package;

package body network_types is
  function hash_byte(h : unsigned(31 downto 0); b : byte_t) return unsigned is
  begin
    return rotate_left(h, 1) xor resize(unsigned(b), 32);
  end;
  function crc_byte(crc : unsigned(31 downto 0); b : byte_t) return unsigned is
    variable v : unsigned(31 downto 0) := crc xor resize(unsigned(b), 32);
  begin
    for bit_id in 0 to 7 loop
      if v(0) = '1' then v := shift_right(v, 1) xor x"EDB88320";
      else v := shift_right(v, 1); end if;
    end loop;
    return v;
  end;
end package body;
