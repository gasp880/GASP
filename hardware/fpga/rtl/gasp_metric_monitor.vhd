-- Dedicated synchronous RAM boundary prevents synthesis from coalescing the
-- five destination replicas into a multi-read LUTRAM. Both outputs retain the
-- original one-clock READ_FIRST latency. The RAM contents are only written
-- through the explicit port; runtime resets never clear memory asynchronously.
library ieee;
use ieee.std_logic_1164.all;
entity gasp_monitor_ram is
 generic(DEPTH:positive; WIDTH:positive);
 port(clk:in std_logic; we:in std_logic;
   addr_a,addr_b:in natural range 0 to DEPTH-1;
   din:in std_logic_vector(WIDTH-1 downto 0);
   dout_a,dout_b:out std_logic_vector(WIDTH-1 downto 0));
end entity;
architecture rtl of gasp_monitor_ram is
 type ram_array is array(0 to DEPTH-1) of std_logic_vector(WIDTH-1 downto 0);
 signal memory:ram_array:=(others=>(others=>'0'));
 attribute ram_style:string;
 attribute ram_style of memory:signal is "block";
 attribute keep_hierarchy:string;
 attribute keep_hierarchy of rtl:architecture is "yes";
begin
 process(clk)
 begin
   if rising_edge(clk) then
     if we='1' then memory(addr_a)<=din;end if;
     dout_a<=memory(addr_a);dout_b<=memory(addr_b);
   end if;
 end process;
end architecture;

-- Hardware-only acceptance measurement. Host writes input member descriptors,
-- never observed successes, totals, masks, or percentages. RX bytes are captured
-- and checked independently of the existing capture RAM/host analyzer.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.network_types.all;
use work.board_types.all;
entity gasp_metric_monitor is
 generic(FRAMES_PER_PORT:positive:=36; MAX_BYTES:positive:=288;
   PERIOD_BANKS:positive:=8; MAX_GROUPS:positive:=640; MAX_EPOCHS:positive:=1024);
 port(clk,resetn,running,run_clear:in std_logic;
   window_ticks,now_tick:in natural;
   -- Observe the exact latched configuration bus consumed by board_network.
   frame_cfg_we:in std_logic;
   frame_cfg_slot:in natural range 0 to 5*FRAMES_PER_PORT-1;
   frame_cfg_value:in frame_config;
   frame_cache_ready:out std_logic;
   frame_enabled:in std_logic_vector(5*FRAMES_PER_PORT-1 downto 0);
   period_words:in word_array(0 to PERIOD_BANKS-1);
   rx_valid,rx_last:in std_logic_vector(4 downto 0);
   rx_frame,rx_index:in natural_array(0 to 4);
   rx_data:in std_logic_vector(39 downto 0);
   cfg_we:in std_logic; cfg_addr:in std_logic_vector(7 downto 0);
   cfg_wdata:in std_logic_vector(31 downto 0);
   read_addr:in std_logic_vector(7 downto 0); read_data:out std_logic_vector(31 downto 0);
   metric_result_valid:out std_logic;
   metric_case_n,metric_total,metric_complete,metric_isolated,
   metric_acceptance_x100,metric_error_flags:out std_logic_vector(31 downto 0));
