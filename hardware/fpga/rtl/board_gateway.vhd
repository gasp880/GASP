-- Resource-optimized source gateway. One-cycle template prefetch preserves
-- the original byte-valid cycles. Configuration remains programmable.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.network_types.all;
use work.board_types.all;
library unisim;
use unisim.vcomponents.all;

entity board_gateway is
  generic (FRAME_COUNT : positive := 5; MAX_BYTES : positive := 128;
    GUARD_TICKS : natural := 12336; PORT_ID : natural := 0;
    MAX_PERIOD_TICKS : positive := 10000000; PERIOD_BANKS : positive := 8);
  port (clk, reset, run, config_we, data_we : in std_logic;
    config_index : in natural range 0 to FRAME_COUNT-1;
    config_value : in frame_config;
    data_address : in natural range 0 to MAX_BYTES-1; data_value : in std_logic_vector(12 downto 0);
    enabled : in std_logic_vector(FRAME_COUNT-1 downto 0);
    epochs : in epoch_array(0 to PERIOD_BANKS-1);
    snapshot_epochs : out epoch_array(0 to PERIOD_BANKS-1);
    debug_read : in std_logic; debug_word : out std_logic_vector(12 downto 0);
    template_meta : out std_logic_vector(4 downto 0);
    now_tick : in natural; queued : in std_logic_vector(FRAME_COUNT-1 downto 0);
    template_byte : out byte_t; transformed_byte : in byte_t; snapshot : out natural;
    byte_valid : out std_logic; byte_frame, byte_index : out natural;
    byte_data : out byte_t; byte_last : out std_logic;
    tx_event, error_event, gate_event : out std_logic_vector(FRAME_COUNT-1 downto 0));
end entity;

architecture rtl of board_gateway is
  constant MAX_AGE : natural := (MAX_BYTES+20)*8;
  function id_width(count : positive) return positive is
    variable width : positive := 1;
  begin
    while 2**width < count loop width := width+1; end loop;
    return width;
  end function;
  constant ID_BITS : positive := id_width(FRAME_COUNT);
  type local_config is record
    source : natural range 0 to 4;
    period_ticks : natural range 1 to MAX_PERIOD_TICKS;
    offset_ticks : natural range 0 to MAX_PERIOD_TICKS-1;
    length_bytes : natural range 64 to MAX_BYTES;
    critical, refresh_crc : std_logic;
  end record;
  type local_configs is array(0 to FRAME_COUNT-1) of local_config;
  type phase_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_PERIOD_TICKS-1;
  type duration_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_AGE;
  type boundary_array is array(0 to FRAME_COUNT-1) of natural range 0 to MAX_PERIOD_TICKS;
  type template_memory is array(0 to FRAME_COUNT*MAX_BYTES-1) of std_logic_vector(12 downto 0);
  signal cfg : local_configs := (others => (0,1,0,64,'1','1'));
  signal phase : phase_array := (others => 0);
  -- Configuration-derived tables survive run-state reset together with cfg.
  signal duration : duration_array := (others => 672);
  signal start_tick, guard_start : phase_array := (others => 0);
  signal busy_end : boundary_array := (others => 0);
  signal guard_wrap : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '0');
  signal guard_full : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '1');
  signal memory : template_memory;
  signal prefetched : std_logic_vector(12 downto 0);
  signal busy : std_logic := '0';
  signal active_length : natural range 64 to MAX_BYTES := 64;
  signal active_duration : natural range 0 to MAX_AGE := 672;
  signal active_refresh_crc : std_logic := '1';
  signal active_id : natural range 0 to FRAME_COUNT-1 := 0;
  signal age : natural range 0 to MAX_AGE := 0;
  signal snap : natural := 0;
  signal crc : unsigned(31 downto 0) := (others => '1');
  signal read_enable : std_logic;
  signal read_address : natural range 0 to FRAME_COUNT*MAX_BYTES-1;
  function raw_guard(p, first, last, guard_first : natural;
                     full_guard, wrapped_guard : std_logic) return std_logic is
  begin
    if full_guard = '1' or (p >= first and p < last) or
       (wrapped_guard = '1' and (p >= guard_first or p <= first)) or
       (wrapped_guard = '0' and p >= guard_first and p <= first) then
      return '1';
    end if;
    return '0';
  end function;
  signal phase_next : phase_array;
  -- At a run edge, cache the decision for the phase that will be visible
  -- immediately after that edge. No launch or byte event is delayed.
  signal due_raw : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '1');
  signal guard_raw : std_logic_vector(FRAME_COUNT-1 downto 0) := (others => '1');
  signal port_blocked : boolean;
  signal guard_blocked, eligible, gated, winner : std_logic_vector(FRAME_COUNT-1 downto 0);
  signal critical_requests, best_effort_requests : std_logic_vector(FRAME_COUNT-1 downto 0);
  signal critical_winner, best_effort_winner : std_logic_vector(FRAME_COUNT-1 downto 0);
  signal winner_id : unsigned(ID_BITS-1 downto 0);
  signal winner_length : natural range 0 to MAX_BYTES;
  signal winner_duration : natural range 0 to MAX_AGE;
  signal winner_refresh_crc : std_logic;
  signal available, accept_any : boolean;
  signal available_bit, critical_any, best_effort_allowed : std_logic;
