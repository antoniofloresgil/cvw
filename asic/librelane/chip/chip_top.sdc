# SPDX-License-Identifier: Apache-2.0
# From IHP's LibreLane template (ihp-sg13-librelane-template, librelane/chip_top.sdc, Apache-2.0),
# with the ports of chip/chip_top.sv and the clock activity below.
current_design $::env(DESIGN_NAME)
set_units -time ns

set clock_port __VIRTUAL_CLK__
if { [info exists ::env(CLOCK_PORT)] } {
    set port_count [llength $::env(CLOCK_PORT)]

    if { $port_count == "0" } {
        puts "\[WARNING] No CLOCK_PORT found. A dummy clock will be used."
    } elseif { $port_count != "1" } {
        puts "\[WARNING] Multi-clock files are not currently supported by the base SDC file. Only the first clock will be constrained."
    }

    if { $port_count > "0" } {
        set ::clock_port [lindex $::env(CLOCK_PORT) 0]
    }
}

if { $::env(CLOCK_PORT) == $::env(CLOCK_NET) } {
    set port_args [get_ports $clock_port]
} else {
    # This should actually use CLOCK_PIN?
    set port_args [get_pins [lindex $::env(CLOCK_NET) 0]]
}

puts "\[INFO] Using clock $clock_port…"
create_clock {*}$port_args -name $clock_port -period $::env(CLOCK_PERIOD)
# A clock defined on a pin inside the design (the clock pad's output) gets no clock activity
# for power: OpenSTA propagates the default input activity of the port through the pad, and the
# chip read 1.2 mW instead of 21 mW.  Two transitions per period, as for a clock on a port.
if { $::env(CLOCK_PORT) != $::env(CLOCK_NET) } {
    set_power_activity -pins $port_args -activity 2 -duty 0.5
}

set input_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
puts "\[INFO] Setting output delay to: $output_delay_value"
puts "\[INFO] Setting input delay to: $input_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set clocks [get_clocks $clock_port]

# The JTAG clock, on the TCK pad's output: 10 MHz at most, asynchronous to the system clock (the
# DTM crosses to the Debug Module through a toggle handshake with synchronizers, src/debug/dtm.sv)
create_clock [get_pins tck_pad/p2c] -name tck -period 100
set_power_activity -pins [get_pins tck_pad/p2c] -activity 2 -duty 0.5
set_clock_groups -asynchronous -group $clocks -group [get_clocks tck]
# TMS and TDI are sampled on the rising edge of TCK, TDO changes on its falling edge; the debugger
# samples TDO on the next rising edge.  A quarter of the period for the board.
set_input_delay -clock tck 25 [get_ports {tms_PAD tdi_PAD}]
set_output_delay -clock tck 25 [get_ports tdo_PAD]

# Input-only pads
set clk_core_input_ports [get_ports {
    rst_n_PAD
    uart_rx_PAD
    spi_miso_PAD
}]

set_input_delay -min 0 -clock $clocks $clk_core_input_ports
set_input_delay -max $input_delay_value -clock $clocks $clk_core_input_ports

# Output-only pads
set clk_core_output_ports [get_ports {
    uart_tx_PAD
    spi_sck_PAD
    spi_mosi_PAD
    spi_cs_PAD
}]

set_output_delay $output_delay_value -clock $clocks $clk_core_output_ports

# Bidirectional pads
set clk_core_inout_ports [get_ports {
    gpio_PAD[*]
}]

set_input_delay -min 0 -clock $clocks $clk_core_inout_ports
set_input_delay -max $input_delay_value -clock $clocks $clk_core_inout_ports
set_output_delay $output_delay_value -clock $clocks $clk_core_inout_ports

# The reset, UART receive and GPIO inputs are asynchronous to the clock, and the SoC synchronizes
# them (resetsync, SINd/SINsync, gpio sync1-3): their hold checks against the pad clock are
# meaningless (one was 0.09 ns short in the fast corner), and so are their setup checks.
set_false_path -from [get_ports {rst_n_PAD uart_rx_PAD gpio_PAD[*]}]

set cap_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0]
puts "\[INFO] Setting load to: $cap_load"
set_load $cap_load [all_outputs]

puts "\[INFO] Setting clock uncertainty to: $::env(CLOCK_UNCERTAINTY_CONSTRAINT)"
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) [all_clocks]

puts "\[INFO] Setting clock transition to: $::env(CLOCK_TRANSITION_CONSTRAINT)"
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) [all_clocks]

puts "\[INFO] Setting timing derate to: $::env(TIME_DERATING_CONSTRAINT)%"
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}
