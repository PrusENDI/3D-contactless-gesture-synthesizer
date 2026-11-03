`timescale 1ns/1ps
// Ported from mgc3130_uart/.worktrees/v2-integration/sim/tb_v2_potts_commit_fsm.sv
// (assertions unchanged; only the PASS line moved to the front).
//
// Board-profile (HORIZON=32) Potts regression.
//
// The portable HORIZON=128 run keeps the dp table in registers.  This bench
// drives the same module at HORIZON=32, the only profile where the dp table is
// mapped to explicit DPB lanes, so the board build's storage path is simulated.
module tb_v2_potts_commit_fsm;
  logic clk = 0, rst_n = 0, start = 0, ready = 1;
  logic busy, done, overflow, bt, ev;
  logic [15:0] lam = 16'd0;
  logic [127:0] rest = 128'd0;
  logic signed [15:0] c [0:127];
  logic [7:0] prog;
  logic [95:0] data;
  logic [5:0] count;
  integer i, n = 0, cycles = 0;
  integer tick0, dur0, note0, tick1, dur1, note1;

  always #5 clk = ~clk;
  always @(posedge clk) if (rst_n && busy) cycles = cycles + 1;

  // GW5A DPB (used at HORIZON<=63) needs the global set/reset model.
  GSR GSR(.GSRI(1'b1));

  v2_potts_commit_fsm #(.HORIZON(32)) dut (
    .clk(clk), .rst_n(rst_n), .abort(1'b0), .start(start), .lambda_q16(lam), .rest_mask(rest),
    .contour(c), .busy(busy), .progress(prog), .done(done), .overflow(overflow),
    .backtrace_valid(bt), .event_valid(ev), .event_ready(ready),
    .event_data(data), .event_count(count));

  task automatic take_event(output integer tk, output integer du, output integer nt);
    begin
      tk = data[87:80];
      du = data[79:72];
      nt = data[71:64];
    end
  endtask

  initial begin : run
    // Two constant runs in the SAME units the capture produces (cursor_y>>6):
    // level 30 is note 55, level 978 is the top note 67 (G4) in the
    // G-natural-minor scale.  Beyond the horizon: rest.
    for (i = 0; i < 128; i = i + 1) c[i] = (i < 8) ? 30 : ((i < 32) ? 978 : 0);
    repeat (2) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    start = 1;
    @(posedge clk);
    #1;
    start = 0;
    wait (bt);
    if (!bt || overflow) $fatal(1, "H32 potts result invalid bt=%b overflow=%b", bt, overflow);
    while (busy) begin
      @(posedge clk);
      if (ev && ready) begin
        if (n == 0) take_event(tick0, dur0, note0);
        if (n == 1) take_event(tick1, dur1, note1);
        n = n + 1;
      end
    end
    $display("H32 events n=%0d count=%0d ev0=t%0d/d%0d/n%0d ev1=t%0d/d%0d/n%0d",
             n, count, tick0, dur0, note0, tick1, dur1, note1);
    // lambda_q16=0: the two constant runs have zero error, so the DP must split
    // them instead of paying for one mixed segment.  The backtrace publishes the
    // last segment first, so the expected stream is (t8,d24,n67),(t0,d8,n55).
    if (n != 2) $fatal(1, "H32 potts events=%0d expected 2", n);
    if (count != 2) $fatal(1, "H32 potts event_count=%0d expected 2", count);
    if (tick0 != 8 || dur0 != 24 || note0 != 67)
      $fatal(1, "H32 potts event0 t%0d/d%0d/n%0d expected t8/d24/n67", tick0, dur0, note0);
    if (tick1 != 0 || dur1 != 8 || note1 != 55)
      $fatal(1, "H32 potts event1 t%0d/d%0d/n%0d expected t0/d8/n55", tick1, dur1, note1);
    $display("PASS tb_v2_potts_commit_fsm events=%0d cycles=%0d ev0=t%0d/d%0d/n%0d ev1=t%0d/d%0d/n%0d",
             n, cycles, tick0, dur0, note0, tick1, dur1, note1);
    $finish;
  end

  initial begin : timeout
    #2_000_000;
    $fatal(1, "H32 potts timeout busy=%b state=%0d progress=%0d", busy, dut.state, prog);
  end
endmodule
