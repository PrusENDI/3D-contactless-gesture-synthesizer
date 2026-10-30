# Official Gowin I2C MASTER

The three vendor files are copied unchanged from Gowin V1.9.12.04:
`IDE/ipcore/I2CMASTER/data/{I2C_MASTER_TOP.v,I2C_MASTER.vp,static_macro_define.vh}`.
`top_define.vh` selects the public module name `Gowin_I2C_Master`.

The encrypted RTL is compiled for the device selected in the enclosing project
(GW5A-LV25MG121NES). No GW1N reference-design netlist, PLL, pin constraints or
bitstream is reused. Add this directory to the Verilog include paths.

The Tcl IPFlow commands in this IDE version do not successfully generate this
IP. The project therefore compiles the installed official RTL template directly.
The official IP, including its protected payload, must be preserved unchanged.

See IPUG504-1.5E for the SRAM register interface. Clock stretching has not been
confirmed by the guide or by a board test.