end;
architecture rtl of gasp_metric_monitor is
 constant FRAME_COUNT:positive:=5*FRAMES_PER_PORT;
 constant FRAME_META_WIDTH:positive:=101;
 subtype frame_meta_t is std_logic_vector(FRAME_META_WIDTH-1 downto 0);
 signal frame_meta_write:frame_meta_t;
 constant MEMBERS:positive:=MAX_GROUPS*4;
 constant DESC_WORDS:positive:=MEMBERS*5;
 constant BANKS:positive:=4;
 -- Compact per-UID state: generation8, flags8, last epoch16,
 -- due first-valid16, due on-time16, duplicates32, reserved8.
 subtype seen_t is std_logic_vector(103 downto 0);
 subtype anomaly_t is std_logic_vector(127 downto 0);
 type anomaly_array is array(0 to 10) of anomaly_t;
 type anomaly_counts is array(0 to 10) of natural range 0 to 512;
 type anomaly_ram is array(0 to 511) of anomaly_t;
 type due_array is array(0 to MEMBERS-1) of std_logic_vector(31 downto 0);
 type group_array is array(0 to MAX_GROUPS-1) of std_logic_vector(2 downto 0);
 signal anomaly_push:std_logic_vector(10 downto 0):=(others=>'0');
 signal anomaly_in,anomaly_out:anomaly_array;
 signal anomaly_count:anomaly_counts:=(others=>0);
 signal anomaly_overflow:std_logic_vector(10 downto 0):=(others=>'0');
 signal selected_lane:natural range 0 to 4:=0;
 signal selected_group:natural range 0 to MAX_GROUPS-1:=0;
 signal selected_queue:natural range 0 to 10:=0;
 signal selected_record:natural range 0 to 511:=0;
 signal selected_record_word:natural range 0 to 3:=0;
 signal due_ram:due_array;
 signal due_read:std_logic_vector(31 downto 0);
 signal due_write:std_logic:='0';
 signal group_results:group_array;
 signal selected_seen:seen_t;

 type five_words is array(0 to 4) of std_logic_vector(31 downto 0);
 type five_seen is array(0 to 4) of seen_t;
 signal lane_readback:five_seen;
 type five_nat is array(0 to 4) of natural;
 type four_nat is array(0 to 3) of natural;
 type four_bit is array(0 to 3) of std_logic;
 type phase_array is array(0 to PERIOD_BANKS-1) of natural;
 type desc_array is array(0 to DESC_WORDS-1) of std_logic_vector(31 downto 0);
 type seen_array is array(0 to MEMBERS-1) of seen_t;
 type raw_array is array(0 to BANKS*MAX_BYTES-1) of byte_t;
 signal clear_busy,committed,result_valid:std_logic:='0';
 signal clear_index:natural range 0 to DESC_WORDS-1:=0;
 signal selected_key:natural range 0 to MEMBERS-1:=0;
 signal selected_word:natural range 0 to 4:=0;
 signal case_n:std_logic_vector(31 downto 0):=(others=>'0');
 signal generation:unsigned(7 downto 0):=(others=>'0');
 signal desc_write:std_logic;
 signal config_errors,summary_errors:std_logic_vector(31 downto 0):=(others=>'0');
 signal phase:phase_array:=(others=>0);
 signal previous_running:std_logic:='0';
 signal summary_requested:std_logic:='0';
 signal lane_busy,lane_pending:std_logic_vector(4 downto 0):=(others=>'0');
 signal lane_errors:word_array(0 to 4):=(others=>(others=>'0'));
 signal lane_frames,lane_crc,lane_bad,lane_duplicate,lane_late:five_nat:=(others=>0);
 signal summary_desc:five_words;
 signal summary_seen:five_seen;
 signal summary_key:natural range 0 to MEMBERS-1:=0;
 signal summary_word:natural range 0 to 4:=0;
 signal summary_mode:std_logic:='0';
 type summary_state is (S_IDLE,S_WAIT,S_REQ,S_GET,S_MEMBER,S_DUE,S_CHECK,S_GROUP,S_DIV,S_DONE);
 signal ss:summary_state:=S_IDLE;
 signal sd:five_words:=(others=>(others=>'0'));
 signal summary_group:natural range 0 to MAX_GROUPS-1:=0;
 signal summary_member:natural range 0 to 3:=0;
 signal group_present,group_complete,group_isolated:std_logic:='0';
 signal group_slots:four_nat:=(others=>255);
 signal group_slot_count:natural range 0 to 4:=0;
 signal member_first,member_ontime,member_last:natural range 0 to 65535:=0;
 signal member_has_seen:std_logic:='0';
 signal member_lanes:natural range 0 to 5:=0;
 signal due_epoch:natural range 0 to MAX_EPOCHS:=0;
 signal due_deadline:unsigned(32 downto 0):=(others=>'0');

 signal total_i,complete_i,isolated_i,rate_i,missing_i:natural:=0;
 signal div_remainder:natural:=0;
 signal all_errors:std_logic_vector(31 downto 0);
 function word(n:natural) return std_logic_vector is begin return std_logic_vector(to_unsigned(n,32));end;
 function anomaly(tick,key,epoch,reason,slot,last_epoch,detail:natural) return anomaly_t is
 begin
   return word(detail)&std_logic_vector(to_unsigned(last_epoch mod 65536,16))&
     std_logic_vector(to_unsigned(slot mod 256,8))&std_logic_vector(to_unsigned(reason mod 256,8))&
     std_logic_vector(to_unsigned(epoch mod 65536,16))&std_logic_vector(to_unsigned(key mod 65536,16))&word(tick);
 end;
 function header_byte(i:natural;c:frame_config) return byte_t is
 begin
   case i is
     when 0|6=>return x"02";
     when 5=>return std_logic_vector(to_unsigned(c.destination+1,8));
     when 11=>return std_logic_vector(to_unsigned(c.source+1,8));
     when 12=>return x"81";
     when 14=>if c.critical='1' then return x"E0";else return x"00";end if;
     when 15=>return x"01";
     when 16=>return x"88";
     when 17=>return x"B5";
     when others=>return x"00";
   end case;
 end;
