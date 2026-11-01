`timescale 1ns/1ps
// The contour capture must not depend on when the host arms it.
//
// Arming only starts a search for the next tick 0; the 32 samples are then
// written in order, so the array index always equals the loop tick and a half
// captured loop leaves the rest of the loop as rests (valid=0) instead of a
// rotated melody.
module tb_loop_contour_capture;
  localparam integer K = 32;

  logic clk = 0, rst_n = 0;
  logic arm = 0;
  logic tick_pulse = 0;
  logic [6:0] mtick = 0;
  logic [15:0] y = 0;
  logic engaged = 0;
  logic [4:0] rd_index = 0;
  logic [15:0] rd_data;
  logic [K-1:0] valid_mask;
  logic full;

  integer t, bad;

  always #5 clk = ~clk;

  v2_loop_contour_capture #(.K(K)) dut (
    .clk(clk), .rst_n(rst_n), .arm(arm),
    .tick_pulse(tick_pulse), .mtick(mtick), .y(y), .engaged(engaged),
    .rd_index(rd_index), .rd_data(rd_data), .valid_mask(valid_mask), .full(full));

  task automatic pulse_arm;
    begin
      @(negedge clk);
      arm = 1'b1;
      @(negedge clk);
      arm = 1'b0;
    end
  endtask

  task automatic tick(input integer tick_no, input [15:0] y_value, input logic eng);
    begin
      @(negedge clk);
      mtick = tick_no[6:0];
      y = y_value;
      engaged = eng;
      tick_pulse = 1'b1;
      @(negedge clk);
      tick_pulse = 1'b0;
    end
  endtask

  task automatic read_sample(input integer idx, output [15:0] value);
    begin
      rd_index = idx[4:0];
      #1;
      value = rd_data;
    end
  endtask

  task automatic expect_sample(input integer idx, input [15:0] want);
    logic [15:0] got;
    begin
      read_sample(idx, got);
      if (got !== want)
        $fatal(1, "sample[%0d]=%0d expected %0d", idx, got, want);
    end
  endtask

  initial begin : run_tb
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // 1) arm at tick 5: nothing may be written before the next tick 0.
    pulse_arm();
    for (t = 5; t < 32; t = t + 1) tick(t, 16'd100 + t[15:0], 1'b1);
    if (full) $fatal(1, "full asserted before the first tick 0");
    if (valid_mask !== {K{1'b0}}) $fatal(1, "valid_mask=%h expected 0 before tick 0", valid_mask);
    expect_sample(0, 16'd0);

    // 2) capture from tick 0, tick 7 is a rest.
    bad = 0;
    for (t = 0; t < K; t = t + 1) tick(t, 16'd100 + t[15:0], (t != 7));
    if (!full) $fatal(1, "full did not assert after %0d samples", K);
    for (t = 0; t < K; t = t + 1) begin
      expect_sample(t, (16'd100 + t[15:0]) >> 6);
      if (valid_mask[t] !== ((t == 7) ? 1'b0 : 1'b1)) begin
        $fatal(1, "valid_mask[%0d]=%b expected %b", t, valid_mask[t], (t == 7) ? 1'b0 : 1'b1);
      end
    end

    // 3) re-arm clears everything and waits for the next tick 0 again.
    pulse_arm();
    if (full) $fatal(1, "re-arm did not clear full");
    if (valid_mask !== {K{1'b0}}) $fatal(1, "re-arm did not clear valid_mask");
    expect_sample(0, 16'd0);
    expect_sample(K - 1, 16'd0);

    // 4) partial capture: only 10 ticks, the rest stay rests at zero.
    for (t = 0; t < 10; t = t + 1) tick(t, 16'd200 + t[15:0], 1'b1);
    if (full) $fatal(1, "full asserted on a partial capture");
    for (t = 0; t < 10; t = t + 1) expect_sample(t, (16'd200 + t[15:0]) >> 6);
    for (t = 10; t < K; t = t + 1) begin
      expect_sample(t, 16'd0);
      if (valid_mask[t] !== 1'b0) $fatal(1, "partial capture set valid_mask[%0d]", t);
    end

    $display("PASS tb_loop_contour_capture K=%0d", K);
    $finish;
  end

  initial begin : timeout
    #200_000;
    $fatal(1, "tb_loop_contour_capture timeout");
  end
endmodule
