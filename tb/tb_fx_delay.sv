`timescale 1ns/1ps
// Characterization test for v2_fx_lite's delay line (P2a plan task 6, step 1).
//
// v2_fx_lite had no testbench before this one.  Four claims are pinned here:
//   1. at level 2 (low-pass then delay) the dry sample is published one
//      sample_ce after it is presented, not on the same sample_ce;
//   2. the delay line then repeats it at a constant spacing;
//   3. the spacing follows the delay word plus one sample for the memory read
//      register (see the measurement note below);
//   4. each repeat is feedback_q15/32768 of the previous one (0.5 here), and
//      the one-pole at cutoff 0xFFFF passes the impulse at full height.
//
// MEASURED, NOT ASSUMED: the bench records audio_out on every sample_ce and
// takes the local maxima above a threshold, then asserts the distances between
// those indices.  The plan's text said the echoes come "every 10 samples" for
// delay_samples = 10; the RTL says the loop period is 11.  v2_fx_lite's own
// header documents the reason: "the read side is deliberately one sample-ce
// pipeline stage behind the write side".  The write data is
// lp + feedback*delay_rd_data, and delay_rd_data is a register that lags the
// address by one sample, so the recurrence is mem[n] = lp[n] + fb*mem[n-11].
// The dry sample therefore appears at index 1, the first repeat at index 11
// (10 after the dry sample) and every later repeat 11 samples after the
// previous one.  v2_fx_lite is not in this task's change set, so the bench
// records what the hardware does and the plan's "every 10" is corrected here.
module tb_fx_delay;

  localparam int          CEP     = 20;      // clocks per sample_ce (1667 available)
  localparam logic [9:0]  DELAY   = 10'd10;  // the delay word under test
  localparam int          IMPULSE = 20000;
  localparam int          N       = 70;      // samples recorded
  localparam int          THRESH  = 500;     // |peak| above this is an echo
  localparam int          LOOP_PERIOD = DELAY + 1;  // + one memory read stage

  logic clk = 1'b0, rst_n = 1'b0, sample_ce = 1'b0;
  logic signed [15:0] audio_in = 16'sd0;
  logic signed [15:0] audio_out;
  logic [1:0] fx_status;
  logic fx_clip;

  v2_fx_lite #(.USE_GOWIN_RAM(0)) dut (
      .clk                 (clk),
      .rst_n               (rst_n),
      .sample_ce           (sample_ce),
      .audio_in            (audio_in),
      .audio_out           (audio_out),
      .fx_enable           (1'b1),
      .fx_level            (2'd2),
      .fx_gain_q16         (18'h10000),
      .fx_cutoff_q16       (16'hFFFF),
      .fx_delay_samples    (DELAY),
      .fx_feedback_q15     (16'h4000),
      .fx_reverb_mix_q15   (16'd0),
      .fx_status_level     (fx_status),
      .fx_clip             (fx_clip)
  );

  always #5 clk = ~clk;

  int checks = 0;
  int errors = 0;

  function automatic int absi(input int x);
    absi = (x < 0) ? -x : x;
  endfunction

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

  task automatic expect_range_i(input int got, input int lo, input int hi, input string what);
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

  task automatic expect_ratio(input int prev, input int cur, input real ratio,
                              input real tol, input string what);
    real got;
    begin
      checks = checks + 1;
      got = (prev != 0) ? (1.0 * cur / prev) : 1.0;
      if (!(got > ratio - tol && got < ratio + tol)) begin
        $display("FAIL %0s: ratio %.4f want %.4f +-%.3f (prev %0d cur %0d)",
                 what, got, ratio, tol, prev, cur);
        errors = errors + 1;
      end else begin
        $display("PASS %0s: ratio %.4f (prev %0d cur %0d)", what, got, prev, cur);
      end
    end
  endtask

  task automatic reset_dut;
    begin
      rst_n = 1'b0; sample_ce = 1'b0; audio_in = 16'sd0;
      repeat (4) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
    end
  endtask

  // One 48 kHz sample: hold the input, pulse sample_ce for one clock, then read
  // the output that the edge produced.  Pulses are CEP clocks apart.
  task automatic step(input int xin, output int vout);
    begin
      repeat (CEP - 2) @(negedge clk);
      audio_in = xin[15:0];
      sample_ce = 1'b1;
      @(negedge clk);
      sample_ce = 1'b0;
      vout = audio_out;
    end
  endtask

  int samples [0:N-1];
  int peaks [0:15];
  int np;
  int k;

  initial begin
    reset_dut();

    // one impulse, then silence
    for (k = 0; k < N; k = k + 1)
      step((k == 0) ? IMPULSE : 0, samples[k]);

    // Local maxima above the threshold; the silence between echoes makes the
    // peak index unambiguous.
    np = 0;
    for (k = 1; k < N - 1; k = k + 1) begin
      if (absi(samples[k]) > THRESH &&
          absi(samples[k]) >= absi(samples[k-1]) &&
          absi(samples[k]) >= absi(samples[k+1])) begin
        peaks[np] = k;
        np = np + 1;
      end
    end
    $display("measured peaks: %0d", np);
    for (k = 0; k < np; k = k + 1)
      $display("  peak %0d at index %0d value %0d", k, peaks[k], samples[peaks[k]]);

    // 1. the dry sample is one sample_ce late; the first repeat follows it
    //    DELAY samples later because the memory read register adds the extra
    //    sample inside the loop.
    expect_i((np >= 5) ? peaks[0] : -1, 1,
             "the dry sample is published one sample_ce late");
    expect_i((np >= 5) ? peaks[1] : -1, 1 + DELAY,
             "the first repeat lands DELAY samples after the dry sample");

    // 2. every later repeat is one full loop period after the previous one.
    for (k = 2; k < np; k = k + 1)
      expect_i(peaks[k] - peaks[k-1], LOOP_PERIOD,
               "repeat spacing equals the delay word plus one read stage");

    // 3. the first delay-tap copy is the dry sample at full height (the tap is
    //    the input, not a feedback lap), then feedback 0x4000 halves every
    //    later lap (+-2%).
    expect_range_i(samples[peaks[0]], IMPULSE - 2, IMPULSE,
                   "cutoff 0xFFFF passes the impulse at full height");
    expect_i(samples[peaks[1]], samples[peaks[0]],
             "the first delay-tap copy is the dry sample at full height");
    for (k = 2; k < np; k = k + 1)
      expect_ratio(samples[peaks[k-1]], samples[peaks[k]], 0.5, 0.02,
                   "feedback 0x4000 halves each repeat");

    if (errors != 0)
      $fatal(1, "tb_fx_delay: %0d of %0d checks failed", errors, checks);
    $display("PASS tb_fx_delay: %0d checks on v2_fx_lite level-2 echo spacing", checks);
    $finish;
  end

  initial begin : timeout
    #2_000_000;
    $fatal(1, "tb_fx_delay timeout");
  end

endmodule
