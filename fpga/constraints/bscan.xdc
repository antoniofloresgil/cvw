# JTAG debug through the FPGA's TAP (fpga/src/fpgaTopNexysA7.sv, DEBUG_SUPPORTED): TCK of the BSCANE2 primitives, at
# most 30 MHz from the board's FT2232, asynchronous to every other clock (the DTM crosses to the system clock with
# toggles).
create_clock -period 33.333 -name jtag_tck [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == BSCANE2 && NAME =~ *user3*}] -filter {REF_PIN_NAME == TCK}]
set_clock_groups -asynchronous -group [get_clocks jtag_tck]
