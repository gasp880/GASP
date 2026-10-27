-- Programmable five-port replay executor, AXI4-Lite protocol 2, continuous 100H measurement.
-- Capture timestamps refer to the rising edge carrying the indicated event.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.network_types.all;
use work.board_types.all;

entity board_executor_axi is
 generic(FRAMES_PER_PORT:positive:=36; MAX_BYTES:positive:=288;
   RX_BYTE_CAP:positive:=65536; RX_EVENT_CAP:positive:=512; PERIOD_BANKS:positive:=8;
   MAX_PERIOD_TICKS:positive:=10000000; GUARD_TICKS:natural:=12336);
 port(clk,resetn:in std_logic;
   s_axi_awaddr:in std_logic_vector(31 downto 0); s_axi_awvalid:in std_logic; s_axi_awready:out std_logic;
   s_axi_wdata:in std_logic_vector(31 downto 0); s_axi_wstrb:in std_logic_vector(3 downto 0);
   s_axi_wvalid:in std_logic; s_axi_wready:out std_logic;
   s_axi_bresp:out std_logic_vector(1 downto 0); s_axi_bvalid:out std_logic; s_axi_bready:in std_logic;
   s_axi_araddr:in std_logic_vector(31 downto 0); s_axi_arvalid:in std_logic; s_axi_arready:out std_logic;
   s_axi_rdata:out std_logic_vector(31 downto 0); s_axi_rresp:out std_logic_vector(1 downto 0);
   s_axi_rvalid:out std_logic; s_axi_rready:in std_logic);
 attribute X_INTERFACE_INFO:string;
 attribute X_INTERFACE_PARAMETER:string;
 attribute X_INTERFACE_INFO of clk:signal is "xilinx.com:signal:clock:1.0 CLK CLK";
 attribute X_INTERFACE_PARAMETER of clk:signal is "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 100000000";
 attribute X_INTERFACE_INFO of resetn:signal is "xilinx.com:signal:reset:1.0 RESET RST";
 attribute X_INTERFACE_PARAMETER of resetn:signal is "XIL_INTERFACENAME RESET, POLARITY ACTIVE_LOW";
 attribute X_INTERFACE_PARAMETER of s_axi_awaddr:signal is "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 32, READ_WRITE_MODE READ_WRITE, FREQ_HZ 100000000";
 attribute X_INTERFACE_INFO of s_axi_awaddr:signal is "xilinx.com:interface:aximm:1.0 S_AXI AWADDR";
 attribute X_INTERFACE_INFO of s_axi_awvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI AWVALID";
 attribute X_INTERFACE_INFO of s_axi_awready:signal is "xilinx.com:interface:aximm:1.0 S_AXI AWREADY";
 attribute X_INTERFACE_INFO of s_axi_wdata:signal is "xilinx.com:interface:aximm:1.0 S_AXI WDATA";
 attribute X_INTERFACE_INFO of s_axi_wstrb:signal is "xilinx.com:interface:aximm:1.0 S_AXI WSTRB";
 attribute X_INTERFACE_INFO of s_axi_wvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI WVALID";
 attribute X_INTERFACE_INFO of s_axi_wready:signal is "xilinx.com:interface:aximm:1.0 S_AXI WREADY";
 attribute X_INTERFACE_INFO of s_axi_bresp:signal is "xilinx.com:interface:aximm:1.0 S_AXI BRESP";
 attribute X_INTERFACE_INFO of s_axi_bvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI BVALID";
 attribute X_INTERFACE_INFO of s_axi_bready:signal is "xilinx.com:interface:aximm:1.0 S_AXI BREADY";
 attribute X_INTERFACE_INFO of s_axi_araddr:signal is "xilinx.com:interface:aximm:1.0 S_AXI ARADDR";
 attribute X_INTERFACE_INFO of s_axi_arvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI ARVALID";
 attribute X_INTERFACE_INFO of s_axi_arready:signal is "xilinx.com:interface:aximm:1.0 S_AXI ARREADY";
 attribute X_INTERFACE_INFO of s_axi_rdata:signal is "xilinx.com:interface:aximm:1.0 S_AXI RDATA";
 attribute X_INTERFACE_INFO of s_axi_rresp:signal is "xilinx.com:interface:aximm:1.0 S_AXI RRESP";
 attribute X_INTERFACE_INFO of s_axi_rvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI RVALID";
 attribute X_INTERFACE_INFO of s_axi_rready:signal is "xilinx.com:interface:aximm:1.0 S_AXI RREADY";
