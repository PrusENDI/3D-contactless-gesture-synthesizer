`timescale 1ns/1ps
// Unit test for the multi-waveform cutoff LFO (plan task 4).
//
// The six claims of the plan's task 4 step 1, in order: period, depth 0,
// unipolar, waveform shape, retrigger, and that enable=0 zeroes the output
// without stopping the phase.  The phase is read hierarchically (dut.phase) for
// the last claim: the whole point is a register that no output shows while
// enable is low, so only a hierarchical read can prove it still runs.
//
// The time base is sample_ce at 48 kHz.  A step is one sample_ce pulse of one
// clock, and the offset is read after the falling edge on which the phase has
// already moved, so `step` returns the value for the sample it just clocked.
module tb_lfo_triangle;
  localparam int PERIOD_1HZ = 48000;      // rate_mhz = 1000 -> 1 Hz at 48 kHz
  localparam int INC_1HZ    = 89478;      // (1000 * 45813) >> 9

  logic clk = 0, rst_n = 0, sample_ce = 0;
  logic [15:0] rate_mhz = 16'd1000;
  logic [7:0]  depth = 8'd100;
  logic        enable = 1'b1, retrig = 1'b0, trigger = 1'b0, unipolar = 1'b0;
  logic [2:0]  waveform = 3'd0;
  logic signed [12:0] offset_ci;

  int checks = 0;
  int errors = 0;

  v2_lfo_triangle dut(.clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
                      .rate_mhz(rate_mhz), .depth(depth), .enable(enable),
                      .retrig(retrig), .trigger(trigger), .unipolar(unipolar),
                      .waveform(waveform), .offset_ci(offset_ci));

  always #5 clk = ~clk;

  task automatic reset_dut;
    begin
      rst_n = 1'b0; sample_ce = 1'b0; trigger = 1'b0;
      repeat (4) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic idle(input int n);
    int j;
    for (j = 0; j < n; j = j + 1) @(negedge clk);
  endtask

  // One 48 kHz sample; returns the offset the DUT now drives.
  task automatic step(output int v);
    begin
      @(negedge clk); sample_ce = 1'b1;
      @(negedge clk); sample_ce = 1'b0;
      v = offset_ci;
    end
  endtask

  task automatic expect_i(input int got, input int want, input string what);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %0d want %0d", what, got, want);
        errors = errors + 1;
      end else begin
        $display("PASS %0s: %0d", what, got);
      end
    end
  endtask

  task automatic expect_range(input int got, input int lo, input int hi,
                              input string what);
    begin
      checks = checks + 1;
      if (got < lo || got > hi) begin
        $display("FAIL %0s: got %0d want %0d..%0d", what, got, lo, hi);
        errors = errors + 1;
      end else begin
        $display("PASS %0s: %0d in %0d..%0d", what, got, lo, hi);
      end
    end
  endtask

  task automatic expect_true(input logic cond, input string what);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("FAIL %0s", what);
        errors = errors + 1;
      end else begin
        $display("PASS %0s", what);
      end
    end
  endtask

  int k, p, w, v, prev, first, period;
  int nz, lo, hi, nmono, npos, nneg, other, distinct, seen;
  int ph0, ph1, v0, v1, v2;
  int sh [0:2];

  initial begin
    // 1. Period.  1000 mHz is 1 Hz and the phase runs on sample_ce, so one full
    // triangle is 48000 samples +-2%: measured between two upward zero
    // crossings, which happen once per period.
    rate_mhz = 16'd1000; depth = 8'd100; waveform = 3'd0;
    enable = 1'b1; unipolar = 1'b0; retrig = 1'b0; trigger = 1'b0;
    reset_dut();
    first = -1; period = -1; prev = -1;
    for (k = 0; k < 2 * PERIOD_1HZ + 4000; k = k + 1) begin
      step(v);
      if (prev < 0 && v >= 0) begin
        if (first < 0) first = k;
        else if (period < 0) period = k - first;
      end
      prev = v;
    end
    expect_range(period, 47040, 48960,
                 "period at 1000 mHz is 48000 sample_ce within 2 percent");

    // 2. depth = 0 holds the offset at zero for every waveform, whatever the
    // phase does.
    depth = 8'd0; enable = 1'b1; unipolar = 1'b0;
    for (w = 0; w < 5; w = w + 1) begin
      waveform = w[2:0];
      reset_dut();
      nz = 0;
      for (k = 0; k < 500; k = k + 1) begin
        step(v);
        if (v != 0) nz = nz + 1;
      end
      expect_i(nz, 0, $sformatf("depth 0 keeps the offset 0, waveform %0d", w));
    end

    // 3. Unipolar never goes negative and reaches +depth (the deterministic
    // waveforms hit it at their trough; the cubic sine stops one LSB short).
    depth = 8'd200; unipolar = 1'b1; enable = 1'b1;
    for (w = 0; w < 4; w = w + 1) begin
      waveform = w[2:0];
      reset_dut();
      lo = 100000; hi = -100000;
      for (k = 0; k < PERIOD_1HZ + 2000; k = k + 1) begin
        step(v);
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      end
      expect_true(lo >= 0, $sformatf("unipolar never negative, waveform %0d", w));
      expect_range(hi, 198, 200, $sformatf("unipolar peaks at +depth, waveform %0d", w));
    end
    // The sample and hold is random, so it can only be held to the bounds.
    waveform = 3'd4; reset_dut();
    lo = 100000; hi = -100000;
    for (k = 0; k < PERIOD_1HZ * 3; k = k + 1) begin
      step(v);
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    end
    expect_true(lo >= 0, "unipolar sample and hold is never negative");
    expect_range(hi, 1, 200, "unipolar sample and hold stays inside +depth");

    // 4a. Triangle: two straight halves.  Landmarks at 1/8, 1/4, 1/2, 3/4 and
    // one period, plus monotonicity over the rising half.
    depth = 8'd100; unipolar = 1'b0; waveform = 3'd0; enable = 1'b1;
    reset_dut();
    lo = 100000; hi = -100000; nmono = 0; prev = -100;
    for (k = 1; k <= PERIOD_1HZ; k = k + 1) begin
      step(v);
      if (v < lo) lo = v;
      if (v > hi) hi = v;
      if (k <= 23000 && v < prev) nmono = nmono + 1;
      if (k == 6000) expect_range(v, -52, -49, "triangle is half way up at one eighth period");
      if (k == 12000) expect_range(v, -2, 2, "triangle crosses zero at a quarter period");
      if (k == 24000) expect_range(v, 98, 100, "triangle peaks at the half period");
      if (k == 36000) expect_range(v, -2, 2, "triangle crosses zero again at three quarters");
      if (k == 48000) expect_range(v, -100, -99, "triangle is back at the trough after one period");
      prev = v;
    end
    expect_i(nmono, 0, "triangle is monotone over its rising half");
    expect_i(lo, -100, "triangle trough is -depth");
    expect_i(hi, 99, "triangle peak is +depth minus one LSB of the one's complement");

    // 4b. Square: only two values, each for half the period.
    waveform = 3'd3; reset_dut();
    npos = 0; nneg = 0; other = 0;
    for (k = 1; k <= PERIOD_1HZ; k = k + 1) begin
      step(v);
      if (v == 100) npos = npos + 1;
      else if (v == -100) nneg = nneg + 1;
      else other = other + 1;
    end
    expect_i(other, 0, "square only takes +depth and -depth");
    expect_range(npos, 23520, 24480, "square is high for half of the period");
    expect_range(nneg, 23520, 24480, "square is low for half of the period");

    // 4c. Saw: monotone with exactly one wrap of the full swing.
    waveform = 3'd2; reset_dut();
    nneg = 0; other = 0; lo = 100000; hi = -100000; prev = -100000;
    for (k = 1; k <= PERIOD_1HZ; k = k + 1) begin
      step(v);
      if (v < prev) begin
        nneg = nneg + 1;
        if ((prev - v) < 150) other = other + 1;
      end
      if (v < lo) lo = v;
      if (v > hi) hi = v;
      prev = v;
    end
    expect_i(nneg, 1, "saw has exactly one falling step per period");
    expect_i(other, 0, "saw's falling step is the full swing wrap");
    expect_i(lo, -100, "saw trough is -depth");
    expect_i(hi, 99, "saw peak is +depth minus one LSB");

    // 4d. Sine: rises monotonically from -depth, ends its first quarter at
    // zero, is at -0.707 depth at one eighth, peaks at the half period.
    waveform = 3'd1; reset_dut();
    nmono = 0; prev = -100000;
    for (k = 1; k <= 24000; k = k + 1) begin
      step(v);
      if (k > 1 && v < prev) nmono = nmono + 1;
      if (k == 6000) expect_range(v, -73, -69, "sine is at -0.707 depth at one eighth period");
      if (k == 12000) expect_range(v, -2, 2, "sine ends its first quarter at zero");
      prev = v;
    end
    expect_i(nmono, 0, "sine rises monotonically over the first half");
    expect_range(v, 98, 100, "sine peaks at the half period");

    // 4e. Sample and hold: constant inside a period, a new value at the
    // period boundary.
    waveform = 3'd4; reset_dut();
    other = 0;
    nz = depth;                              // int copy: -depth on a bit vector is unsigned
    for (p = 0; p < 3; p = p + 1) begin
      v0 = 0; v1 = 0; v2 = 0;
      for (k = 1; k <= PERIOD_1HZ; k = k + 1) begin
        step(v);
        if (k == 1000) v0 = v;
        if (k == 20000) v1 = v;
        if (k == 46000) v2 = v;
      end
      if (v0 != v1 || v1 != v2) other = other + 1;
      if (v0 < -nz || v0 > nz) other = other + 1;
      sh[p] = v0;
    end
    expect_i(other, 0, "sample and hold is constant inside one period");
    distinct = 0;
    for (p = 0; p < 3; p = p + 1) begin
      seen = 1;
      for (w = 0; w < p; w = w + 1) if (sh[w] == sh[p]) seen = 0;
      distinct = distinct + seen;
    end
    expect_range(distinct, 2, 3, "sample and hold jumps to a new value between periods");

    // 5. Retrigger.  The strobe is one clock wide and deliberately not aligned
    // to sample_ce, because the note-on edge that drives it is not either.
    waveform = 3'd0; depth = 8'd100; unipolar = 1'b0; enable = 1'b1;
    retrig = 1'b1; reset_dut();
    for (k = 0; k < 5000; k = k + 1) step(v);
    idle(2);
    expect_range(offset_ci, -60, -58, "triangle sits off the trough after 5000 samples");
    @(negedge clk); trigger = 1'b1;
    @(negedge clk); trigger = 1'b0;
    expect_i(dut.phase, 0, "retrig=1 and a trigger strobe clear the phase");
    expect_i(offset_ci, -100, "retrig=1 and a trigger strobe put the offset at the trough");
    idle(3);
    expect_i(dut.phase, 0, "the phase stays cleared until the next sample");

    retrig = 1'b0;
    for (k = 0; k < 5000; k = k + 1) step(v);
    ph0 = dut.phase;
    @(negedge clk); trigger = 1'b1;
    @(negedge clk); trigger = 1'b0;
    expect_i(dut.phase, ph0, "retrig=0 ignores the trigger strobe");
    expect_i(dut.phase, 5000 * INC_1HZ, "retrig=0 leaves the phase where it was running");

    // 6. enable=0: the output is 0, the phase still advances by one increment
    // per sample_ce.  This is what keeps the LFO's time base while the filter
    // is bypassed.
    waveform = 3'd0; depth = 8'd100; retrig = 1'b0; enable = 1'b0;
    reset_dut();
    for (k = 0; k < 100; k = k + 1) step(v);
    ph0 = dut.phase;
    nz = 0;
    for (k = 0; k < 1000; k = k + 1) begin
      step(v);
      if (v != 0) nz = nz + 1;
    end
    ph1 = dut.phase;
    expect_i(nz, 0, "enable=0 keeps the output at 0");
    expect_i(ph1, ph0 + 1000 * INC_1HZ, "enable=0 still advances the phase");

    if (errors != 0)
      $fatal(1, "tb_lfo_triangle: %0d of %0d checks failed", errors, checks);
    $display("PASS tb_lfo_triangle: %0d checks over the six claims of task 4", checks);
    $finish;
  end
endmodule
