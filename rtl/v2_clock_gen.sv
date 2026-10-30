// V2 clock boundary: 50 MHz board oscillator to a single 100 MHz system clock.
// Simulation uses V2_SIM to bypass the device PLL and keep testbenches portable.
module v2_clock_gen (
  input  logic clk_in,
  input  logic rst_n,
  output logic clk_sys_100m,
  output logic pll_locked
);
`ifdef V2_SIM
  assign clk_sys_100m = clk_in;
  assign pll_locked   = rst_n;
`else
  wire clk_pll;
  wire pll_lock_i;
  // GW5A PLLA: 50 / 1 * 1 * 16 = 800 MHz VCO; / 10 = 80 MHz (documented fallback).
  PLLA #(
    .FCLKIN("50.0"),
    .IDIV_SEL(1),
    .FBDIV_SEL(1),
    .MDIV_SEL(16),
    .ODIV0_SEL(10),
    .CLKOUT0_EN("TRUE"),
    .CLKOUT1_EN("FALSE"),
    .CLKOUT2_EN("FALSE"),
    .CLKOUT3_EN("FALSE"),
    .CLKOUT4_EN("FALSE"),
    .CLKOUT5_EN("FALSE"),
    .CLKOUT6_EN("FALSE"),
    .CLKFB_SEL("INTERNAL")
  ) u_pll (
    .CLKOUT0(clk_pll), .CLKOUT1(), .CLKOUT2(), .CLKOUT3(),
    .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUT(),
    .LOCK(pll_lock_i), .CLKIN(clk_in), .CLKFB(1'b0), .MDRDO(),
    .MDCLK(1'b0), .MDOPC(2'd0), .MDAINC(1'b0), .MDWDI(8'd0),
    .PSSEL(3'd0), .PSDIR(1'b0), .PSPULSE(1'b0), .SSCPOL(1'b0),
    .SSCON(1'b0), .SSCMDSEL(7'd0), .SSCMDSEL_FRAC(3'd0),
    .RESET(~rst_n), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0)
  );
  assign clk_sys_100m = clk_pll;
  assign pll_locked   = pll_lock_i;
`endif
endmodule
