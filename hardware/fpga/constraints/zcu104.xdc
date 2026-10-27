# AMD XTP484 schematic sheet 4 / RDF0438 Rev 1.0 master XDC:
# CLK_125_P/N from the U182 clock generator -> F23/E23, LVDS.
# UG1267 v1.1 table 3-13 disagrees; schematic and companion XDC agree.
# https://docs.amd.com/v/u/en-US/ZCU104-Schematics-XTP484
# Clock Wizard emits the primary 8 ns constraint and 100 MHz derived clock.
set_property PACKAGE_PIN F23 [get_ports sys_clk_p]
set_property PACKAGE_PIN E23 [get_ports sys_clk_n]
set_property IOSTANDARD LVDS [get_ports {sys_clk_p sys_clk_n}]
