# Fresh compact source synthesis followed by an isolated non-project implementation.
# Run with Vivado in batch mode, sourcing this file. No external or incremental DCP is used.
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set out [file join $root output]
file mkdir $out
set_param general.maxThreads 8
proc stage {name} {puts "GASP|FULL_IMPL|$name|[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]"; flush stdout}
if {[info exists ::env(GASP_INCREMENTAL_DCP)]} {error "Compact build forbids incremental checkpoint reuse"}
file delete -force [file join $out build_pass.txt] [file join $out signoff.json]
set xpr [file join $root build gasp_zcu104 gasp_zcu104.xpr]
if {[file exists $xpr]} {open_project $xpr} else {source [file join $here create_project.tcl]}
set synth [get_runs synth_1]
if {[get_property NEEDS_REFRESH $synth] || [string match {*ERROR*} [get_property STATUS $synth]]} {reset_run synth_1}
stage SYNTHESIS
if {[get_property STATUS $synth] ne "synth_design Complete!"} {
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
if {[get_property STATUS $synth] ne "synth_design Complete!"} {error "Synthesis failed: [get_property STATUS $synth]"}
open_run synth_1
report_utilization -file [file join $out synthesis_utilization.rpt]
report_utilization -hierarchical -file [file join $out synthesis_hierarchy.rpt]
write_checkpoint -force [file join $out synthesis.dcp]
close_design
close_project
stage OPEN_CURRENT_SYNTHESIS
open_checkpoint [file join $out synthesis.dcp]
if {[get_property PART [current_design]] ne "xczu7ev-ffvc1156-2-e"} {error "Unexpected checkpoint part"}
stage OPT
opt_design -directive Explore
source [file join $here apply_debug_tdi.tcl]
write_checkpoint -force [file join $out optimized.dcp]
report_utilization -hierarchical -file [file join $out optimized_hierarchy.rpt]
stage PLACE
place_design -directive Explore
write_checkpoint -force [file join $out placed.dcp]
report_utilization -hierarchical -file [file join $out placed_hierarchy.rpt]
stage PHYS_OPT
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $out phys_optimized.dcp]
stage ROUTE
# Preserve a real partial DCP even if routing fails. The old attempts lost
# their almost-routed designs because a Tcl exception ended the process.
set route_code [catch {route_design -directive RuntimeOptimized} route_error]
if {$route_code} {
    puts "GASP|ROUTE|INITIAL_FAILED|$route_error"
    if {[catch {write_checkpoint -force [file join $out route_failed_initial.dcp]} save_error]} {
        puts "GASP|ROUTE|PARTIAL_SAVE_FAILED|$save_error"
    }
    stage ROUTE_REPAIR
    if {[catch {route_design -directive Explore} repair_error]} {
        catch {write_checkpoint -force [file join $out route_failed_repair.dcp]}
        error "Routing failed initial and bounded Explore repair: $repair_error"
    }
}
write_checkpoint -force [file join $out routed_initial.dcp]
set repair 0
foreach type {max min} {
    set p [get_timing_paths -quiet -delay_type $type -max_paths 1 -no_report_unconstrained]
    if {[llength $p] != 1 || [get_property SLACK $p] < 0} {set repair 1}
}
if {$repair} {
    stage POST_ROUTE_PHYS_OPT
    phys_opt_design -directive AggressiveExplore
    stage POST_ROUTE_ROUTE
    if {[catch {route_design -directive Explore} timing_error]} {
        catch {write_checkpoint -force [file join $out route_failed_timing_repair.dcp]}
        error "Post-route timing repair could not route: $timing_error"
    }
}
stage SIGNOFF
write_checkpoint -force [file join $out routed.dcp]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out hierarchy.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -report_unconstrained -max_paths 20 -file [file join $out timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $out setup_paths.rpt]
report_timing -delay_type min -max_paths 20 -file [file join $out hold_paths.rpt]
report_drc -file [file join $out drc.rpt]
report_route_status -file [file join $out route_status.rpt]
report_clocks -file [file join $out clocks.rpt]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
report_methodology -file [file join $out methodology.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
set slacks {}
foreach type {max min} {
    set p [get_timing_paths -quiet -delay_type $type -max_paths 1 -no_report_unconstrained]
    if {[llength $p] != 1} {error "No valid $type timing path"}
    set slack [get_property SLACK $p]
    if {$slack eq "" || $slack < 0} {error "Timing failed $type=$slack; routed checkpoint and reports retained"}
    dict set slacks $type $slack
    puts "GASP|TIMING|$type|$slack"
}
set fd [open [file join $out check_timing.rpt] r]
set checks [read $fd]; close $fd
set matches [regexp -all -inline {checking ([a-z_]+) \(([0-9]+)\)} $checks]
foreach {full name count} $matches {
    if {$count != 0} {error "Unresolved timing check $name=$count"}
}
if {[llength $matches] == 0} {error "Unrecognized check_timing report"}
set fd [open [file join $out timing_summary.rpt] r]
set timing_text [read $fd]; close $fd
if {![string match {*All user specified timing constraints are met*} $timing_text]} {
    error "Timing summary did not confirm all constraints met"
}
if {![regexp {(?s)\| Unconstrained Path Table.*?\| Timing Details} $timing_text unconstrained_section]} {
    error "Unable to audit actual unconstrained path table"
}
foreach table_line [split $unconstrained_section "\n"] {
    set table_line [string trim $table_line]
    if {$table_line eq "" || [regexp {^[|\-]} $table_line] || [string match {Path Group*} $table_line]} {continue}
    error "Actual unconstrained paths remain: $table_line; report retained"
}
set drc_count [llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]
if {$drc_count > 0} {error "Unresolved DRC"}
set route_counts {}
foreach status {PARTIAL UNPLACED UNROUTED NODRIVER ANTENNAS CONFLICTS} {
    set n [llength [get_nets -quiet -hierarchical -filter "ROUTE_STATUS == $status"]]
    dict set route_counts $status $n
    if {$n > 0} {error "Unresolved routing $status=$n"}
}
# This file is emitted only after every real implementation check passed.
set fd [open [file join $out signoff.json] w]
puts $fd "\{"
puts $fd "  \"status\": \"passed\","
puts $fd "  \"vivado_version\": \"[version -short]\","
puts $fd "  \"part\": \"[get_property PART [current_design]]\","
puts $fd "  \"setup_slack_ns\": [dict get $slacks max],"
puts $fd "  \"hold_slack_ns\": [dict get $slacks min],"
puts $fd "  \"actual_unconstrained_path_table_empty\": true,"
puts $fd "  \"check_timing_nonzero_categories\": 0,"
puts $fd "  \"drc_errors_and_critical_warnings\": $drc_count,"
puts $fd "  \"route_faults\": \{"
set sep ""
foreach status {PARTIAL UNPLACED UNROUTED NODRIVER ANTENNAS CONFLICTS} {
    puts -nonewline $fd "$sep    \"$status\": [dict get $route_counts $status]"
    set sep ",\n"
}
puts $fd "\n  \}\n\}"
close $fd
stage BITSTREAM
write_bitstream -force [file join $out gasp_zcu104.bit]
write_debug_probes -force [file join $out gasp_zcu104.ltx]
set fd [open [file join $out build_pass.txt] w]
puts $fd "Vivado [version -short]; part [get_property PART [current_design]]; setup [dict get $slacks max]; hold [dict get $slacks min]; fresh current-source synthesis and nonproject implementation"
close $fd
puts "GASP|BUILD|PASS"
stage COMPLETE
