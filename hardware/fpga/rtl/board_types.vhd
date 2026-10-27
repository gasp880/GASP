library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
package board_types is
 type epoch_array is array(natural range <>) of unsigned(31 downto 0);
 type word_array is array(natural range <>) of std_logic_vector(31 downto 0);
 type meta_array is array(natural range <>) of std_logic_vector(12 downto 0);
end package;
