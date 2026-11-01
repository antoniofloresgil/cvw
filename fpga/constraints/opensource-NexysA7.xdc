set_property PACKAGE_PIN E3 [get_ports default_100mhz_clk]
set_property IOSTANDARD LVCMOS33 [get_ports default_100mhz_clk]

set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {GPI[0]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {GPI[1]}]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {GPI[2]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {GPI[3]}]

set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {GPO[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {GPO[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {GPO[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {GPO[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {GPO[4]}]

set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports UARTSin]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports UARTSout]
set_property PACKAGE_PIN C12 [get_ports resetn]
set_property IOSTANDARD LVCMOS33 [get_ports resetn]
