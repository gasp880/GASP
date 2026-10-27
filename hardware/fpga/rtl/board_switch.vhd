-- Per-frame 1W/1R banks replace the shared 5W/5R register-based memory.
-- Read prefetch occupies an otherwise idle serialization tick.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.network_types.all;

entity board_switch is
  generic (FRAME_COUNT : positive := 5; MAX_BYTES : positive := 128;
    GUARD_TICKS : natural := 12336; MAX_PERIOD_TICKS : positive := 10000000);
  port (clk, reset, run, config_we : in std_logic;
    config_index : in natural range 0 to FRAME_COUNT-1; config_value : in frame_config;
    enabled : in std_logic_vector(FRAME_COUNT-1 downto 0);
    in_valid, in_last : in std_logic_vector(4 downto 0);
    in_frame, in_index : in natural_array(0 to 4); in_data : in std_logic_vector(39 downto 0);
    queued_feedback : out std_logic_vector(FRAME_COUNT-1 downto 0);
    out_valid, out_last : out std_logic_vector(4 downto 0);
    out_frame, out_index : out natural_array(0 to 4); out_data : out std_logic_vector(39 downto 0);
    down_event, error_event, gate_event : out std_logic_vector(FRAME_COUNT-1 downto 0));
end entity;

architecture rtl of board_switch is
  constant MAX_AGE : natural := (MAX_BYTES+20)*8;
  function id_width(count : positive) return positive is
    variable width : positive := 1;
  begin
    while 2**width < count loop width := width+1; end loop;
    return width;
  end function;
  constant ID_BITS : positive := id_width(FRAME_COUNT);
  constant BANK_SIZE : positive := 36;
  constant BANK_COUNT : positive := (FRAME_COUNT+BANK_SIZE-1)/BANK_SIZE;
  constant BANK_LEAVES : positive := 2**id_width(BANK_SIZE);
  constant ROOT_LEAVES : positive := 2**id_width(BANK_COUNT);
  constant AGE_BITS : positive := id_width(MAX_AGE+1);
  constant LENGTH_BITS : positive := id_width(MAX_BYTES+1);
  function interval_blocked(ph, start_at, end_at, guard_at : natural;
                           wraps, full : std_logic) return std_logic is
  begin
    if full = '1' or (ph >= start_at and ph < end_at) or
       (wraps = '1' and (ph >= guard_at or ph <= start_at)) or
       (wraps = '0' and ph >= guard_at and ph <= start_at) then return '1';
    else return '0'; end if;
  end function;
  type local_config is record
    destination : natural range 0 to 4;
    period_ticks : natural range 1 to MAX_PERIOD_TICKS;
    offset_ticks : natural range 0 to MAX_PERIOD_TICKS-1;
    length_bytes : natural range 64 to MAX_BYTES;
    critical : std_logic;
  end record;
  type local_configs is array(0 to FRAME_COUNT-1) of local_config;
  type phase_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_PERIOD_TICKS-1;
  type id_array is array(0 to 4) of natural range 0 to FRAME_COUNT-1;
  type age_array is array(0 to 4) of natural range 0 to MAX_AGE;
  type byte_array is array(0 to FRAME_COUNT-1) of byte_t;
  type boolean_array is array(0 to 4) of boolean;
  type duration_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_AGE;
  type start_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_PERIOD_TICKS+MAX_AGE;
  type boundary_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_PERIOD_TICKS;
  type port_frame_vectors is array(0 to 4) of std_logic_vector(FRAME_COUNT-1 downto 0);
  type encoded_array is array(0 to 4) of unsigned(ID_BITS-1 downto 0);
  type route_array is array(0 to FRAME_COUNT-1) of std_logic_vector(4 downto 0);
  type active_duration_array is array(0 to 4) of natural range 0 to MAX_AGE;
  type active_length_array is array(0 to 4) of natural range 64 to MAX_BYTES;
  type length_unsigned_array is array(0 to 4) of unsigned(LENGTH_BITS-1 downto 0);
  type duration_unsigned_array is array(0 to 4) of unsigned(AGE_BITS-1 downto 0);
  signal cfg : local_configs := (others => (1,1,0,64,'1'));
  signal phase : phase_array := (others => 0);
  signal queued, prequeued : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '0');
  signal busy : std_logic_vector(4 downto 0) := (others => '0');
  signal active_id : id_array := (others => 0);
  signal age : age_array := (others => 0);
  signal prefetched : byte_array;
  signal port_blocked : boolean_array;
  -- Configuration-derived tables survive run-state reset together with cfg.
  signal duration : duration_array := (others => 672);
  signal start_tick : start_array := (others => 672);
  signal busy_end : boundary_array := (others => 0);
  signal guard_start : phase_array := (others => 0);
  signal guard_wrap : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '0');
  signal guard_full : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '1');
  signal guard_blocked, eligible, gated, accepted : std_logic_vector(FRAME_COUNT-1 downto 0);
  signal winner, active_hot : port_frame_vectors := (others => (others => '0'));
  signal route_mask : route_array := (others => "00010");
  signal period_last : phase_array := (others => 0);
  signal due_cached : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '0');
  signal blocked_cached : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '1');
  signal critical_id, all_id : encoded_array;
  signal critical_any, all_any, selected_any, choose_critical, choose_all : std_logic_vector(4 downto 0);
  signal critical_duration, all_duration : duration_unsigned_array;
  signal critical_length, all_length : length_unsigned_array;
  signal active_duration : active_duration_array := (others => 672);
  signal active_length : active_length_array := (others => 64);
  signal winner_id : encoded_array;
  signal available, accept_any : boolean_array;
