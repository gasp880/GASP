# The debug hub is inserted during opt_design. Apply the verified input
# constraints before placement, when its real BSCAN timing pins exist.
set gasp_board_root [file dirname [file dirname [file normalize [info script]]]]
source [file join $gasp_board_root constraints debug_tdi.xdc]
puts "GASP|JTAG_TIMING|TCK_MAX_HZ=10000000|TDI_MAX_NS=25|TDI_MIN_NS=-10"
