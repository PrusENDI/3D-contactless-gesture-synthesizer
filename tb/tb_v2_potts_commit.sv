`timescale 1ns/1ps
// Ported from mgc3130_uart/sim/tb_v2_potts_commit.sv (unchanged assertions).
//
// Portable HORIZON=128 profile: the dp table lives in registers, so this bench
// needs no DPB model.  It proves three things about the commit FSM on its own:
// the DP terminates, it emits at least two events for a two-step contour, and
// the held event stays stable while the consumer stalls.
module tb_v2_potts_commit;
  logic clk = 0, rst_n = 0, start = 0, abort = 0, ready = 1;
  logic busy, done, overflow, bt, ev;
  logic [15:0] lam = 16'd0;
  logic [127:0] rest = 128'd0;
  logic signed [15:0] c [0:127];
  logic [7:0] prog;
  logic [95:0] data;
  logic [5:0] count;
  integer i, n = 0, cycles = 0;

  always #5 clk = ~clk;
  always @(posedge clk) if (rst_n && busy) cycles = cycles + 1;

  v2_potts_commit_fsm dut (
    .clk(clk), .rst_n(rst_n),  .abort(abort), .start(start), .lambda_q16(lam), .rest_mask(rest),
    .contour(c), .busy(busy), .progress(prog), .done(done), .overflow(overflow),
    .backtrace_valid(bt), .event_valid(ev), .event_ready(ready),
    .event_data(data), .event_count(count));

  initial begin : run
    logic [95:0] held;
    // y-space levels: 135 is note 57, 978 is the top note 67 (G4).
    for (i = 0; i < 128; i = i + 1) c[i] = (i < 64) ? 135 : 978;
    repeat (2) @(posedge clk);
    rst_n = 1;

    // Abort must return a running DP to idle: the board hung with the DP busy
    // and STOP/RESET could not release it.
    @(negedge clk);
    start = 1;
    @(posedge clk);
    #1;
    start = 0;
    repeat (20) @(posedge clk);
    #1;
    if (!busy) $fatal(1, "DP did not start for the abort case");
    @(negedge clk);
    abort = 1'b1;
    @(negedge clk);
    abort = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    if (busy) $fatal(1, "abort did not release a busy DP");
    if (ev) $fatal(1, "abort left an event asserted");

    @(negedge clk);
    start = 1;
    @(posedge clk);
    #1;
    start = 0;
    wait (bt);
    ready = 0;
    @(posedge clk);
    #1;
    if (!ev) $fatal(1, "missing held event");
    held = data;
    repeat (3) begin
      @(posedge clk);
      #1;
      if (data !== held) $fatal(1, "event data changed under stall");
    end
    ready = 1;
    while (busy) begin
      @(posedge clk);
      if (ev && ready) n = n + 1;
    end
    if (n < 2 || overflow) $fatal(1, "potts events=%0d overflow=%b", n, overflow);
    $display("PASS tb_v2_potts_commit events=%0d cycles=%0d", n, cycles);
    $finish;
  end
endmodule