begin
  assert MAX_BYTES >= 64 and PORT_ID <= 4 severity failure;
  snapshot <= snap;
  template_byte <= prefetched(7 downto 0); template_meta <= prefetched(12 downto 8); debug_word <= prefetched;

  -- Fetch at age 71,79,... so byte 0,1,... remains visible at 72,80,...
  process(all)
    variable j : natural range 0 to MAX_BYTES+12;
  begin
    read_enable <= '0'; read_address <= 0;
    if run = '0' and debug_read = '1' then read_enable <= '1'; read_address <= config_index*MAX_BYTES+data_address; end if;
    byte_valid <= '0'; byte_last <= '0'; byte_frame <= active_id;
    byte_index <= 0; byte_data <= transformed_byte;
    if run = '1' and busy = '1' then
      if age >= 71 and age mod 8 = 7 then
        j := (age+1)/8-9;
        if j < active_length then
          read_enable <= '1'; read_address <= active_id*MAX_BYTES+j;
        end if;
      end if;
      if age >= 72 and age mod 8 = 0 then
        j := age/8-9;
        if j < active_length then
          byte_valid <= '1'; byte_index <= j;
          if j = active_length-1 then byte_last <= '1'; end if;
          if active_refresh_crc = '1' and j >= active_length-4 then
            case j-(active_length-4) is
              when 0 => byte_data <= not std_logic_vector(crc(7 downto 0));
              when 1 => byte_data <= not std_logic_vector(crc(15 downto 8));
              when 2 => byte_data <= not std_logic_vector(crc(23 downto 16));
              when 3 => byte_data <= not std_logic_vector(crc(31 downto 24));
              when others => null;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '0' and run = '0' and data_we = '1' then
        memory(config_index*MAX_BYTES+data_address) <= data_value;
      end if;
      if read_enable = '1' then prefetched <= memory(read_address); end if;
    end if;
  end process;

  -- Phase and raw interval comparisons are private to each slot. The
  -- registered flags match phase, including reset, stopped runs, and writes
  -- of a new configuration at a held phase.
  phase_predictions : for k in 0 to FRAME_COUNT-1 generate
    phase_next(k) <= 0 when phase(k) = cfg(k).period_ticks-1 else phase(k)+1;
    process(clk)
      variable p : natural range 0 to MAX_PERIOD_TICKS-1;
      variable first, guard_first : natural range 0 to MAX_PERIOD_TICKS-1;
      variable last : natural range 0 to MAX_PERIOD_TICKS;
      variable full_guard, wrapped_guard : std_logic;
    begin
      if rising_edge(clk) then
        if reset = '1' then p := 0;
        elsif run = '1' then p := phase_next(k);
        else p := phase(k); end if;
        first := start_tick(k); last := busy_end(k);
        guard_first := guard_start(k);
        full_guard := guard_full(k); wrapped_guard := guard_wrap(k);
        if reset = '0' and run = '0' and config_we = '1' and config_index = k then
          first := config_value.offset_ticks;
          last := first+(config_value.length_bytes+20)*8;
          if config_value.period_ticks <= GUARD_TICKS then
            full_guard := '1'; wrapped_guard := '0'; guard_first := 0;
          else
            full_guard := '0';
            if first >= GUARD_TICKS then
              guard_first := first-GUARD_TICKS; wrapped_guard := '0';
            else
              guard_first := config_value.period_ticks-(GUARD_TICKS-first); wrapped_guard := '1';
            end if;
          end if;
        end if;
        if p = first then due_raw(k) <= '1'; else due_raw(k) <= '0'; end if;
        guard_raw(k) <= raw_guard(p,first,last,guard_first,full_guard,wrapped_guard);
      end if;
    end process;
    -- enabled/source remain current-cycle qualifiers, rather than part of
    -- the predictive cache; callers may vary enabled on every run edge.
    guard_blocked(k) <= guard_raw(k) when enabled(k) = '1' and
      cfg(k).critical = '1' and cfg(k).source = PORT_ID else '0';
  end generate;
  port_blocked <= (or guard_blocked) = '1';

  -- Arbitrate the two classes independently. The global guard reduction
  -- appears only at the final best-effort selection, outside either tree.
  -- Every eligible critical frame blocks this port, even when queued.
  available <= busy = '0' or age = active_duration;
  request_checks : for i in 0 to FRAME_COUNT-1 generate
    eligible(i) <= due_raw(i) when enabled(i) = '1' and cfg(i).source = PORT_ID else '0';
    gated(i) <= '1' when eligible(i) = '1' and cfg(i).critical = '0' and port_blocked else '0';
    critical_requests(i) <= eligible(i) and cfg(i).critical and not queued(i);
    best_effort_requests(i) <= eligible(i) and not cfg(i).critical and not queued(i);
    first_request : if i = 0 generate
      critical_winner(i) <= critical_requests(i);
      best_effort_winner(i) <= best_effort_requests(i);
    end generate;
    later_request : if i > 0 generate
      critical_winner(i) <= critical_requests(i) and not (or critical_requests(i-1 downto 0));
      best_effort_winner(i) <= best_effort_requests(i) and not (or best_effort_requests(i-1 downto 0));
    end generate;
    winner(i) <= critical_winner(i) or best_effort_winner(i) when not port_blocked else critical_winner(i);
  end generate;
  available_bit <= '1' when available else '0';
  critical_any <= or critical_requests;
  best_effort_allowed <= (or best_effort_requests) when not port_blocked else '0';
  accept_any <= available and (critical_any = '1' or best_effort_allowed = '1');

  -- Each epoch bank gets its own combinational launch LUT. Preserving these
  -- eight small local gates bounds snapshot CE fanout without registering
  -- the launch event or moving its epoch-sampling edge.
  epoch_banks : for bank in 0 to PERIOD_BANKS-1 generate
    signal bank_launch : std_logic;
    attribute DONT_TOUCH : string;
    attribute DONT_TOUCH of launch_gate : label is "TRUE";
  begin
    launch_gate : LUT3 generic map(INIT => X"A8")
      port map(I0 => available_bit, I1 => critical_any,
               I2 => best_effort_allowed, O => bank_launch);
    process(clk)
    begin
      if rising_edge(clk) then
        if reset = '0' and run = '1' and bank_launch = '1' then
          snapshot_epochs(bank) <= epochs(bank);
        end if;
      end if;
    end process;
  end generate;

  -- One-hot field ORs avoid repeatedly selecting the active slot's wide
  -- length/duration tables while a frame is being emitted.
  process(all)
    variable length_bits : unsigned(id_width(MAX_BYTES+1)-1 downto 0);
    variable duration_bits : unsigned(id_width(MAX_AGE+1)-1 downto 0);
    variable refresh_bit : std_logic;
  begin
    length_bits := (others => '0'); duration_bits := (others => '0'); refresh_bit := '0';
    for i in 0 to FRAME_COUNT-1 loop
      if winner(i) = '1' then
        length_bits := length_bits or to_unsigned(cfg(i).length_bytes,length_bits'length);
        duration_bits := duration_bits or to_unsigned(duration(i),duration_bits'length);
        refresh_bit := refresh_bit or cfg(i).refresh_crc;
      end if;
    end loop;
    winner_length <= to_integer(length_bits); winner_duration <= to_integer(duration_bits);
    winner_refresh_crc <= refresh_bit;
  end process;
  encode_id : for bit_index in 0 to ID_BITS-1 generate
    signal bit_requests : std_logic_vector(FRAME_COUNT-1 downto 0);
  begin
    encode_requests : for i in 0 to FRAME_COUNT-1 generate
      bit_requests(i) <= winner(i) when (i/(2**bit_index)) mod 2 = 1 else '0';
    end generate;
    winner_id(bit_index) <= or bit_requests;
  end generate;

  process(clk)
    variable loaded_period : natural range 1 to MAX_PERIOD_TICKS;
    variable loaded_length : natural range 64 to MAX_BYTES;
    variable loaded_start : natural range 0 to MAX_PERIOD_TICKS-1;
    variable loaded_duration : natural range 0 to MAX_AGE;
    variable loaded_end : natural range 0 to MAX_PERIOD_TICKS;
  begin
    if rising_edge(clk) then
      tx_event <= (others => '0'); error_event <= (others => '0'); gate_event <= (others => '0');
      if reset = '1' then
        phase <= (others => 0); busy <= '0'; age <= 0; snap <= 0; crc <= (others => '1');
      elsif run = '0' then
        -- Preserve the old paused-run semantics if a selected slot is
        -- reconfigured while run is low.
        active_length <= cfg(active_id).length_bytes;
        active_duration <= duration(active_id);
        active_refresh_crc <= cfg(active_id).refresh_crc;
        if config_we = '1' then
          assert config_value.period_ticks <= MAX_PERIOD_TICKS and config_value.period_ticks > 0
            and config_value.length_bytes >= 64 and config_value.length_bytes <= MAX_BYTES
            and config_value.offset_ticks+(config_value.length_bytes+20)*16 <= config_value.period_ticks
            report "optimized gateway configuration exceeds supported range" severity failure;
          cfg(config_index) <= (config_value.source, config_value.period_ticks,
            config_value.offset_ticks, config_value.length_bytes, config_value.critical, config_value.refresh_crc);
          loaded_period := config_value.period_ticks;
          loaded_length := config_value.length_bytes;
          loaded_start := config_value.offset_ticks;
          loaded_duration := (loaded_length+20)*8;
          loaded_end := loaded_start+loaded_duration;
          duration(config_index) <= loaded_duration;
          if config_index = active_id then
            active_length <= loaded_length; active_duration <= loaded_duration;
            active_refresh_crc <= config_value.refresh_crc;
          end if;
          start_tick(config_index) <= loaded_start;
          busy_end(config_index) <= loaded_end;
          if loaded_period <= GUARD_TICKS then
            guard_full(config_index) <= '1'; guard_wrap(config_index) <= '0'; guard_start(config_index) <= 0;
          else
            guard_full(config_index) <= '0';
            if loaded_start >= GUARD_TICKS then
              guard_start(config_index) <= loaded_start-GUARD_TICKS; guard_wrap(config_index) <= '0';
            else
              guard_start(config_index) <= loaded_period-(GUARD_TICKS-loaded_start); guard_wrap(config_index) <= '1';
            end if;
          end if;
        end if;
      else
        if busy = '1' then
          if byte_valid = '1' and byte_index < active_length-4 then
            crc <= crc_byte(crc,transformed_byte);
          end if;
          if age = active_duration then busy <= '0';
          else age <= age+1; end if;
        end if;
        for i in 0 to FRAME_COUNT-1 loop
          phase(i) <= phase_next(i);
          if eligible(i) = '1' then
            if gated(i) = '1' then gate_event(i) <= '1';
            elsif not available or queued(i) = '1' or winner(i) = '0' then error_event(i) <= '1';
            else tx_event(i) <= '1'; end if;
          end if;
        end loop;
        if accept_any then
          busy <= '1'; active_id <= to_integer(winner_id); age <= 1;
          snap <= now_tick; crc <= (others => '1');
          active_length <= winner_length; active_duration <= winner_duration;
          active_refresh_crc <= winner_refresh_crc;
        end if;
      end if;
    end if;
  end process;
end architecture;