begin
  assert MAX_BYTES >= 64 severity failure;
  banks: for i in 0 to FRAME_COUNT-1 generate
    signal we, re : std_logic;
    signal wa, ra : natural range 0 to MAX_BYTES-1;
    signal wd : byte_t;
  begin
    process(all)
      variable p : natural range 0 to 4;
      variable j : natural range 0 to MAX_BYTES+12;
    begin
      we <= '0'; wa <= 0; wd <= (others => '0'); re <= '0'; ra <= 0;
      if run = '1' and reset = '0' then
        -- Preserve the original port priority for a duplicated write address.
        for source in 0 to 4 loop
          if in_valid(source) = '1' and in_frame(source) = i then
            assert in_index(source) < MAX_BYTES report "frame write address out of range" severity failure;
            we <= '1'; wa <= in_index(source); wd <= in_data(source*8+7 downto source*8);
          end if;
        end loop;
        -- Static port connections replace each bank's dynamic destination/age mux.
        for port_id in 0 to 4 loop
          if busy(port_id) = '1' and active_hot(port_id)(i) = '1'
             and age(port_id) >= 71 and age(port_id) mod 8 = 7 then
            j := (age(port_id)+1)/8-9;
            if j < active_length(port_id) then re <= '1'; ra <= j; end if;
          end if;
        end loop;
      end if;
    end process;
    storage: entity work.frame_buffer generic map(MAX_BYTES)
      port map(clk,we,re,wa,ra,wd,prefetched(i));
  end generate;

  process(all)
    variable q : std_logic_vector(FRAME_COUNT-1 downto 0);
    variable j : natural range 0 to MAX_BYTES+12;
  begin
    q := queued;
    for p in 0 to 4 loop
      if in_valid(p) = '1' and in_last(p) = '1' then q(in_frame(p)) := '1'; end if;
    end loop;
    prequeued <= q; queued_feedback <= q;
    out_valid <= (others => '0'); out_last <= (others => '0'); out_data <= (others => '0');
    out_index <= (others => 0);
    for p in 0 to 4 loop
      out_frame(p) <= active_id(p);
      if run = '1' and busy(p) = '1' and age(p) >= 72 and age(p) mod 8 = 0 then
        j := age(p)/8-9;
        if j < active_length(p) then
          out_valid(p) <= '1'; out_index(p) <= j;
          out_data(p*8+7 downto p*8) <= prefetched(active_id(p));
          if j = active_length(p)-1 then out_last(p) <= '1'; end if;
        end if;
      end if;
    end loop;
  end process;

  -- Prediction stores the condition for the NEXT phase, never queued/enable.
  -- The current enable mask and same-edge upstream-last bypass stay combinational.
  frame_checks : for i in 0 to FRAME_COUNT-1 generate
    signal grants, blocked_ports : std_logic_vector(4 downto 0);
  begin
    eligible(i) <= due_cached(i) and enabled(i);
    route_guards : for p in 0 to 4 generate
      blocked_ports(p) <= '1' when route_mask(i)(p) = '1' and port_blocked(p) else '0';
      grants(p) <= winner(p)(i) when available(p) else '0';
    end generate;
    gated(i) <= eligible(i) and not cfg(i).critical and (or blocked_ports);
    guard_blocked(i) <= blocked_cached(i) and enabled(i) and cfg(i).critical and run;
    accepted(i) <= or grants;
  end generate;

  -- Two independent balanced priority trees per destination: critical-only and
  -- all eligible queued frames. A blocked port selects the critical-only root;
  -- an unblocked port selects the all-frame root. Both roots already contain
  -- their lowest ID, so no cross-class ID comparator follows either tree.
  -- Global guard never enters the 180-slot priority tree or its field muxes.
  port_arbitration : for p in 0 to 4 generate
    signal guards : std_logic_vector(FRAME_COUNT-1 downto 0);
    signal c_bank_valid, a_bank_valid : std_logic_vector(BANK_COUNT-1 downto 0);
    type bank_id_array is array(0 to BANK_COUNT-1) of unsigned(ID_BITS-1 downto 0);
    signal c_bank_id, a_bank_id : bank_id_array;
    type bank_duration_array is array(0 to BANK_COUNT-1) of unsigned(AGE_BITS-1 downto 0);
    type bank_length_array is array(0 to BANK_COUNT-1) of unsigned(LENGTH_BITS-1 downto 0);
    signal c_bank_duration, a_bank_duration : bank_duration_array;
    signal c_bank_length, a_bank_length : bank_length_array;
    signal c_root_valid, a_root_valid : std_logic_vector(2*ROOT_LEAVES-1 downto 1);
    type root_id_array is array(1 to 2*ROOT_LEAVES-1) of unsigned(ID_BITS-1 downto 0);
    signal c_root_id, a_root_id : root_id_array;
    type root_duration_array is array(1 to 2*ROOT_LEAVES-1) of unsigned(AGE_BITS-1 downto 0);
    type root_length_array is array(1 to 2*ROOT_LEAVES-1) of unsigned(LENGTH_BITS-1 downto 0);
    signal c_root_duration, a_root_duration : root_duration_array;
    signal c_root_length, a_root_length : root_length_array;
  begin
    available(p) <= busy(p) = '0' or age(p) = active_duration(p);
    guard_frames : for i in 0 to FRAME_COUNT-1 generate
      guards(i) <= guard_blocked(i) and route_mask(i)(p);
      winner(p)(i) <= '1' when selected_any(p) = '1' and winner_id(p) = i else '0';
    end generate;
    port_blocked(p) <= (or guards) = '1';
    banks : for bank in 0 to BANK_COUNT-1 generate
      signal cv, av : std_logic_vector(2*BANK_LEAVES-1 downto 1);
      type tree_id_array is array(1 to 2*BANK_LEAVES-1) of unsigned(ID_BITS-1 downto 0);
      signal ci, ai : tree_id_array;
      type tree_duration_array is array(1 to 2*BANK_LEAVES-1) of unsigned(AGE_BITS-1 downto 0);
      type tree_length_array is array(1 to 2*BANK_LEAVES-1) of unsigned(LENGTH_BITS-1 downto 0);
      signal cd, ad : tree_duration_array;
      signal cl, al : tree_length_array;
    begin
      leaves : for leaf in 0 to BANK_LEAVES-1 generate
        constant node : positive := BANK_LEAVES+leaf;
        constant frame : natural := bank*BANK_SIZE+leaf;
      begin
        present : if leaf < BANK_SIZE and frame < FRAME_COUNT generate
          cv(node) <= eligible(frame) and prequeued(frame) and route_mask(frame)(p) and cfg(frame).critical;
          av(node) <= eligible(frame) and prequeued(frame) and route_mask(frame)(p);
          ci(node) <= to_unsigned(frame, ID_BITS); ai(node) <= to_unsigned(frame, ID_BITS);
          cd(node) <= to_unsigned(duration(frame), AGE_BITS); ad(node) <= to_unsigned(duration(frame), AGE_BITS);
          cl(node) <= to_unsigned(cfg(frame).length_bytes, LENGTH_BITS); al(node) <= to_unsigned(cfg(frame).length_bytes, LENGTH_BITS);
        end generate;
        padding : if leaf >= BANK_SIZE or frame >= FRAME_COUNT generate
          cv(node) <= '0'; av(node) <= '0'; ci(node) <= (others => '0'); ai(node) <= (others => '0');
          cd(node) <= (others => '0'); ad(node) <= (others => '0');
          cl(node) <= (others => '0'); al(node) <= (others => '0');
        end generate;
      end generate;
      branches : for node in 1 to BANK_LEAVES-1 generate
        cv(node) <= cv(2*node) or cv(2*node+1); av(node) <= av(2*node) or av(2*node+1);
        ci(node) <= ci(2*node) when cv(2*node) = '1' else ci(2*node+1);
        ai(node) <= ai(2*node) when av(2*node) = '1' else ai(2*node+1);
        cd(node) <= cd(2*node) when cv(2*node) = '1' else cd(2*node+1);
        ad(node) <= ad(2*node) when av(2*node) = '1' else ad(2*node+1);
        cl(node) <= cl(2*node) when cv(2*node) = '1' else cl(2*node+1);
        al(node) <= al(2*node) when av(2*node) = '1' else al(2*node+1);
      end generate;
      c_bank_valid(bank) <= cv(1); a_bank_valid(bank) <= av(1);
      c_bank_id(bank) <= ci(1); a_bank_id(bank) <= ai(1);
      c_bank_duration(bank) <= cd(1); a_bank_duration(bank) <= ad(1);
      c_bank_length(bank) <= cl(1); a_bank_length(bank) <= al(1);
    end generate;
    root_leaf_nodes : for leaf in 0 to ROOT_LEAVES-1 generate
      constant node : positive := ROOT_LEAVES+leaf;
    begin
      present : if leaf < BANK_COUNT generate
        c_root_valid(node) <= c_bank_valid(leaf); a_root_valid(node) <= a_bank_valid(leaf);
        c_root_id(node) <= c_bank_id(leaf); a_root_id(node) <= a_bank_id(leaf);
        c_root_duration(node) <= c_bank_duration(leaf); a_root_duration(node) <= a_bank_duration(leaf);
        c_root_length(node) <= c_bank_length(leaf); a_root_length(node) <= a_bank_length(leaf);
      end generate;
      padding : if leaf >= BANK_COUNT generate
        c_root_valid(node) <= '0'; a_root_valid(node) <= '0';
        c_root_id(node) <= (others => '0'); a_root_id(node) <= (others => '0');
        c_root_duration(node) <= (others => '0'); a_root_duration(node) <= (others => '0');
        c_root_length(node) <= (others => '0'); a_root_length(node) <= (others => '0');
      end generate;
    end generate;
    root_branches : for node in 1 to ROOT_LEAVES-1 generate
      c_root_valid(node) <= c_root_valid(2*node) or c_root_valid(2*node+1);
      a_root_valid(node) <= a_root_valid(2*node) or a_root_valid(2*node+1);
      c_root_id(node) <= c_root_id(2*node) when c_root_valid(2*node) = '1' else c_root_id(2*node+1);
      a_root_id(node) <= a_root_id(2*node) when a_root_valid(2*node) = '1' else a_root_id(2*node+1);
      c_root_duration(node) <= c_root_duration(2*node) when c_root_valid(2*node) = '1' else c_root_duration(2*node+1);
      a_root_duration(node) <= a_root_duration(2*node) when a_root_valid(2*node) = '1' else a_root_duration(2*node+1);
      c_root_length(node) <= c_root_length(2*node) when c_root_valid(2*node) = '1' else c_root_length(2*node+1);
      a_root_length(node) <= a_root_length(2*node) when a_root_valid(2*node) = '1' else a_root_length(2*node+1);
    end generate;
    critical_any(p) <= c_root_valid(1); all_any(p) <= a_root_valid(1);
    critical_id(p) <= c_root_id(1); all_id(p) <= a_root_id(1);
    -- Carry the selected fields beside the ID at each unregistered tree node.
    -- No launch field depends on ID decoding or a second 180-slot reduction.
    critical_duration(p) <= c_root_duration(1); all_duration(p) <= a_root_duration(1);
    critical_length(p) <= c_root_length(1); all_length(p) <= a_root_length(1);
    choose_critical(p) <= '1' when port_blocked(p) else '0';
    choose_all(p) <= '0' when port_blocked(p) else '1';
    selected_any(p) <= critical_any(p) when port_blocked(p) else all_any(p);
    accept_any(p) <= available(p) and selected_any(p) = '1';
    winner_id(p) <= critical_id(p) when port_blocked(p) else all_id(p);
  end generate;

  process(clk)
    variable loaded_period : natural range 1 to MAX_PERIOD_TICKS;
    variable loaded_length : natural range 64 to MAX_BYTES;
    variable loaded_offset, loaded_start : natural range 0 to MAX_PERIOD_TICKS-1;
    variable loaded_duration : natural range 0 to MAX_AGE;
    variable loaded_end : natural range 0 to MAX_PERIOD_TICKS;
    variable loaded_guard : natural range 0 to MAX_PERIOD_TICKS-1;
    variable loaded_wrap, loaded_full : std_logic;
    variable next_phase : natural range 0 to MAX_PERIOD_TICKS-1;
  begin
    if rising_edge(clk) then
      down_event <= (others => '0'); error_event <= (others => '0'); gate_event <= (others => '0');
      if reset = '1' then
        phase <= (others => 0); queued <= (others => '0'); busy <= (others => '0'); age <= (others => 0);
        active_hot <= (others => (others => '0'));
        for i in 0 to FRAME_COUNT-1 loop
          due_cached(i) <= '1' when start_tick(i) = 0 else '0';
          blocked_cached(i) <= interval_blocked(0,start_tick(i),busy_end(i),guard_start(i),guard_wrap(i),guard_full(i));
        end loop;
      elsif run = '0' then
        for i in 0 to FRAME_COUNT-1 loop
          due_cached(i) <= '1' when phase(i) = start_tick(i) else '0';
          blocked_cached(i) <= interval_blocked(phase(i),start_tick(i),busy_end(i),guard_start(i),guard_wrap(i),guard_full(i));
        end loop;
        if config_we = '1' then
          assert config_value.period_ticks <= MAX_PERIOD_TICKS and config_value.period_ticks > 0
            and config_value.length_bytes >= 64 and config_value.length_bytes <= MAX_BYTES
            and config_value.offset_ticks+(config_value.length_bytes+20)*16 <= config_value.period_ticks
            report "optimized switch configuration exceeds supported range" severity failure;
          cfg(config_index) <= (config_value.destination,config_value.period_ticks,
            config_value.offset_ticks,config_value.length_bytes,config_value.critical);
          loaded_period := config_value.period_ticks;
          loaded_length := config_value.length_bytes;
          loaded_offset := config_value.offset_ticks;
          loaded_duration := (loaded_length+20)*8;
          loaded_start := loaded_offset+loaded_duration;
          loaded_end := loaded_start+loaded_duration;
          period_last(config_index) <= loaded_period-1;
          for p in 0 to 4 loop
            route_mask(config_index)(p) <= '1' when config_value.destination = p else '0';
          end loop;
          duration(config_index) <= loaded_duration;
          start_tick(config_index) <= loaded_start;
          busy_end(config_index) <= loaded_end;
          if loaded_period <= GUARD_TICKS then
            loaded_full := '1'; loaded_wrap := '0'; loaded_guard := 0;
          else
            loaded_full := '0';
            if loaded_start >= GUARD_TICKS then
              loaded_guard := loaded_start-GUARD_TICKS; loaded_wrap := '0';
            else
              loaded_guard := loaded_period-(GUARD_TICKS-loaded_start); loaded_wrap := '1';
            end if;
          end if;
          guard_full(config_index) <= loaded_full; guard_wrap(config_index) <= loaded_wrap; guard_start(config_index) <= loaded_guard;
          -- Override the selected slot using newly written fields on this edge.
          due_cached(config_index) <= '1' when phase(config_index) = loaded_start else '0';
          blocked_cached(config_index) <= interval_blocked(phase(config_index),loaded_start,loaded_end,loaded_guard,loaded_wrap,loaded_full);
        end if;
      else
        for port_id in 0 to 4 loop
          if busy(port_id) = '1' then
            if age(port_id) = active_duration(port_id) then busy(port_id) <= '0';
            else age(port_id) <= age(port_id)+1; end if;
          end if;
          if accept_any(port_id) then
            busy(port_id) <= '1'; active_id(port_id) <= to_integer(winner_id(port_id)); age(port_id) <= 1;
            active_hot(port_id) <= winner(port_id);
            if choose_critical(port_id) = '1' then
              active_duration(port_id) <= to_integer(critical_duration(port_id));
              active_length(port_id) <= to_integer(critical_length(port_id));
            else
              active_duration(port_id) <= to_integer(all_duration(port_id));
              active_length(port_id) <= to_integer(all_length(port_id));
            end if;
          end if;
        end loop;
        for i in 0 to FRAME_COUNT-1 loop
          if phase(i) = period_last(i) then next_phase := 0; else next_phase := phase(i)+1; end if;
          phase(i) <= next_phase;
          due_cached(i) <= '1' when next_phase = start_tick(i) else '0';
          blocked_cached(i) <= interval_blocked(next_phase,start_tick(i),busy_end(i),guard_start(i),guard_wrap(i),guard_full(i));
          if eligible(i) = '1' then
            if gated(i) = '1' then gate_event(i) <= '1';
            elsif accepted(i) = '1' then down_event(i) <= '1';
            else error_event(i) <= '1'; end if;
          end if;
        end loop;
        queued <= prequeued and not accepted;
      end if;
    end if;
  end process;
end architecture;
