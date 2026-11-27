# Capture the coherence controller's ILA (COH_ILA=1 builds, ../constraints/coherence-ila.tcl) on a programmed board.
#   vivado -mode batch -source coherence-ila-capture.tcl -tclargs <mode> <probes.ltx> <out.csv> [timeout minutes]
# mode arm: trigger when a checker fires (CohErrNow != 0), with 4000 of the 4096 samples before the trigger;
#           waits up to the timeout (default 120 minutes)
# mode now: capture immediately, e.g. when Linux is already hung; also shows the sticky flags (CohErr)
# The board must already hold the bitstream that wrote <probes.ltx> (openFPGALoader -b nexysVideo fpgaTop.bit).
set mode    [lindex $argv 0]
set ltx     [lindex $argv 1]
set out     [lindex $argv 2]
set timeout [expr {[llength $argv] > 3 ? [lindex $argv 3] : 120}]

open_hw_manager
connect_hw_server -allow_non_jtag
# A Digilent FT2232 shows up as two targets and only one of them reaches the FPGA
set dev ""
foreach t [get_hw_targets] {
    if {[catch {open_hw_target $t}]} { catch {close_hw_target $t}; continue }
    set dev [lindex [get_hw_devices -quiet xc7a200t*] 0]
    if {$dev ne ""} break
    close_hw_target $t
}
if {$dev eq ""} { puts "No xc7a200t on any JTAG target"; exit 1 }
# The debug hub runs on the 20 MHz SoC clock: JTAG must be at most 2.5 times slower, or the uploaded data is corrupted
close_hw_target $t
set_property PARAM.FREQUENCY 3000000 [get_hw_targets $t]
open_hw_target $t
set dev [lindex [get_hw_devices xc7a200t*] 0]
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set_property CONTROL.DATA_DEPTH 4096 $ila

proc probe {ila name} { return [lindex [get_hw_probes -of_objects $ila -filter "NAME =~ *$name"] 0] }

if {$mode eq "arm"} {
    set p [probe $ila CohErrNow]
    set w [get_property WIDTH $p]
    set_property TRIGGER_COMPARE_VALUE "neq${w}'h[string repeat 0 [expr {($w + 3) / 4}]]" $p
    set_property CONTROL.TRIGGER_POSITION 4000 $ila
    set_property CONTROL.TRIGGER_CONDITION AND $ila
    run_hw_ila $ila
    puts "ILA armed: waiting up to $timeout minutes for a checker"
    if {[catch {wait_on_hw_ila -timeout $timeout $ila} err]} {
        puts "No checker fired within $timeout minutes ($err)"
        exit 2
    }
} elseif {$mode eq "now"} {
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    run_hw_ila -trigger_now $ila
    wait_on_hw_ila $ila
} else {
    puts "mode must be arm or now"
    exit 1
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $out $data
puts "Captured to $out"