end;

architecture rtl of board_executor_axi is
 constant FRAME_COUNT:positive:=5*FRAMES_PER_PORT;
 constant SNAP_CAP:positive:=128; constant DIAG_CAP:positive:=128;
 constant DIAG_WORDS:positive:=1+(4*FRAME_COUNT+31)/32;
 type period_array is array(0 to PERIOD_BANKS-1) of natural range 0 to MAX_PERIOD_TICKS;
 type counter_array is array(0 to 4) of unsigned(31 downto 0);
 type increments_array is array(0 to 4) of unsigned(9 downto 0);
 type snap_ram_t is array(0 to SNAP_CAP-1) of std_logic_vector(255 downto 0);
 type diag_ram_t is array(0 to DIAG_CAP-1) of std_logic_vector(DIAG_WORDS*32-1 downto 0);
 signal cfg:config_array(0 to FRAME_COUNT-1):=(others=>EMPTY_CONFIG);
 signal active:std_logic_vector(FRAME_COUNT-1 downto 0):=(others=>'0');
 signal cfg_we:std_logic:='0'; signal cfg_slot:natural range 0 to FRAME_COUNT-1:=0;
 signal cfg_value:frame_config:=EMPTY_CONFIG;
 signal data_we:std_logic:='0';signal data_slot:natural range 0 to FRAME_COUNT-1:=0;
 signal data_addr:natural range 0 to MAX_BYTES-1:=0;signal data_value:std_logic_vector(12 downto 0):=(others=>'0');
 signal slot_sel:natural range 0 to FRAME_COUNT-1:=0;signal byte_sel:natural range 0 to MAX_BYTES:=0;
 signal flags_stage:std_logic_vector(31 downto 0):=x"00000301";
 signal period_stage,offset_stage,deadline_stage,length_stage:natural:=1;
 signal bank_sel:natural range 0 to PERIOD_BANKS-1:=0;
 signal period_config:period_array:=(others=>0);signal period_words:word_array(0 to PERIOD_BANKS-1);
 signal debug_word:std_logic_vector(12 downto 0);
 signal source_tx,source_error,source_gate:std_logic_vector(FRAME_COUNT-1 downto 0);
 signal ddata:std_logic_vector(39 downto 0);signal dv,dl:std_logic_vector(4 downto 0);signal df,di:natural_array(0 to 4);
 signal down,sw_error,sw_gate:std_logic_vector(FRAME_COUNT-1 downto 0);
 signal core_reset:std_logic:='1';signal running,done,complete,armed,previous_running:std_logic:='0';
 signal window_ticks:natural range 1 to 2147483647:=1000000000;
 signal hyperperiod_ticks:natural range 1 to MAX_PERIOD_TICKS:=MAX_PERIOD_TICKS;
 signal now_tick:natural range 0 to 2147483647:=0;
 signal next_snapshot:unsigned(31 downto 0):=to_unsigned(MAX_PERIOD_TICKS,32);
 signal clear_capture,cfg_error:std_logic:='0';
 signal total_counts:counter_array:=(others=>(others=>'0'));
 signal count_increment:increments_array;
 signal overflow_flags:std_logic_vector(31 downto 0):=(others=>'0');
 signal snapshot_mem:snap_ram_t;signal snapshot_q:std_logic_vector(255 downto 0);
 signal snapshot_count:natural range 0 to SNAP_CAP:=0;signal snapshot_sel:natural range 0 to SNAP_CAP-1:=0;
 signal snapshot_word:natural range 0 to 7:=0;
 signal diag_mem:diag_ram_t;signal diag_q:std_logic_vector(DIAG_WORDS*32-1 downto 0);
 signal diag_count:natural range 0 to DIAG_CAP:=0;signal diag_sel:natural range 0 to DIAG_CAP-1:=0;
 signal diag_word:natural range 0 to DIAG_WORDS-1:=0;
 signal start_count,run_clear_count:unsigned(31 downto 0):=(others=>'0');
 signal actual_start_tick,actual_end_tick:unsigned(31 downto 0):=(others=>'0');
 signal frame_cache_ready:std_logic;
 signal mon_cfg_we,metric_valid:std_logic:='0';signal mon_cfg_addr:std_logic_vector(7 downto 0);
 signal mon_cfg_data,mon_read_data:std_logic_vector(31 downto 0);
 signal metric_case,metric_total,metric_complete,metric_isolated,metric_rate,metric_errors:std_logic_vector(31 downto 0);
 signal aw_pending,w_pending,bvalid_i,rvalid_i:std_logic:='0';
 signal aw_saved,w_saved:std_logic_vector(31 downto 0);signal strb_saved:std_logic_vector(3 downto 0);
 signal bresp_i,rresp_i:std_logic_vector(1 downto 0):="00";signal rdata_i:std_logic_vector(31 downto 0):=(others=>'0');
 function word(n:natural) return std_logic_vector is begin return std_logic_vector(to_unsigned(n,32));end;
 function tree_size(n:positive) return positive is variable size:positive:=1;
 begin while size<n loop size:=size*2;end loop;return size;end;
