# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# The chip asic_soc_rv32imac on the Nexys Video with Vivado (non-project flow), to compare with the open-source flow
# (build-opensource.sh nexysvideochip) on the same sources, clock and pins.  Run through `make nexysvideochip-vivado`, which first
# prepares ../src/CopiedFiles_do_not_add_to_repo; everything it writes goes to vivado-nexysvideochip/, nothing of the open flow's output.
set part xc7a200tsbg484-1
set out vivado-nexysvideochip
set src ../src/CopiedFiles_do_not_add_to_repo
file mkdir $out

# cvw.sv first: its macros are used by the other files
set sv [list $src/fpgaChip.sv]
foreach f [exec find $src -type f -name *.sv | sort] {
    if {[file tail $f] ne "fpgaChip.sv" && [file tail $f] ne "cvw.sv"} { lappend sv $f }
}
read_verilog -sv $src/cvw.sv
read_verilog -sv $sv
read_verilog $src/fpgaChipClk.v
read_xdc ../constraints/opensource-NexysVideoChip.xdc

synth_design -top fpgaChip -part $part -include_dirs [list $src/config ../../config/shared $src] -flatten_hierarchy rebuilt
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/utilization_synth.rpt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/post_route.dcp
report_utilization -file $out/utilization.rpt
report_timing_summary -file $out/timing_summary.rpt
report_clock_utilization -file $out/clock_utilization.rpt
write_bitstream -force $out/nexysvideochip.bit
