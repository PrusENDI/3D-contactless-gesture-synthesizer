`timescale 1ns/1ps
// Rests shorter than MIN_LENGTH make the Potts DP unsatisfiable: it forbids a
// segment that mixes rest and data, and every non-initial segment must be at
// least MIN_LENGTH long, so a two-tick rest leaves dp[K] at infinity and the
// backtrace publishes whatever the untouched backpointer holds.
//
// The purifier rewrites every short run into the previous run, so all segments
// except the first are at least MIN_LENGTH long and the DP always has a path.
module tb_loop_rest_purify;
  localparam integer K = 32;

  logic clk = 0, rst_n = 0, start = 0;
  logic [K-1:0] raw_valid = 0;
  logic [K-1:0] purified_valid;
  logic busy, done;

  always #5 clk = ~clk;

  v2_loop_rest_purify #(.K(K)) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .raw_valid(raw_valid), .purified_valid(purified_valid),
    .busy(busy), .done(done));

  task automatic run_case(input [31:0] raw, input [31:0] expected, input [127:0] name);
    integer cycles;
    begin
      @(negedge clk);
      raw_valid = raw[K-1:0];
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      cycles = 0;
      while (!done && cycles < 500) begin
        @(posedge clk);
        #1;
        cycles = cycles + 1;
      end
      if (!done) $fatal(1, "%0s: purifier never finished", name);
      if (purified_valid !== expected[K-1:0])
        $fatal(1, "%0s: purified=%h expected %h", name, purified_valid, expected[K-1:0]);
      @(negedge clk);
    end
  endtask

  initial begin : run_tb
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    run_case(32'hFFFFFFFF, 32'hFFFFFFFF, "all data");
    run_case(32'h00000000, 32'h00000000, "all rest");
    // 16 data, 2 rest, 14 data: the two rest ticks are absorbed.
    run_case(32'hFFFCFFFF, 32'hFFFFFFFF, "two-tick rest");
    // 16 data, 5 rest, 11 data: five ticks is a real rest and stays.
    run_case(32'hFFE0FFFF, 32'hFFE0FFFF, "five-tick rest");
    // 0..11 data, 12..15 rest (exactly MIN_LENGTH), 16..31 data: kept.
    run_case(32'hFFFF0FFF, 32'hFFFF0FFF, "rest of exactly four");
    // First run short is legal for the DP, so it must survive untouched.
    run_case(32'hFFFFFFFC, 32'hFFFFFFFC, "short first run");
    // 8 data, 2 rest, 2 data, 20 rest: both short runs collapse into the data
    // run, the long rest stays.  A single pass over the raw mask would leave
    // the second short run standing, which is what this case catches.
    run_case(32'h00000CFF, 32'h00000FFF, "two short runs in a row");

    $display("PASS tb_loop_rest_purify K=%0d", K);
    $finish;
  end

  initial begin : timeout
    #200_000;
    $fatal(1, "tb_loop_rest_purify timeout");
  end
endmodule
