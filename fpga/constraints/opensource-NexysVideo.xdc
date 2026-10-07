set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports default_100mhz_clk]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS15} [get_ports resetn]

set_property -dict {PACKAGE_PIN E22 IOSTANDARD LVCMOS12} [get_ports {GPI[0]}]
set_property -dict {PACKAGE_PIN F21 IOSTANDARD LVCMOS12} [get_ports {GPI[1]}]
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVCMOS12} [get_ports {GPI[2]}]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS12} [get_ports {GPI[3]}]

set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS25} [get_ports {GPO[0]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS25} [get_ports {GPO[1]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS25} [get_ports {GPO[2]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS25} [get_ports {GPO[3]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS25} [get_ports {GPO[4]}]

set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports UARTSin]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports UARTSout]
