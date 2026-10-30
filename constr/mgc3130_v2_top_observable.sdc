# V2 board input is 50 MHz.  The internal GW5A PLLA generates the only
# free-running system clock: IDIV=1, FBDIV=1, MDIV=16 -> 800 MHz VCO,
# ODIV0=10 -> 80 MHz (see rtl/v2_clock_gen.sv).  The PLL implementation
# exposes the generated clock automatically, so no create_generated_clock
# is needed here.  The port/signal name `clk_sys_100m` is a leftover and
# does NOT describe 100 MHz.
create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]
set_false_path -from [get_ports {uart_rx}]
