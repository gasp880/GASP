# Verified in-memory on the original routed board DCP with Vivado 2025.2.
# Identical pin/clock selection and commands to conservative25_min10_10mhz.
# Requires real hardware TCK <=10MHz, set/read back by program/measure scripts.
# Adds bounded input setup/hold checks (no false_path/multicycle).
set gasp_tdi_bscan dbg_hub/inst/BSCANID.u_xsdbm_id/SWITCH_N_EXT_BSCAN.bscan_inst/SERIES7_BSCAN.bscan_inst
set gasp_tdi_pin [get_pins ${gasp_tdi_bscan}/INTERNAL_TDI]
set gasp_tck_pin [get_pins ${gasp_tdi_bscan}/INTERNAL_TCK]
if {[llength $gasp_tdi_pin] != 1 || [llength $gasp_tck_pin] != 1} {error "Expected one native BSCANE2 internal TDI/TCK pin"}
set gasp_jtag_clock [get_clocks -of_objects $gasp_tck_pin]
if {[llength $gasp_jtag_clock] != 1} {error "Expected one original JTAG clock"}
set gasp_jtag_clock_name [get_property NAME $gasp_jtag_clock]
# Same source pin and same name; no -add, so no duplicate launch clock.
create_clock -name $gasp_jtag_clock_name -period 100.0 -waveform {0.0 50.0} $gasp_tck_pin
set gasp_jtag_clock [get_clocks -of_objects $gasp_tck_pin]
if {[llength $gasp_jtag_clock] != 1} {error "JTAG clock duplication after override"}
set_input_delay -clock $gasp_jtag_clock -clock_fall -max 25.0 $gasp_tdi_pin
set_input_delay -clock $gasp_jtag_clock -clock_fall -min -10.0 $gasp_tdi_pin
