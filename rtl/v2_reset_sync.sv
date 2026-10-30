// Assert reset immediately on external reset or PLL unlock; release only
// after two edges of the 100 MHz system clock. Reuse in the V2 top level.
module v2_reset_sync (
  input  logic clk_sys_100m,
  input  logic rst_n,
  input  logic pll_locked,
  output logic rst_sys_n
);
  wire async_ready_n = rst_n & pll_locked;
  logic release_meta;

  always_ff @(posedge clk_sys_100m or negedge async_ready_n) begin
    if (!async_ready_n) begin
      release_meta <= 1'b0;
      rst_sys_n    <= 1'b0;
    end else begin
      release_meta <= 1'b1;
      rst_sys_n    <= release_meta;
    end
  end
endmodule