begin
 assert MAX_EPOCHS<=65536 and MAX_GROUPS<=16384 and MAX_BYTES>=64 severity failure;
 -- One common packed write value fans out to five independent synchronous
 -- BRAM read replicas. Validity is stored in each initialized RAM row. RAM is
 -- not cleared by runtime reset, just like the executor's frame configuration.
 frame_meta_write<= '1' & std_logic_vector(to_unsigned(frame_cfg_value.length_bytes,31)) &
   std_logic_vector(to_unsigned(frame_cfg_value.offset_ticks,31)) &
   std_logic_vector(to_unsigned(frame_cfg_value.period_ticks,31)) & frame_cfg_value.critical &
   std_logic_vector(to_unsigned(frame_cfg_value.destination,3)) &
   std_logic_vector(to_unsigned(frame_cfg_value.source,3));
 frame_cache_ready<=not frame_cfg_we;
 desc_write<='1' when cfg_we='1' and cfg_addr=x"14" and clear_busy='0' and running='0' and ss=S_IDLE else '0';
 selected_seen<=lane_readback(selected_lane);
 queues:for q in 0 to 10 generate
   signal records:anomaly_ram;
   attribute ram_style:string;
   attribute ram_style of records:signal is "block";
 begin
   process(clk)
   begin
     if rising_edge(clk) then
       if anomaly_push(q)='1' and anomaly_count(q)<512 then records(anomaly_count(q))<=anomaly_in(q);end if;
       anomaly_out(q)<=records(selected_record);
       if resetn='0' or run_clear='1' or clear_busy='1' then
         anomaly_count(q)<=0;anomaly_overflow(q)<='0';
       elsif anomaly_push(q)='1' then
         if anomaly_count(q)=512 then anomaly_overflow(q)<='1';else anomaly_count(q)<=anomaly_count(q)+1;end if;
       end if;
     end if;
   end process;
 end generate;
 process(clk)
 begin
   if rising_edge(clk) then
     if due_write='1' then due_ram(summary_key)<=word(due_epoch);end if;
     due_read<=due_ram(selected_key);
     if ss=S_GROUP then
       group_results(summary_group)<=(group_isolated and group_complete and group_present) &
         (group_complete and group_present) & group_present;
     end if;
   end if;
 end process;
 metric_result_valid<=result_valid;metric_case_n<=case_n;
 metric_total<=word(total_i);metric_complete<=word(complete_i);metric_isolated<=word(isolated_i);
 metric_acceptance_x100<=word(rate_i);metric_error_flags<=all_errors;
 process(all)
   variable flags:std_logic_vector(31 downto 0);
   variable frames,crcs,bad,dups,late:natural;
 begin
   flags:=config_errors or summary_errors;frames:=0;crcs:=0;bad:=0;dups:=0;late:=0;
   for p in 0 to 4 loop
     flags:=flags or lane_errors(p);frames:=frames+lane_frames(p);crcs:=crcs+lane_crc(p);
     bad:=bad+lane_bad(p);dups:=dups+lane_duplicate(p);late:=late+lane_late(p);
   end loop;
   if anomaly_overflow/=(anomaly_overflow'range=>'0') then flags(11):='1';end if;
   all_errors<=flags;read_data<=(others=>'0');
   case to_integer(unsigned(read_addr)) is
     when 0=>read_data<=x"47534D31";
     when 8=>read_data<=case_n;
     when 12=>read_data<=word(selected_key);
     when 16=>read_data<=word(selected_word);
     when 20=>read_data<=summary_desc(0);
     when 24=>read_data(0)<=clear_busy;read_data(1)<=clear_busy;read_data(2)<=committed;
       if ss/=S_IDLE then read_data(3)<='1';end if;read_data(4)<=result_valid;
       if lane_busy/="00000" then read_data(5)<='1';end if;
       if lane_pending/="00000" then read_data(6)<='1';end if;
     when 28=>read_data<=flags;
     when 32=>read_data<=word(total_i);
     when 36=>read_data<=word(complete_i);
     when 40=>read_data<=word(isolated_i);
     when 44=>read_data<=word(rate_i);
     when 48=>read_data<=word(frames);
     when 52=>read_data<=word(crcs);
     when 56=>read_data<=word(bad);
     when 60=>read_data<=word(dups);
     when 64=>read_data<=word(late);
     when 68=>read_data<=word(missing_i);
     when 72=>read_data<=word(MAX_GROUPS);
     when 76=>read_data<=word(MAX_EPOCHS);
     when 80=>read_data<=std_logic_vector(resize(generation,32));
     when 84=>if selected_seen(103 downto 96)=std_logic_vector(generation) then read_data<=x"0000"&selected_seen(71 downto 56);end if;
     when 88=>if selected_seen(103 downto 96)=std_logic_vector(generation) then read_data<=x"0000"&selected_seen(55 downto 40);end if;
     when 92=>if selected_seen(103 downto 96)=std_logic_vector(generation) then read_data<=x"0000"&selected_seen(87 downto 72);end if;
     when 96=>if selected_seen(103 downto 96)=std_logic_vector(generation) then read_data<=selected_seen(39 downto 8);end if;
     when 100=>if selected_seen(103 downto 96)=std_logic_vector(generation) then read_data<=x"000000"&selected_seen(95 downto 88);end if;
     when 104=>read_data<=word(selected_group);
     when 108=>if result_valid='1' then read_data(2 downto 0)<=group_results(selected_group);end if;
     when 112=>read_data<=word(selected_queue);
     when 116=>read_data<=word(selected_record);
     when 120=>read_data<=word(selected_record_word);
     when 124=>read_data<=anomaly_out(selected_queue)(selected_record_word*32+31 downto selected_record_word*32);
     when 128=>read_data<=word(anomaly_count(selected_queue));
     when 132=>read_data(10 downto 0)<=anomaly_overflow;
     when 136=>read_data<=word(selected_lane);
     when 140=>read_data<=due_read;
     when others=>null;
   end case;
 end process;
 -- Runtime reset changes a tag, not thousands of RAM entries. An explicit
 -- descriptor CLEAR also scrubs tags so generation wrap cannot reuse old data.
 process(clk)
   variable a,v:natural;
 begin
   if rising_edge(clk) then
     previous_running<=running;
     if resetn='0' then
       clear_busy<='0';committed<='0';selected_key<=0;selected_word<=0;case_n<=(others=>'0');
       selected_lane<=0;selected_group<=0;selected_queue<=0;selected_record<=0;selected_record_word<=0;
       generation<=(others=>'0');config_errors<=(others=>'0');phase<=(others=>0);
     else
       if clear_busy='1' then
         if clear_index=DESC_WORDS-1 then clear_busy<='0';clear_index<=0;else clear_index<=clear_index+1;end if;
       end if;
       if frame_cfg_we='1' and running='1' then config_errors(0)<='1';end if;
       if run_clear='1' then
         phase<=(others=>0);
         if generation=255 then config_errors(2)<='1';else generation<=generation+1;end if;
       elsif running='1' then
         if committed='0' or clear_busy='1' then config_errors(1)<='1';end if;
         for b in 0 to PERIOD_BANKS-1 loop
           v:=to_integer(unsigned(period_words(b)(30 downto 0)));
           if v>0 then if phase(b)=v-1 then phase(b)<=0;else phase(b)<=phase(b)+1;end if;else phase(b)<=0;end if;
         end loop;
       end if;
       if cfg_we='1' then
         a:=to_integer(unsigned(cfg_addr));v:=to_integer(unsigned(cfg_wdata(30 downto 0)));
         if running='1' or clear_busy='1' or ss/=S_IDLE then config_errors(0)<='1';
         else
           case a is
             when 4=>
               if cfg_wdata=x"00000001" then
                 clear_busy<='1';clear_index<=0;committed<='0';generation<=(others=>'0');config_errors<=(others=>'0');
               elsif cfg_wdata=x"00000002" then committed<='1';else config_errors(0)<='1';end if;
             when 8=>case_n<=cfg_wdata;
             when 12=>if unsigned(cfg_wdata)<MEMBERS then selected_key<=v;else config_errors(0)<='1';end if;
             when 16=>if unsigned(cfg_wdata)<5 then selected_word<=v;else config_errors(0)<='1';end if;
             when 104=>if unsigned(cfg_wdata)<MAX_GROUPS then selected_group<=v;else config_errors(0)<='1';end if;
             when 112=>if unsigned(cfg_wdata)<11 then selected_queue<=v;else config_errors(0)<='1';end if;
             when 116=>if unsigned(cfg_wdata)<512 then selected_record<=v;else config_errors(0)<='1';end if;
             when 120=>if unsigned(cfg_wdata)<4 then selected_record_word<=v;else config_errors(0)<='1';end if;
             when 136=>if unsigned(cfg_wdata)<5 then selected_lane<=v;else config_errors(0)<='1';end if;
             when 20=>committed<='0';
             when others=>config_errors(0)<='1';
           end case;
         end if;
       end if;
     end if;
   end if;
 end process;
 lanes:for p in 0 to 4 generate
   signal descriptor_we,history_we,raw_we:std_logic;
   signal config_slot,cache_addr,cache_read_slot:natural range 0 to FRAME_COUNT-1:=0;
   signal cache_data:frame_meta_t;
   signal descriptor_in:std_logic_vector(31 downto 0);
   signal history_in:seen_t;
   signal history_addr:natural range 0 to MEMBERS-1:=0;
   signal capture_addr:natural range 0 to BANKS*MAX_BYTES-1:=0;
   signal descriptor_dout,readback_dout:std_logic_vector(31 downto 0);
   signal program_addr:natural range 0 to DESC_WORDS-1:=0;
   signal seen_dout:seen_t;
   signal raw_dout:byte_t;
   signal desc_addr:natural range 0 to DESC_WORDS-1:=0;
   signal seen_addr:natural range 0 to MEMBERS-1:=0;
   signal raw_addr:natural range 0 to BANKS*MAX_BYTES-1:=0;
   signal seen_we:std_logic:='0';
   signal seen_write_addr:natural range 0 to MEMBERS-1:=0;
   signal seen_write_value:seen_t:=(others=>'0');
   signal capture_bank,parse_bank:natural range 0 to BANKS-1:=0;
   signal pending:four_bit:=(others=>'0');
   signal meta_good:four_bit:=(others=>'0');
   signal meta_length,meta_tick,meta_tx,meta_slot:four_nat:=(others=>0);
   signal capture_crc:unsigned(31 downto 0):=(others=>'1');
   signal capture_good:std_logic:='1';
   signal previous_index,previous_tick,previous_slot,first_tick:natural:=0;
   type parser_state is (P_IDLE,P_HREQ,P_HGET,P_DREQ,P_DGET,P_MULT,P_TIME,P_PAYREQ,P_PAYGET,P_COMMIT,P_NEXT,P_PADREQ,P_PADGET,P_FINISH);
   signal ps:parser_state:=P_IDLE;
   signal byte_pos:natural range 0 to MAX_BYTES-1:=18;
   signal record_pos:natural range 0 to MAX_BYTES-1:=18;
   signal header_index:natural range 0 to 7:=0;
   type header_array is array(0 to 7) of byte_t;
   signal rh:header_array:=(others=>(others=>'0'));
   signal key:natural range 0 to MEMBERS-1:=0;
   signal dw:natural range 0 to 4:=0;
   signal d:five_words:=(others=>(others=>'0'));
   signal payload_length:natural range 0 to 8:=0;
   signal payload_index:natural range 0 to 7:=0;
   signal epoch:natural range 0 to 65535:=0;
   signal record_good:std_logic:='0';
   signal product:unsigned(47 downto 0):=(others=>'0');
   signal deadline_value:unsigned(48 downto 0):=(others=>'0');
 begin
   -- The live slot selects BRAM only on byte zero. Hold the latched slot
   -- through all inter-byte gaps, even when rx_frame defaults to another slot.
   cache_addr<=rx_frame(p) when running='1' and rx_valid(p)='1' and
     rx_index(p)=0 and rx_frame(p)<FRAME_COUNT else config_slot;
   frame_metadata_memory:entity work.gasp_monitor_ram
     generic map(FRAME_COUNT,FRAME_META_WIDTH)
     port map(clk,frame_cfg_we,frame_cfg_slot,cache_addr,frame_meta_write,open,cache_data);
   process(clk)
   begin
     if rising_edge(clk) then cache_read_slot<=cache_addr;end if;
   end process;
   lane_busy(p)<='0' when ps=P_IDLE else '1';
   lane_pending(p)<='0' when pending=('0','0','0','0') else '1';
   program_addr<=clear_index when clear_busy='1' else selected_key*5+selected_word;
   summary_desc(p)<=descriptor_dout when summary_mode='1' else readback_dout;
   desc_addr<=summary_key*5+summary_word when summary_mode='1' else key*5+dw;
   seen_addr<=summary_key when summary_mode='1' else selected_key when running='0' and ps=P_IDLE else key;
   raw_addr<=parse_bank*MAX_BYTES+byte_pos;
   -- Explicit single-write/two-read synchronous memories. Separate hierarchy
   -- preserves five physical replicas for concurrent destination parsing.
   descriptor_we<='1' when clear_busy='1' or desc_write='1' else '0';
   descriptor_in<=(others=>'0') when clear_busy='1' else cfg_wdata;
   history_we<='1' when (clear_busy='1' and clear_index<MEMBERS) or
     (clear_busy='0' and seen_we='1') else '0';
   history_addr<=clear_index when clear_busy='1' and clear_index<MEMBERS else seen_write_addr;
   history_in<=(others=>'0') when clear_busy='1' else seen_write_value;
   raw_we<='1' when running='1' and rx_valid(p)='1' and rx_index(p)<MAX_BYTES else '0';
   capture_addr<=capture_bank*MAX_BYTES+rx_index(p) when rx_index(p)<MAX_BYTES else 0;
   descriptor_memory:entity work.gasp_monitor_ram
     generic map(DESC_WORDS,32)
     port map(clk,descriptor_we,program_addr,desc_addr,descriptor_in,readback_dout,descriptor_dout);
   history_memory:entity work.gasp_monitor_ram
     generic map(MEMBERS,104)
     port map(clk,history_we,history_addr,seen_addr,history_in,open,seen_dout);
   raw_memory:entity work.gasp_monitor_ram
     generic map(BANKS*MAX_BYTES,8)
     port map(clk,raw_we,capture_addr,raw_addr,rx_data(p*8+7 downto p*8),open,raw_dout);
   summary_seen(p)<=seen_dout;lane_readback(p)<=seen_dout;
   process(clk)
     variable crc:unsigned(31 downto 0);
     variable good:std_logic;
     variable b:byte_t;
     variable slot,length,tx,period,grp,member,n,expected:natural;
     variable release_tick:natural;
     variable found:boolean;
     variable first_count,on_time_count,last_epoch,duplicate_count:natural;
     variable already_seen,is_due:boolean;
     variable sv:seen_t;
     variable v48:unsigned(48 downto 0);
     variable c:frame_config;
   begin
     if rising_edge(clk) then
       seen_we<='0';anomaly_push(p)<='0';anomaly_push(p+5)<='0';
       if resetn='0' or run_clear='1' or clear_busy='1' then
         capture_bank<=0;parse_bank<=0;pending<=(others=>'0');ps<=P_IDLE;capture_crc<=(others=>'1');capture_good<='1';
         lane_errors(p)<=(others=>'0');lane_frames(p)<=0;lane_crc(p)<=0;lane_bad(p)<=0;lane_duplicate(p)<=0;lane_late(p)<=0;
       else
         if running='1' and rx_valid(p)='1' then
           slot:=rx_frame(p);b:=rx_data(p*8+7 downto p*8);good:=capture_good;
           c:=EMPTY_CONFIG;
           c.source:=to_integer(unsigned(cache_data(2 downto 0)));
           c.destination:=to_integer(unsigned(cache_data(5 downto 3)));
           c.critical:=cache_data(6);
           c.period_ticks:=to_integer(unsigned(cache_data(37 downto 7)));
           c.offset_ticks:=to_integer(unsigned(cache_data(68 downto 38)));
           c.length_bytes:=to_integer(unsigned(cache_data(99 downto 69)));
           if rx_index(p)=0 then
             crc:=crc_byte(x"FFFFFFFF",b);good:='1';first_tick<=now_tick;
             if slot<FRAME_COUNT then config_slot<=slot;end if;
             if pending(capture_bank)='1' or (ps/=P_IDLE and parse_bank=capture_bank) then
               good:='0';lane_errors(p)(4)<='1';anomaly_push(p)<='1';
               anomaly_in(p)<=anomaly(now_tick,65535,65535,1,slot,65535,rx_index(p));
             end if;
           else
             crc:=crc_byte(capture_crc,b);
             if rx_index(p)/=previous_index+1 or now_tick/=previous_tick+8 or slot/=previous_slot then good:='0';end if;
           end if;
           if slot>=5*FRAMES_PER_PORT or rx_index(p)>=MAX_BYTES then good:='0';
           else
             if frame_enabled(slot)/='1' then good:='0';end if;
             if rx_index(p)=0 then
               -- Header byte zero is metadata independent. Synchronous BRAM
               -- data is required starting at byte one and again at EOF.
               if b/=x"02" then good:='0';end if;
             else
               if cache_data(100)/='1' or cache_read_slot/=slot or config_slot/=slot or c.destination/=p then good:='0';end if;
               if rx_index(p)<18 and b/=header_byte(rx_index(p),c) then good:='0';end if;
             end if;
           end if;
           capture_crc<=crc;capture_good<=good;previous_index<=rx_index(p);previous_tick<=now_tick;previous_slot<=slot;
           if rx_last(p)='1' then
             length:=rx_index(p)+1;tx:=0;found:=false;
             if slot<5*FRAMES_PER_PORT then
               if cache_data(100)/='1' or cache_read_slot/=slot or config_slot/=slot or
                 frame_enabled(slot)/='1' or c.destination/=p then good:='0';end if;
               period:=c.period_ticks;release_tick:=0;
               for bank in 0 to PERIOD_BANKS-1 loop
                 if unsigned(period_words(bank))=period and period>0 then release_tick:=now_tick-phase(bank);found:=true;end if;
               end loop;
               tx:=release_tick+c.offset_ticks;
               if length/=c.length_bytes or length<64 or length>MAX_BYTES or not found then good:='0';end if;
               if now_tick/=tx+2*(c.length_bytes+20)*8-96 or first_tick/=tx+(c.length_bytes+20)*8+72 then good:='0';end if;
             end if;
             if crc/=x"DEBB20E3" then lane_crc(p)<=lane_crc(p)+1;lane_errors(p)(5)<='1';good:='0';end if;
             if good='1' then lane_frames(p)<=lane_frames(p)+1;
             else
               lane_errors(p)(6)<='1';anomaly_push(p)<='1';
               if crc/=x"DEBB20E3" then n:=2;else n:=3;end if;
               anomaly_in(p)<=anomaly(now_tick,65535,65535,n,slot,65535,length);
             end if;
             meta_good(capture_bank)<=good;meta_length(capture_bank)<=length;meta_tick(capture_bank)<=now_tick;
             meta_tx(capture_bank)<=tx;meta_slot(capture_bank)<=slot;pending(capture_bank)<='1';
             if capture_bank=BANKS-1 then capture_bank<=0;else capture_bank<=capture_bank+1;end if;
           end if;
         end if;
         case ps is
           when P_IDLE=>
             if pending(parse_bank)='1' then
               if meta_good(parse_bank)='1' then byte_pos<=18;record_pos<=18;header_index<=0;ps<=P_HREQ;
               else ps<=P_FINISH;end if;
             end if;
           when P_HREQ=>ps<=P_HGET;
           when P_HGET=>
             rh(header_index)<=raw_dout;
             if header_index=7 then
               grp:=to_integer(unsigned(rh(0)))*256+to_integer(unsigned(rh(1)));member:=to_integer(unsigned(rh(2)));
               n:=to_integer(unsigned(rh(5)));
               if member=0 and rh(0)=x"00" and rh(1)=x"00" then byte_pos<=record_pos;ps<=P_PADREQ;
               elsif grp>=MAX_GROUPS or member<1 or member>4 or rh(4)/=x"00" or n>8 or record_pos+8+n>meta_length(parse_bank)-4 then
                 lane_bad(p)<=lane_bad(p)+1;lane_errors(p)(7)<='1';ps<=P_FINISH;
                 anomaly_push(p+5)<='1';anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),65535,record_pos,4,meta_slot(parse_bank),65535,0);
                 anomaly_in(p+5)(127 downto 96)<=rh(0)&rh(1)&rh(2)&rh(3);
               else
                 key<=grp*4+member-1;payload_length<=n;epoch<=to_integer(unsigned(rh(6)))*256+to_integer(unsigned(raw_dout));dw<=0;ps<=P_DREQ;
               end if;
             else header_index<=header_index+1;byte_pos<=byte_pos+1;ps<=P_HREQ;end if;
           when P_DREQ=>ps<=P_DGET;
           when P_DGET=>
             d(dw)<=descriptor_dout;
             if dw=4 then ps<=P_MULT;else dw<=dw+1;ps<=P_DREQ;end if;
           when P_MULT=>
             product<=unsigned(d(1))*to_unsigned(epoch,16);
             good:='1';
             if d(0)(0)/='1' or to_integer(unsigned(d(0)(11 downto 8)))/=payload_length or d(0)(31 downto 24)/=rh(3) or unsigned(d(1))=0 then good:='0';end if;
             if d(0)(3 downto 2)="01" then
               if to_integer(unsigned(d(0)(23 downto 16)))/=meta_slot(parse_bank) or to_integer(unsigned(d(0)(6 downto 4)))/=p then good:='0';end if;
             elsif d(0)(3 downto 2)="00" then good:='0';end if;
             if epoch>=MAX_EPOCHS then good:='0';lane_errors(p)(8)<='1';end if;
             record_good<=good;ps<=P_TIME;
           when P_TIME=>
             v48:=resize(product,49);
             deadline_value<=v48+resize(unsigned(d(2)),49);
             if v48>to_unsigned(meta_tx(parse_bank),49) or to_unsigned(meta_tx(parse_bank),49)>=v48+resize(unsigned(d(1)),49) then record_good<='0';end if;
             if payload_length=0 then ps<=P_COMMIT;else payload_index<=0;byte_pos<=record_pos+8;ps<=P_PAYREQ;end if;
           when P_PAYREQ=>ps<=P_PAYGET;
           when P_PAYGET=>
             if payload_index<4 then expected:=to_integer(unsigned(d(3)(payload_index*8+7 downto payload_index*8)));
             else expected:=to_integer(unsigned(d(4)((payload_index-4)*8+7 downto (payload_index-4)*8)));end if;
             if to_integer(unsigned(raw_dout))/=(expected+epoch) mod 256 then record_good<='0';end if;
             if payload_index=payload_length-1 then ps<=P_COMMIT;else payload_index<=payload_index+1;byte_pos<=byte_pos+1;ps<=P_PAYREQ;end if;
           when P_COMMIT=>
             if record_good/='1' then
               lane_bad(p)<=lane_bad(p)+1;lane_errors(p)(7)<='1';
               anomaly_push(p+5)<='1';anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),key,epoch,5,meta_slot(parse_bank),epoch,record_pos);
             else
               sv:=(others=>'0');first_count:=0;on_time_count:=0;last_epoch:=0;duplicate_count:=0;already_seen:=false;
               if seen_dout(103 downto 96)=std_logic_vector(generation) then
                 sv:=seen_dout;already_seen:=sv(88)='1';
                 first_count:=to_integer(unsigned(sv(71 downto 56)));on_time_count:=to_integer(unsigned(sv(55 downto 40)));
                 last_epoch:=to_integer(unsigned(sv(87 downto 72)));duplicate_count:=to_integer(unsigned(sv(38 downto 8)));
               end if;
               sv(103 downto 96):=std_logic_vector(generation);
               is_due:=deadline_value<to_unsigned(window_ticks,49);
               if already_seen and epoch=last_epoch then
                 lane_duplicate(p)<=lane_duplicate(p)+1;
                 if unsigned(sv(39 downto 8))=x"FFFFFFFF" then lane_errors(p)(12)<='1';
                 else sv(39 downto 8):=std_logic_vector(unsigned(sv(39 downto 8))+1);end if;
               elsif already_seen and epoch<last_epoch then
                 sv(89):='1';lane_errors(p)(13)<='1';
                 anomaly_push(p+5)<='1';anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),key,epoch,9,meta_slot(parse_bank),last_epoch,0);
               else
                 if (already_seen and epoch>last_epoch+1) or ((not already_seen) and epoch>0) then
                   n:=0;if already_seen then n:=last_epoch+1;end if;
                   anomaly_push(p+5)<='1';anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),key,n,10,meta_slot(parse_bank),epoch-1,0);
                   lane_errors(p)(10)<='1';
                 end if;
                 sv(88):='1';sv(87 downto 72):=std_logic_vector(to_unsigned(epoch,16));
                 if is_due then
                   if first_count=65535 then lane_errors(p)(12)<='1';else first_count:=first_count+1;end if;
                   if to_unsigned(meta_tick(parse_bank),49)>deadline_value then
                     lane_late(p)<=lane_late(p)+1;lane_errors(p)(9)<='1';
                     -- A gap and a late event can occur together. Preserve both
                     -- kinds in one record by using detail bit0 for late.
                     if (already_seen and epoch>last_epoch+1) or ((not already_seen) and epoch>0) then
                       anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),key,n,10,meta_slot(parse_bank),epoch-1,epoch*2+1);
                     else
                       anomaly_push(p+5)<='1';anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),key,epoch,8,meta_slot(parse_bank),epoch,0);
                     end if;
                   else
                     if on_time_count=65535 then lane_errors(p)(12)<='1';else on_time_count:=on_time_count+1;end if;
                   end if;
                 end if;
                 sv(71 downto 56):=std_logic_vector(to_unsigned(first_count,16));sv(55 downto 40):=std_logic_vector(to_unsigned(on_time_count,16));
               end if;
               seen_write_addr<=key;seen_write_value<=sv;seen_we<='1';
             end if;
             ps<=P_NEXT;
           when P_NEXT=>
             n:=record_pos+8+payload_length;
             if n=meta_length(parse_bank)-4 then ps<=P_FINISH;
             elsif n+8>meta_length(parse_bank)-4 then byte_pos<=n;ps<=P_PADREQ;
             else record_pos<=n;byte_pos<=n;header_index<=0;ps<=P_HREQ;end if;
           when P_PADREQ=>ps<=P_PADGET;
           when P_PADGET=>
             if raw_dout/=x"00" then
               lane_bad(p)<=lane_bad(p)+1;lane_errors(p)(7)<='1';anomaly_push(p+5)<='1';
               anomaly_in(p+5)<=anomaly(meta_tick(parse_bank),65535,65535,6,meta_slot(parse_bank),65535,byte_pos);
             end if;
             if byte_pos=meta_length(parse_bank)-5 then ps<=P_FINISH;
             else byte_pos<=byte_pos+1;ps<=P_PADREQ;end if;
           when P_FINISH=>
             pending(parse_bank)<='0';if parse_bank=BANKS-1 then parse_bank<=0;else parse_bank<=parse_bank+1;end if;ps<=P_IDLE;
         end case;
       end if;
     end if;
   end process;
 end generate;
 -- Summary counts all due input instances, without epoch bitmaps. Each UID
 -- has one configured location in these five existing workloads; the host must
 -- reject multiple-location descriptors before loading them.
 process(clk)
   variable first_sum,on_time_sum,last_max,lanes_seen,slot,miss,tail_start:natural;
   variable iso:std_logic;
 begin
   if rising_edge(clk) then
     due_write<='0';anomaly_push(10)<='0';
     if resetn='0' or run_clear='1' or clear_busy='1' then
       ss<=S_IDLE;summary_mode<='0';summary_requested<='0';result_valid<='0';
       total_i<=0;complete_i<=0;isolated_i<=0;rate_i<=0;missing_i<=0;summary_errors<=(others=>'0');
     else
       if previous_running='1' and running='0' then summary_requested<='1';end if;
       case ss is
         when S_IDLE=>if summary_requested='1' then ss<=S_WAIT;summary_requested<='0';end if;
         when S_WAIT=>
           if lane_busy="00000" and lane_pending="00000" then
             summary_mode<='1';summary_group<=0;summary_member<=0;summary_key<=0;summary_word<=0;
             group_present<='0';group_complete<='1';group_isolated<='1';group_slot_count<=0;group_slots<=(others=>255);ss<=S_REQ;
           end if;
         when S_REQ=>ss<=S_GET;
         when S_GET=>
           sd(summary_word)<=summary_desc(0);
           if summary_word=4 then ss<=S_MEMBER;else summary_word<=summary_word+1;ss<=S_REQ;end if;
         when S_MEMBER=>
           due_epoch<=0;due_deadline<=resize(unsigned(sd(2)),33);
           if sd(0)(0)='1' then
             first_sum:=0;on_time_sum:=0;last_max:=0;lanes_seen:=0;
             for p in 0 to 4 loop
               if summary_seen(p)(103 downto 96)=std_logic_vector(generation) and summary_seen(p)(88)='1' then
                 first_sum:=first_sum+to_integer(unsigned(summary_seen(p)(71 downto 56)));
                 on_time_sum:=on_time_sum+to_integer(unsigned(summary_seen(p)(55 downto 40)));
                 if to_integer(unsigned(summary_seen(p)(87 downto 72)))>last_max then last_max:=to_integer(unsigned(summary_seen(p)(87 downto 72)));end if;
                 lanes_seen:=lanes_seen+1;
               end if;
             end loop;
             if first_sum>65535 or on_time_sum>65535 or lanes_seen>1 then
               summary_errors(13)<='1';member_first<=0;member_ontime<=0;
             else member_first<=first_sum;member_ontime<=on_time_sum;end if;
             member_last<=last_max;member_lanes<=lanes_seen;
             if lanes_seen=0 then member_has_seen<='0';else member_has_seen<='1';end if;
             if sd(0)(1)='1' then
               group_present<='1';slot:=to_integer(unsigned(sd(0)(23 downto 16)));iso:=group_isolated;
               if sd(0)(3 downto 2)/="01" then iso:='0';end if;
               for j in 0 to 3 loop if j<group_slot_count and group_slots(j)=slot then iso:='0';end if;end loop;
               group_slots(group_slot_count)<=slot;group_slot_count<=group_slot_count+1;group_isolated<=iso;
             end if;
             if sd(0)(3 downto 2)="10" or sd(0)(3 downto 2)="11" then summary_errors(14)<='1';end if;
             if unsigned(sd(1))=0 or sd(1)(31)='1' or sd(2)(31)='1' then
               if sd(0)(1)='1' then group_complete<='0';end if;summary_errors(1)<='1';ss<=S_CHECK;
             else ss<=S_DUE;end if;
           else due_write<='1';ss<=S_CHECK;end if;
         when S_DUE=>
           if due_deadline<to_unsigned(window_ticks,33) then
             if due_epoch=MAX_EPOCHS then
               group_complete<='0';summary_errors(8)<='1';ss<=S_CHECK;
             else due_epoch<=due_epoch+1;due_deadline<=due_deadline+resize(unsigned(sd(1)),33);end if;
           else
             due_write<='1';
             if sd(0)(1)='1' and (due_epoch=0 or member_ontime/=due_epoch) then group_complete<='0';end if;
             -- Missing and late are separate diagnostics. Only scheduled UIDs
             -- create missing errors; unscheduled inputs remain in denominator.
             if sd(0)(3 downto 2)="01" then
               if member_first>due_epoch then summary_errors(13)<='1';miss:=0;
               else miss:=due_epoch-member_first;end if;
               missing_i<=missing_i+miss;
               if miss>0 then summary_errors(10)<='1';end if;
               tail_start:=0;if member_has_seen='1' then tail_start:=member_last+1;end if;
               if tail_start<due_epoch then
                 anomaly_push(10)<='1';anomaly_in(10)<=anomaly(window_ticks,summary_key,tail_start,11,
                   to_integer(unsigned(sd(0)(23 downto 16))),due_epoch-1,0);
               end if;
             end if;
             ss<=S_CHECK;
           end if;
         when S_CHECK=>
           if summary_member=3 then ss<=S_GROUP;
           else summary_member<=summary_member+1;summary_key<=summary_key+1;summary_word<=0;ss<=S_REQ;end if;
         when S_GROUP=>
           if group_present='1' then
             total_i<=total_i+1;
             if group_complete='1' then complete_i<=complete_i+1;if group_isolated='1' then isolated_i<=isolated_i+1;end if;end if;
           end if;
           if summary_group=MAX_GROUPS-1 then ss<=S_DIV;
           else summary_group<=summary_group+1;summary_member<=0;summary_key<=summary_key+1;summary_word<=0;
             group_present<='0';group_complete<='1';group_isolated<='1';group_slot_count<=0;group_slots<=(others=>255);ss<=S_REQ;end if;
         when S_DIV=>div_remainder<=isolated_i*10000+total_i/2;rate_i<=0;ss<=S_DONE;
         when S_DONE=>
           if total_i=0 then summary_errors(1)<='1';result_valid<='1';summary_mode<='0';ss<=S_IDLE;
           elsif div_remainder>=total_i then div_remainder<=div_remainder-total_i;rate_i<=rate_i+1;
           else result_valid<='1';summary_mode<='0';ss<=S_IDLE;end if;
       end case;
     end if;
   end if;
 end process;
end;
