# ILA on the coherence controller of the coherent L1 D-caches (ADR 0026), sourced by wally.tcl on the synthesized
# design when COH_ILA=1, which also defines COHERENCE_ILA: src/ebu/ahbcoherence.sv then has eight sticky checker flags
# (CohErr) and every signal of the controller in registered vectors named Coh*, all with MARK_DEBUG.
# One probe per vector, bits in index order; fpga/generator/coherence-ila-capture.tcl arms it on the board.
set coh_order {CohErrNow CohErr CohCtl CohCur CohCurAdr CohHarts CohAcqAdr CohBus CohHADDR CohHWDATA CohHRDATA}
set coh_bits [dict create]
foreach n [get_nets -hier -filter {MARK_DEBUG == 1}] {
    if {[regexp {/(Coh[A-Za-z]+)\[([0-9]+)\]$} $n -> base idx]} {
        dict lappend coh_bits $base [list $idx $n]
    }
}
create_debug_core u_ila_coh ila
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_coh]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_coh]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_coh]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_coh]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_coh]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_coh]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_coh]
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_coh]
connect_debug_port u_ila_coh/clk [get_nets CPUCLK]
set coh_log [open reports/coherence-ila-probes.txt w]
set port 0
foreach base $coh_order {
    if {![dict exists $coh_bits $base]} { puts $coh_log "$base: no nets (optimized away)"; continue }
    set nets {}
    foreach pair [lsort -integer -index 0 [dict get $coh_bits $base]] { lappend nets [lindex $pair 1] }
    if {$port > 0} { create_debug_port u_ila_coh probe }
    set_property port_width [llength $nets] [get_debug_ports u_ila_coh/probe$port]
    set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_coh/probe$port]
    connect_debug_port u_ila_coh/probe$port $nets
    puts $coh_log "probe$port $base [llength $nets] bits: [lsort -integer [lmap p [dict get $coh_bits $base] {lindex $p 0}]]"
    incr port
}
close $coh_log
