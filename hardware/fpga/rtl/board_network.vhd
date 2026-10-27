-- Five-gateway logical network including shared member epoch generation.
-- Pure hierarchy extraction: every byte/event remains on its original edge.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.network_types.all;
use work.board_types.all;
entity board_network is
 generic(FRAMES_PER_PORT:positive:=36;MAX_BYTES:positive:=288;PERIOD_BANKS:positive:=8;
   MAX_PERIOD_TICKS:positive:=10000000;GUARD_TICKS:natural:=12336);
 port(clk,core_reset,running,cfg_we,data_we:in std_logic;
   cfg_slot,data_slot,slot_sel:in natural range 0 to 5*FRAMES_PER_PORT-1;
   cfg_value:in frame_config;data_addr:in natural range 0 to MAX_BYTES-1;
   byte_sel:in natural range 0 to MAX_BYTES;data_value:in std_logic_vector(12 downto 0);
   active:in std_logic_vector(5*FRAMES_PER_PORT-1 downto 0);
   period_words:in word_array(0 to PERIOD_BANKS-1);now_tick:in natural;
   debug_word:out std_logic_vector(12 downto 0);
   source_tx,source_error,source_gate:out std_logic_vector(5*FRAMES_PER_PORT-1 downto 0);
   down,sw_error,sw_gate:out std_logic_vector(5*FRAMES_PER_PORT-1 downto 0);
   dv,dl:out std_logic_vector(4 downto 0);df,di:out natural_array(0 to 4);
   ddata:out std_logic_vector(39 downto 0));
end;
architecture rtl of board_network is
 constant FRAME_COUNT:positive:=5*FRAMES_PER_PORT;
 type local_events is array(0 to 4) of std_logic_vector(FRAMES_PER_PORT-1 downto 0);
 type local_epochs is array(0 to 4) of epoch_array(0 to PERIOD_BANKS-1);
 type meta_ports is array(0 to 4) of std_logic_vector(4 downto 0);
 type debug_ports is array(0 to 4) of std_logic_vector(12 downto 0);
 type period_array is array(0 to PERIOD_BANKS-1) of natural range 0 to MAX_PERIOD_TICKS;
 signal period_config,period_phase:period_array:=(others=>0);
 signal epochs:epoch_array(0 to PERIOD_BANKS-1):=(others=>(others=>'0'));
 signal snapshots:local_epochs;signal meta:meta_ports;signal debug_data:debug_ports;
 signal raw,transformed,udata:std_logic_vector(39 downto 0);
 signal uv,ul:std_logic_vector(4 downto 0);
 signal uf_local,uf,ui,snaps:natural_array(0 to 4);
 signal gt,ge,gg:local_events;
 signal queued:std_logic_vector(FRAME_COUNT-1 downto 0);
begin
 periods:for b in 0 to PERIOD_BANKS-1 generate
   period_config(b)<=to_integer(unsigned(period_words(b)));
 end generate;
 ports:for p in 0 to 4 generate
   source_tx((p+1)*FRAMES_PER_PORT-1 downto p*FRAMES_PER_PORT)<=gt(p);
   source_error((p+1)*FRAMES_PER_PORT-1 downto p*FRAMES_PER_PORT)<=ge(p);
   source_gate((p+1)*FRAMES_PER_PORT-1 downto p*FRAMES_PER_PORT)<=gg(p);
 end generate;
 debug_word<=debug_data(slot_sel/FRAMES_PER_PORT);
 process(clk)
 begin
   if rising_edge(clk) then
     if core_reset='1' then period_phase<=(others=>0);epochs<=(others=>(others=>'0'));
     elsif running='1' then
       for b in 0 to PERIOD_BANKS-1 loop
         if period_config(b)>0 then
           if period_phase(b)=period_config(b)-1 then period_phase(b)<=0;epochs(b)<=epochs(b)+1;
           else period_phase(b)<=period_phase(b)+1;end if;
         end if;
       end loop;
     end if;
   end if;
 end process;
 gateways:for p in 0 to 4 generate
   signal local_we,local_data:std_logic;signal local_index:natural range 0 to FRAMES_PER_PORT-1;
   signal selected_index:natural range 0 to FRAMES_PER_PORT-1;
   signal selected_address:natural range 0 to MAX_BYTES-1;
 begin
   local_we<=cfg_we when cfg_slot/FRAMES_PER_PORT=p else '0';
   local_data<=data_we when data_slot/FRAMES_PER_PORT=p else '0';
   local_index<=cfg_slot mod FRAMES_PER_PORT when cfg_we='1' else data_slot mod FRAMES_PER_PORT when data_we='1' else slot_sel mod FRAMES_PER_PORT;
   selected_address<=data_addr when data_we='1' else byte_sel mod MAX_BYTES;
   gateway:entity work.board_gateway generic map(FRAMES_PER_PORT,MAX_BYTES,GUARD_TICKS,p,MAX_PERIOD_TICKS,PERIOD_BANKS)
     port map(clk,core_reset,running,local_we,local_data,local_index,cfg_value,selected_address,data_value,
       active((p+1)*FRAMES_PER_PORT-1 downto p*FRAMES_PER_PORT),epochs,snapshots(p),'1',debug_data(p),meta(p),
       now_tick,queued((p+1)*FRAMES_PER_PORT-1 downto p*FRAMES_PER_PORT),raw(p*8+7 downto p*8),
       transformed(p*8+7 downto p*8),snaps(p),uv(p),uf_local(p),ui(p),udata(p*8+7 downto p*8),ul(p),gt(p),ge(p),gg(p));
   uf(p)<=p*FRAMES_PER_PORT+uf_local(p);
   process(all)
     variable b:natural range 0 to 7;variable e:unsigned(31 downto 0);variable v:unsigned(7 downto 0);
   begin
     b:=to_integer(unsigned(meta(p)(2 downto 0)));e:=(others=>'0');v:=unsigned(raw(p*8+7 downto p*8));
     if b<PERIOD_BANKS then e:=snapshots(p)(b);end if;
     case meta(p)(4 downto 3) is
       when "01"=>v:=e(15 downto 8);when "10"=>v:=e(7 downto 0);
       when "11"=>v:=v+e(7 downto 0);when others=>null;
     end case;
     transformed(p*8+7 downto p*8)<=std_logic_vector(v);
   end process;
 end generate;
 switch_core:entity work.board_switch generic map(FRAME_COUNT,MAX_BYTES,GUARD_TICKS,MAX_PERIOD_TICKS)
   port map(clk,core_reset,running,cfg_we,cfg_slot,cfg_value,active,uv,ul,uf,ui,udata,queued,dv,dl,df,di,ddata,down,sw_error,sw_gate);

end;
