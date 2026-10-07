set_property PACKAGE_PIN E3 [get_ports default_100mhz_clk]
set_property IOSTANDARD LVCMOS33 [get_ports default_100mhz_clk]

set_property -dict {PACKAGE_PIN A8 IOSTANDARD LVCMOS33} [get_ports {GPI[0]}]
set_property -dict {PACKAGE_PIN C9 IOSTANDARD LVCMOS33} [get_ports {GPI[1]}]
set_property -dict {PACKAGE_PIN B9 IOSTANDARD LVCMOS33} [get_ports {GPI[2]}]
set_property -dict {PACKAGE_PIN B8 IOSTANDARD LVCMOS33} [get_ports {GPI[3]}]

set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports {GPO[0]}]
set_property -dict {PACKAGE_PIN F6 IOSTANDARD LVCMOS33} [get_ports {GPO[1]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {GPO[2]}]
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports {GPO[3]}]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports {GPO[4]}]

set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports UARTSin]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports UARTSout]
set_property PACKAGE_PIN C2 [get_ports resetn]
set_property IOSTANDARD LVCMOS33 [get_ports resetn]
