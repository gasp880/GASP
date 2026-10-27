set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set prototype [file join [file dirname $root] common]
set xprdir [file join $root build gasp_zcu104]
if {[file exists $xprdir]} {error "Project exists: $xprdir; use build.tcl to resume"}
set part xczu7ev-ffvc1156-2-e
if {[llength [get_parts -quiet $part]] != 1} {error "Missing device support: $part"}
create_project gasp_zcu104 $xprdir -part $part
set_param general.maxThreads 8
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]
foreach src [list [file join $prototype rtl network_types.vhd] \
    [file join $prototype split_core frame_buffer.vhd] \
    [file join $root rtl board_types.vhd] \
    [file join $root rtl board_gateway.vhd] \
    [file join $root rtl board_switch.vhd] \
    [file join $root rtl board_network.vhd] \
    [file join $root rtl gasp_metric_monitor.vhd] \
    [file join $root rtl board_executor_axi.vhd]] {
    if {![file exists $src]} {error "Missing RTL $src"}
    add_files -norecurse $src
    set_property FILE_TYPE {VHDL 2008} [get_files $src]
}
add_files -fileset constrs_1 -norecurse [file join $root constraints zcu104.xdc]
add_files -norecurse [file join $here board_executor_bd.vhd]
set_property FILE_TYPE VHDL [get_files [file join $here board_executor_bd.vhd]]
update_compile_order -fileset sources_1
create_bd_design gasp_board
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clock_100m]
set_property -dict [list CONFIG.PRIM_IN_FREQ {125.000} \
    CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true}] $cw
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 reset_100m]
set jtag [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_control]
set_property -dict [list CONFIG.PROTOCOL {2} \
    CONFIG.RD_TXN_QUEUE_LENGTH {16} CONFIG.WR_TXN_QUEUE_LENGTH {16}] $jtag
set executor [create_bd_cell -type module -reference board_executor_bd executor]
set_property -dict [list CONFIG.FRAMES_PER_PORT {36} CONFIG.MAX_BYTES {288} \
    CONFIG.RX_BYTE_CAP {65536} CONFIG.RX_EVENT_CAP {512} \
    CONFIG.PERIOD_BANKS {8} CONFIG.MAX_PERIOD_TICKS {10000000} \
    CONFIG.GUARD_TICKS {12336}] $executor
create_bd_port -dir I -type clk sys_clk_p
create_bd_port -dir I sys_clk_n
set_property CONFIG.FREQ_HZ 125000000 [get_bd_ports sys_clk_p]
connect_bd_net [get_bd_ports sys_clk_p] [get_bd_pins clock_100m/clk_in1_p]
connect_bd_net [get_bd_ports sys_clk_n] [get_bd_pins clock_100m/clk_in1_n]
connect_bd_net [get_bd_pins clock_100m/clk_out1] \
    [get_bd_pins reset_100m/slowest_sync_clk] \
    [get_bd_pins jtag_control/aclk] [get_bd_pins executor/clk]
connect_bd_net [get_bd_pins clock_100m/locked] [get_bd_pins reset_100m/dcm_locked]
set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 zero]
set_property CONFIG.CONST_VAL {0} $zero
# Board propagation configures ext/aux resets as ACTIVE_LOW. Tie them high;
# the independent mb_debug_sys_rst input is ACTIVE_HIGH and remains low.
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one]
set_property CONFIG.CONST_VAL {1} $one
connect_bd_net [get_bd_pins one/dout] [get_bd_pins reset_100m/ext_reset_in] \
    [get_bd_pins reset_100m/aux_reset_in]
connect_bd_net [get_bd_pins zero/dout] [get_bd_pins reset_100m/mb_debug_sys_rst]
connect_bd_net [get_bd_pins reset_100m/peripheral_aresetn] \
    [get_bd_pins executor/resetn] [get_bd_pins jtag_control/aresetn]
connect_bd_intf_net [get_bd_intf_pins jtag_control/M_AXI] [get_bd_intf_pins executor/S_AXI]
assign_bd_address
set segments [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_control/Data]]
if {[llength $segments] != 1} {error "Expected one JTAG executor address segment: $segments"}
set_property offset 0x00000000 $segments
set_property range 16M $segments
validate_bd_design
foreach parameter {C_EXT_RESET_HIGH C_AUX_RESET_HIGH} {
    set actual [get_property CONFIG.$parameter [get_bd_cells reset_100m]]
    if {$actual != 0} {error "Reset polarity changed: $parameter=$actual; inactive tie-high wiring requires ACTIVE_LOW"}
    puts "GASP|RESET_POLARITY|$parameter|$actual"
}
save_bd_design
set bd [get_files */gasp_board.bd]
set_property synth_checkpoint_mode None $bd
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]
set_property top gasp_board_wrapper [get_filesets sources_1]
add_files -fileset utils_1 -norecurse [list [file join $here apply_debug_tdi.tcl] [file join $root constraints debug_tdi.xdc]]
set_property STEPS.PLACE_DESIGN.TCL.PRE [file join $here apply_debug_tdi.tcl] [get_runs impl_1]
update_compile_order -fileset sources_1
# This isolated resource rebuild always starts from its own current-source
# synthesis. No failed or original implementation checkpoint is imported.
if {[info exists ::env(GASP_INCREMENTAL_DCP)]} {
    error "Compact build forbids GASP_INCREMENTAL_DCP; use a fresh implementation"
}
puts "GASP|CREATE|PASS"