begin
 assert MAX_BYTES>=64 and PERIOD_BANKS<=8 severity failure;
 s_axi_awready<=not aw_pending and not bvalid_i;s_axi_wready<=not w_pending and not bvalid_i;
 s_axi_bvalid<=bvalid_i;s_axi_bresp<=bresp_i;
 s_axi_arready<=not rvalid_i;s_axi_rvalid<=rvalid_i;s_axi_rdata<=rdata_i;s_axi_rresp<=rresp_i;
 period_word_connections:for b in 0 to PERIOD_BANKS-1 generate period_words(b)<=word(period_config(b));end generate;
 network:entity work.board_network generic map(FRAMES_PER_PORT,MAX_BYTES,PERIOD_BANKS,MAX_PERIOD_TICKS,GUARD_TICKS)
   port map(clk,core_reset,running,cfg_we,data_we,cfg_slot,data_slot,slot_sel,cfg_value,data_addr,byte_sel,data_value,
     active,period_words,now_tick,debug_word,source_tx,source_error,source_gate,down,sw_error,sw_gate,dv,dl,df,di,ddata);
 monitor:entity work.gasp_metric_monitor generic map(FRAMES_PER_PORT,MAX_BYTES,PERIOD_BANKS,640,1024)
   port map(clk,resetn,running,clear_capture,window_ticks,now_tick,cfg_we,cfg_slot,cfg_value,frame_cache_ready,active,period_words,dv,dl,df,di,ddata,
     mon_cfg_we,mon_cfg_addr,mon_cfg_data,s_axi_araddr(7 downto 0),mon_read_data,metric_valid,
     metric_case,metric_total,metric_complete,metric_isolated,metric_rate,metric_errors);
 -- Exact population counts retain simultaneous events. Source/switch events
 -- are registered by the network; their timestamps are now_tick-1. RX last
 -- bytes are observed directly on now_tick. No event is selected or discarded.
 count_trees:for k in 0 to 4 generate
   function leaf_count return positive is
   begin if k=2 then return 5;elsif k=3 or k=4 then return 2*FRAME_COUNT;else return FRAME_COUNT;end if;end;
   constant HIT_COUNT:positive:=leaf_count;constant LEAVES:positive:=tree_size(HIT_COUNT);
   type tree_t is array(1 to 2*LEAVES-1) of unsigned(9 downto 0);
   signal tree:tree_t;signal bits:std_logic_vector(HIT_COUNT-1 downto 0);
 begin
   tx:if k=0 generate bits<=source_tx;end generate;
   dw:if k=1 generate bits<=down;end generate;
   rx:if k=2 generate bits<=dv and dl;end generate;
   er:if k=3 generate bits<=sw_error&source_error;end generate;
   ga:if k=4 generate bits<=sw_gate&source_gate;end generate;
   leaves_g:for i in 0 to LEAVES-1 generate
     hit:if i<HIT_COUNT generate tree(LEAVES+i)<=to_unsigned(1,10) when bits(i)='1' else to_unsigned(0,10);end generate;
     pad:if i>=HIT_COUNT generate tree(LEAVES+i)<=(others=>'0');end generate;
   end generate;
   branches:for i in 1 to LEAVES-1 generate tree(i)<=tree(2*i)+tree(2*i+1);end generate;
   count_increment(k)<=tree(1);
 end generate;
 -- Synchronous read ports infer memories. Entries have eight cumulative words
 -- per hyperperiod, and full source/switch ERROR/GATE masks per anomalous edge.
 process(clk)
 begin if rising_edge(clk) then snapshot_q<=snapshot_mem(snapshot_sel);diag_q<=diag_mem(diag_sel);end if;end process;

 process(clk)
   variable a,v:natural;variable bad:boolean;variable read_word:std_logic_vector(31 downto 0);
   variable c:frame_config;variable n:natural;variable flags:std_logic_vector(31 downto 0);
   variable updated:counter_array;variable extended:unsigned(32 downto 0);
   variable snap:std_logic_vector(255 downto 0);variable diag:std_logic_vector(DIAG_WORDS*32-1 downto 0);
 begin
   if rising_edge(clk) then
     cfg_we<='0';data_we<='0';clear_capture<='0';core_reset<='0';mon_cfg_we<='0';previous_running<=running;
     if resetn='0' then
       aw_pending<='0';w_pending<='0';bvalid_i<='0';rvalid_i<='0';running<='0';previous_running<='0';armed<='0';done<='0';core_reset<='1';
       now_tick<=0;total_counts<=(others=>(others=>'0'));cfg_error<='0';overflow_flags<=(others=>'0');
       snapshot_count<=0;diag_count<=0;start_count<=(others=>'0');run_clear_count<=(others=>'0');
       actual_start_tick<=(others=>'0');actual_end_tick<=(others=>'0');
     else
       if bvalid_i='1' and s_axi_bready='1' then bvalid_i<='0';end if;
       if rvalid_i='1' and s_axi_rready='1' then rvalid_i<='0';end if;
       if s_axi_awvalid='1' and s_axi_awready='1' then aw_saved<=s_axi_awaddr;aw_pending<='1';end if;
       if s_axi_wvalid='1' and s_axi_wready='1' then w_saved<=s_axi_wdata;strb_saved<=s_axi_wstrb;w_pending<='1';end if;
       if armed='1' then armed<='0';running<='1';end if;
       if running='1' then
         if now_tick=window_ticks-1 then running<='0';end if;
         if now_tick=2147483647 then overflow_flags(3)<='1';running<='0';
         else now_tick<=now_tick+1;end if;
         if core_reset='1' then overflow_flags(4)<='1';end if;
       elsif previous_running='1' then done<='1';actual_end_tick<=to_unsigned(now_tick,32);end if;
       updated:=total_counts;
       for k in 0 to 4 loop
         if (k=2 and running='1') or (k/=2 and previous_running='1') then
           extended:=resize(total_counts(k),33)+resize(count_increment(k),33);
           if extended(32)='1' then overflow_flags(0)<='1';updated(k):=(others=>'1');
           else updated(k):=extended(31 downto 0);end if;
         end if;
       end loop;
       total_counts<=updated;
       -- A snapshot is committed on the first edge at the exclusive H
       -- boundary. Include delayed TX/DOWN/ERROR/GATE from boundary-1, but
       -- exclude RX at the boundary, which belongs to the following segment.
       if previous_running='1' and to_unsigned(now_tick,32)=next_snapshot then
         snap:=(others=>'0');snap(31 downto 0):=word(now_tick);
         for k in 0 to 4 loop
           if k=2 then snap((k+2)*32-1 downto (k+1)*32):=std_logic_vector(total_counts(k));
           else snap((k+2)*32-1 downto (k+1)*32):=std_logic_vector(updated(k));end if;
         end loop;
         snap(223 downto 192):=overflow_flags;snap(255 downto 224):=metric_errors;
         if snapshot_count=SNAP_CAP then overflow_flags(1)<='1';
         else snapshot_mem(snapshot_count)<=snap;snapshot_count<=snapshot_count+1;end if;
         next_snapshot<=next_snapshot+to_unsigned(hyperperiod_ticks,32);
       end if;
       if previous_running='1' and ((or source_error)='1' or (or sw_error)='1' or (or source_gate)='1' or (or sw_gate)='1') then
         diag:=(others=>'0');if now_tick>0 then diag(31 downto 0):=word(now_tick-1);end if;
         diag(32+FRAME_COUNT-1 downto 32):=source_error;
         diag(32+2*FRAME_COUNT-1 downto 32+FRAME_COUNT):=sw_error;
         diag(32+3*FRAME_COUNT-1 downto 32+2*FRAME_COUNT):=source_gate;
         diag(32+4*FRAME_COUNT-1 downto 32+3*FRAME_COUNT):=sw_gate;
         if diag_count=DIAG_CAP then overflow_flags(2)<='1';
         else diag_mem(diag_count)<=diag;diag_count<=diag_count+1;end if;
       end if;
       if aw_pending='1' and w_pending='1' and bvalid_i='0' then
         aw_pending<='0';w_pending<='0';bvalid_i<='1';bresp_i<="00";bad:=false;
         a:=to_integer(unsigned(aw_saved(8 downto 0)));v:=to_integer(unsigned(w_saved(30 downto 0)));
         if aw_saved(31 downto 9)/=(22 downto 0=>'0') or aw_saved(1 downto 0)/="00" or strb_saved/="1111" then bad:=true;
         elsif running='1' or armed='1' or previous_running='1' then bad:=true;
         elsif a>=16#100# then mon_cfg_addr<=aw_saved(7 downto 0);mon_cfg_data<=w_saved;mon_cfg_we<='1';
         else
           case a is
             when 16#0C#=>
               if w_saved(31 downto 4)/=(27 downto 0=>'0') or v=0 or (v/=1 and v/=2 and v/=4 and v/=8) then bad:=true;
               elsif v=1 then
                 if complete='0' or frame_cache_ready/='1' then bad:=true;
                 else armed<='1';done<='0';now_tick<=0;core_reset<='1';clear_capture<='1';total_counts<=(others=>(others=>'0'));
                   overflow_flags<=(others=>'0');snapshot_count<=0;diag_count<=0;next_snapshot<=to_unsigned(hyperperiod_ticks,32);
                   actual_start_tick<=(others=>'0');actual_end_tick<=(others=>'0');
                   if start_count=x"FFFFFFFF" or run_clear_count=x"FFFFFFFF" then overflow_flags(0)<='1';
                   else start_count<=start_count+1;run_clear_count<=run_clear_count+1;end if;
                 end if;
               elsif v=2 then done<='0';now_tick<=0;core_reset<='1';clear_capture<='1';total_counts<=(others=>(others=>'0'));cfg_error<='0';
                 overflow_flags<=(others=>'0');snapshot_count<=0;diag_count<=0;
                 if run_clear_count=x"FFFFFFFF" then overflow_flags(0)<='1';else run_clear_count<=run_clear_count+1;end if;
               elsif v=4 then active<=(others=>'0');complete<='0';period_config<=(others=>0);cfg_error<='0';core_reset<='1';
                 start_count<=(others=>'0');run_clear_count<=(others=>'0');
               elsif v=8 then
                 n:=0;for i in 0 to FRAME_COUNT-1 loop if active(i)='1' then n:=n+1;end if;end loop;
                 if n=0 or frame_cache_ready/='1' then bad:=true;else complete<='1';end if;
               end if;
             when 16#10#=>if w_saved(31)='1' or v=0 then bad:=true;else window_ticks<=v;complete<='0';end if;
             when 16#40#=>if w_saved(31)='1' or v>=FRAME_COUNT then bad:=true;else slot_sel<=v;end if;
             when 16#44#=>if (unsigned(w_saved) and unsigned'(x"FFFFFCF8"))/=0 or v mod 8>4 then bad:=true;else flags_stage<=w_saved;complete<='0';end if;
             when 16#48#=>if w_saved(31)='1' or v=0 or v>MAX_PERIOD_TICKS then bad:=true;else period_stage<=v;complete<='0';end if;
             when 16#4C#=>if w_saved(31)='1' or v>=MAX_PERIOD_TICKS then bad:=true;else offset_stage<=v;complete<='0';end if;
             when 16#50#=>if w_saved(31)='1' or v=0 then bad:=true;else deadline_stage<=v;complete<='0';end if;
             when 16#54#=>if w_saved(31)='1' or v<64 or v>MAX_BYTES then bad:=true;else length_stage<=v;complete<='0';end if;
             when 16#58#=>
               if unsigned(w_saved)>1 then bad:=true;
               elsif v=0 then active(slot_sel)<='0';complete<='0';
               elsif length_stage<64 or offset_stage+(length_stage+20)*16>period_stage then bad:=true;
               else
                 c:=(slot_sel/FRAMES_PER_PORT,to_integer(unsigned(flags_stage(2 downto 0))),period_stage,offset_stage,deadline_stage,length_stage,flags_stage(8),flags_stage(9));
                 cfg(slot_sel)<=c;cfg_slot<=slot_sel;cfg_value<=c;cfg_we<='1';active(slot_sel)<='1';complete<='0';
               end if;
             when 16#60#=>if w_saved(31)='1' or v>=MAX_BYTES then bad:=true;else byte_sel<=v;end if;
             when 16#64#|16#68#=>
               if w_saved(31 downto 13)/=(18 downto 0=>'0') or byte_sel>=MAX_BYTES or to_integer(unsigned(w_saved(10 downto 8)))>=PERIOD_BANKS then bad:=true;
               else data_slot<=slot_sel;data_addr<=byte_sel;data_value<=w_saved(12 downto 0);data_we<='1';complete<='0';if a=16#68# then byte_sel<=byte_sel+1;end if;end if;
             when 16#70#=>if w_saved(31)='1' or v>=PERIOD_BANKS then bad:=true;else bank_sel<=v;end if;
             when 16#74#=>if w_saved(31)='1' or v>MAX_PERIOD_TICKS then bad:=true;else period_config(bank_sel)<=v;complete<='0';end if;
             when 16#C0#=>if w_saved(31)='1' or v=0 or v>MAX_PERIOD_TICKS then bad:=true;else hyperperiod_ticks<=v;complete<='0';end if;
             when 16#C4#=>if unsigned(w_saved)>=SNAP_CAP then bad:=true;else snapshot_sel<=v;end if;
             when 16#C8#=>if unsigned(w_saved)>7 then bad:=true;else snapshot_word<=v;end if;
             when 16#EC#=>if unsigned(w_saved)>=DIAG_CAP then bad:=true;else diag_sel<=v;end if;
             when 16#F0#=>if unsigned(w_saved)>=DIAG_WORDS then bad:=true;else diag_word<=v;end if;
             when others=>bad:=true;
           end case;
         end if;
         if bad then bresp_i<="10";cfg_error<='1';end if;
       end if;
       if s_axi_arvalid='1' and s_axi_arready='1' then
         rvalid_i<='1';rresp_i<="00";read_word:=(others=>'0');bad:=false;
         a:=to_integer(unsigned(s_axi_araddr(8 downto 0)));
         if s_axi_araddr(31 downto 9)/=(22 downto 0=>'0') or s_axi_araddr(1 downto 0)/="00" then bad:=true;
         elsif a>=16#100# then read_word:=mon_read_data;
         else
           case a is
             when 16#00#=>read_word:=x"47535032";when 16#04#=>read_word:=x"00000002";
             when 16#08#=>read_word(0):=running or armed or previous_running;read_word(1):=done;read_word(2):=complete;
               read_word(3):=or overflow_flags;read_word(4):=cfg_error;read_word(5):=metric_valid;
             when 16#10#=>read_word:=word(window_ticks);when 16#14#=>read_word:=word(now_tick);
             when 16#18#=>read_word:=word(FRAMES_PER_PORT);when 16#1C#=>read_word:=word(MAX_BYTES);
             when 16#20#|16#24#=>read_word:=(others=>'0'); -- protocol 2 has no full stream capture RAM
             when 16#28#=>read_word:=word(PERIOD_BANKS);when 16#2C#=>read_word:=word(GUARD_TICKS);
             when 16#40#=>read_word:=word(slot_sel);
             when 16#44#=>read_word(2 downto 0):=std_logic_vector(to_unsigned(cfg(slot_sel).destination,3));read_word(8):=cfg(slot_sel).critical;read_word(9):=cfg(slot_sel).refresh_crc;
             when 16#48#=>read_word:=word(cfg(slot_sel).period_ticks);when 16#4C#=>read_word:=word(cfg(slot_sel).offset_ticks);
             when 16#50#=>read_word:=word(cfg(slot_sel).deadline_ticks);when 16#54#=>read_word:=word(cfg(slot_sel).length_bytes);
             when 16#58#=>read_word(0):=active(slot_sel);when 16#60#=>read_word:=word(byte_sel);
             when 16#64#|16#68#=>if running='1' or armed='1' or previous_running='1' or byte_sel>=MAX_BYTES then bad:=true;
               else read_word(12 downto 0):=debug_word;if a=16#68# then byte_sel<=byte_sel+1;end if;end if;
             when 16#70#=>read_word:=word(bank_sel);when 16#74#=>read_word:=word(period_config(bank_sel));
             when 16#A4#=>read_word:=overflow_flags;
             when 16#A8#=>read_word:=std_logic_vector(total_counts(0));when 16#AC#=>read_word:=std_logic_vector(total_counts(1));when 16#B0#=>read_word:=std_logic_vector(total_counts(2));
             when 16#B4#=>read_word:=std_logic_vector(total_counts(3));when 16#B8#=>read_word:=std_logic_vector(total_counts(4));
             when 16#C0#=>read_word:=word(hyperperiod_ticks);when 16#C4#=>read_word:=word(snapshot_sel);when 16#C8#=>read_word:=word(snapshot_word);
             when 16#CC#=>if running='1' or armed='1' or previous_running='1' or snapshot_sel>=snapshot_count then bad:=true;
               else read_word:=snapshot_q(snapshot_word*32+31 downto snapshot_word*32);end if;
             when 16#D0#=>read_word:=word(snapshot_count);when 16#D4#=>read_word:=std_logic_vector(start_count);when 16#D8#=>read_word:=std_logic_vector(run_clear_count);
             when 16#DC#=>read_word:=std_logic_vector(actual_start_tick);when 16#E0#=>read_word:=std_logic_vector(actual_end_tick);when 16#E4#=>read_word:=word(SNAP_CAP);
             when 16#E8#=>read_word:=word(diag_count);when 16#EC#=>read_word:=word(diag_sel);when 16#F0#=>read_word:=word(diag_word);
             when 16#F4#=>if running='1' or armed='1' or previous_running='1' or diag_sel>=diag_count then bad:=true;
               else read_word:=diag_q(diag_word*32+31 downto diag_word*32);end if;
             when 16#F8#=>read_word:=word(DIAG_CAP);when 16#FC#=>read_word:=overflow_flags;
             when others=>bad:=true;
           end case;
         end if;
         rdata_i<=read_word;if bad then rresp_i<="10";end if;
       end if;
     end if;
   end if;
 end process;
end;
