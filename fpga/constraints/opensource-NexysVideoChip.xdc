# Nexys Video pins of fpgaChip (asic_soc_rv32imac, open-source flow).  The pin numbers of the clock, reset, SW0-3, LD0-4 and the UART
# are those of opensource-NexysVideo.xdc; SW4-7 and LD5-7 are from Digilent's Nexys Video master constraints and must be checked
# against the board's reference manual before the first bitstream is loaded.
set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports default_100mhz_clk]
create_clock -name default_100mhz_clk -period 10.000 [get_ports default_100mhz_clk]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS15} [get_ports resetn]

set_property -dict {PACKAGE_PIN E22 IOSTANDARD LVCMOS12} [get_ports {SW[0]}]
set_property -dict {PACKAGE_PIN F21 IOSTANDARD LVCMOS12} [get_ports {SW[1]}]
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVCMOS12} [get_ports {SW[2]}]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS12} [get_ports {SW[3]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS12} [get_ports {SW[4]}]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS12} [get_ports {SW[5]}]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS12} [get_ports {SW[6]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS12} [get_ports {SW[7]}]

set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS25} [get_ports {LD[0]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS25} [get_ports {LD[1]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS25} [get_ports {LD[2]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS25} [get_ports {LD[3]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS25} [get_ports {LD[4]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS25} [get_ports {LD[5]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS25} [get_ports {LD[6]}]
set_property -dict {PACKAGE_PIN Y13 IOSTANDARD LVCMOS25} [get_ports {LD[7]}]

set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports UARTSin]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports UARTSout]
