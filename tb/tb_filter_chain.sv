`timescale 1ns/1ps
// Top-level audio-chain test for P2a (plan 2026-11-01 P2a, Task 6 step 2).
//
// The filter, the LFO and the master volume live in mgc3130_v2_top between the
// four-way audio mux and the I2S transmitter.  This bench instantiates the real
// top, writes the three CSRs through the real UART command path, and injects
// the post-mux sample by forcing i2s_sample_raw, so the four claims are checked
// on the shipped wiring rather than on a copy of it:
//
//   1. bypass is bit-exact: filter_en=0 and volume=0x10000 make i2s_sample
//      identical to i2s_sample_raw for every int16 value (Review Focus 1);
//   2. the LFO phase and the filter state keep advancing on sample_ce while
//      i2s_sample_valid is low for 4800 samples (Review Focus 3, the LIVE-gate
//      case).  In IDLE the valid line is already low for every sample, which is
//      the same situation the LIVE gate creates;
//   3. volume 0x8000 halves and 0x20000 doubles with int16 saturation, so no
//      value wraps;
//   4. with lfo_en=1, depth=64 and rate_mhz=2000 the cutoff index ci_total
//      swings by 128 ci units over one LFO period (+-2).
//
// Time base.  The real sample_ce is a 48 kHz pulse; at the 80 MHz system clock
// one LFO period at 2 Hz would be 24000 pulses x 1667 clocks and the whole
// bench would take minutes.  Nothing under test measures wall time: the filter
// coefficients bake in 48 kHz and the LFO increments per sample_ce, so the
// bench forces sample_ce to a one-clock pulse every CEP clocks (CEP=24, above
// the ladder's documented minimum of 15).  The arithmetic then sees exactly the
// same sample sequence in a fraction of the simulated time.
module tb_filter_chain;
  import v2_contract_pkg::*;

  localparam int CEP          = 24;          // clocks between forced sample_ce pulses
  localparam int LFO_SWING_N  = 24000;       // one period at rate_mhz = 2000
  localparam int GATE_N       = 4800;        // the LIVE-gate window
  localparam int FLUSH_N      = 400;         // let the filter state settle to zero
  localparam int CI_REG       = 192;         // static cutoff index under test
  localparam int LFO_DEPTH    = 64;
  localparam int LFO_RATE     = 2000;
  localparam int RATE_INC     = (LFO_RATE * 45813) >> 9;  // the LFO's Q9 increment
  localparam real FS          = 48000.0;
  localparam real PI          = 3.141592653589793;

  logic clk_50m = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  logic [7:0] inject_value;
  integer i, guard;
  logic [15:0] crc;
  integer seq_counter = 0;
  logic [7:0] last_seq;

  logic [7:0] reply [0:21];
  integer reply_len = 0;

  int checks = 0;
  int errors = 0;
  logic [15:0] drive_word = 16'd0;

  always #5 clk_50m = ~clk_50m;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(1), .UART_BAUD(40_000_000),
                   .POTTS_HORIZON(32), .V2_DEBUG_CSR(1),
                   .FX_ENABLE(0), .FX_LEVEL(0)) dut (
    .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck), .pcm5102a_din(pcm5102a_din)
  );

  always @(posedge clk_50m) begin
    if (dut.v2_tx_valid && dut.v2_tx_ready) begin
      if (reply_len < 22) reply[reply_len] = dut.v2_tx_byte;
      reply_len = reply_len + 1;
    end
  end

  // ---------------------------------------------------------------- UART path
  function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
    reg [15:0] c;
    integer b;
    begin
      c = crc_in ^ {value, 8'h00};
      for (b = 0; b < 8; b = b + 1)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc_byte = c;
    end
  endfunction

  function automatic [31:0] reply_word;
    reply_word = {reply[14], reply[15], reply[16], reply[17]};
  endfunction

  task automatic inject_byte(input [7:0] value);
    begin
      inject_value = value;
      force dut.uart_byte = inject_value;
      force dut.uart_byte_valid = 1'b1;
      @(posedge clk_50m);
      #1;
      force dut.uart_byte_valid = 1'b0;
      @(posedge clk_50m);
      #1;
      release dut.uart_byte_valid;
      release dut.uart_byte;
    end
  endtask

  task automatic send_frame(input [7:0] op, input [7:0] address, input [31:0] data);
    reg [7:0] b [0:10];
    reg [15:0] c;
    integer k;
    begin
      last_seq = seq_counter[7:0];
      seq_counter = seq_counter + 1;
      b[0] = 8'ha5; b[1] = 8'h02; b[2] = op; b[3] = address; b[4] = last_seq;
      b[5] = data[31:24]; b[6] = data[23:16]; b[7] = data[15:8]; b[8] = data[7:0];
      c = 16'hffff;
      for (k = 0; k < 9; k = k + 1) c = crc_byte(c, b[k]);
      b[9] = c[15:8]; b[10] = c[7:0];
      guard = 0;
      while ((dut.v2_tx_valid || dut.uart_tx_busy) && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "the previous reply never finished");
      reply_len = 0;
      for (k = 0; k < 11; k = k + 1) inject_byte(b[k]);
      guard = 0;
      while (reply_len < 22 && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (reply_len != 22) $fatal(1, "no 22-byte reply for op=0x%02h addr=0x%02h", op, address);
      guard = 0;
      while ((dut.v2_tx_valid || dut.uart_tx_busy) && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy) $fatal(1, "V2 UART response did not drain");
      repeat (2) @(posedge clk_50m);
    end
  endtask

  task automatic write_csr(input [7:0] address, input [31:0] data, input string what);
    begin
      send_frame(V2_OP_WRITE, address, data);
      if (reply[2] !== V2_TLM_ACK || reply[19] !== V2_ERR_NONE)
        $fatal(1, "%s: write NACKed type=0x%02h err=0x%02h", what, reply[2], reply[19]);
      $display("PASS %s accepted", what);
    end
  endtask

  task automatic read_csr(input [7:0] address, output [31:0] value, input string what);
    begin
      send_frame(V2_OP_READ, address, 32'd0);
      if (reply[2] !== V2_TLM_ACK || reply[19] !== V2_ERR_NONE)
        $fatal(1, "%s: read NACKed type=0x%02h err=0x%02h", what, reply[2], reply[19]);
      value = reply_word();
    end
  endtask

  // ------------------------------------------------------------- chain driving
  // One forced 48 kHz tick: sample_ce high for exactly one system clock, then
  // low for CEP-1 clocks, so consecutive ticks are CEP clocks apart.
  task automatic tick;
    begin
      force dut.sample_ce = 1'b1;
      @(negedge dut.clk_sys_100m);
      force dut.sample_ce = 1'b0;
      repeat (CEP - 1) @(negedge dut.clk_sys_100m);
    end
  endtask

  task automatic drive_raw(input int value);
    begin
      drive_word = value;
      force dut.i2s_sample_raw = drive_word[15:0];
    end
  endtask

  function automatic int out_now;
    out_now = $signed(dut.i2s_sample);
  endfunction

  function automatic int absi(input int x);
    absi = (x < 0) ? -x : x;
  endfunction

  function automatic int sat16(input int x);
    sat16 = (x > 32767) ? 32767 : (x < -32768) ? -32768 : x;
  endfunction

  function automatic int rnd(input real x);
    rnd = (x >= 0.0) ? $rtoi(x + 0.5) : -$rtoi(-x + 0.5);
  endfunction

  function automatic int lfo_phase_now;
    lfo_phase_now = dut.u_lfo.phase;
  endfunction

  function automatic int filter_w1_now;
    filter_w1_now = $signed(dut.u_filter.w1);
  endfunction

  // --------------------------------------------------------------- assertions
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

  task automatic expect_near_i(input int got, input int want, input int tol, input string what);
    begin
      checks = checks + 1;
      if (got < want - tol || got > want + tol) begin
        $display("FAIL %0s: got %0d want %0d +-%0d", what, got, want, tol);
        errors = errors + 1;
      end else begin
        $display("PASS %0s: %0d (want %0d +-%0d)", what, got, want, tol);
      end
    end
  endtask

  // ------------------------------------------------------------- test vectors
  int test_values [0:11];
  int ci_min, ci_max, ci_swing;
  int phase0, phase1, w1_0, w1_1, want_phase;
  int peak, valid_low;
  longint phase_sum;
  logic [31:0] ctrl_word;

  initial begin
    repeat (40) @(posedge clk_50m);
    if (!dut.rst_sys_n || !dut.pll_locked) $fatal(1, "reset/PLL did not release");

    // Read-path self test: if the reply decoder were wrong every later result
    // is the bench's fault, not the DUT's.
    read_csr(8'hB0, ctrl_word, "read path self test (0xB0 constant)");
    if (ctrl_word !== 32'h5A5A_0003) $fatal(1, "0xB0=0x%08h", ctrl_word);
    $display("PASS read path self test (0xB0 constant)");

    // Take the 48 kHz cadence over: the scheduler keeps counting, but the
    // audio chain now ticks only when the bench says so.
    force dut.sample_ce = 1'b0;
    drive_raw(0);

    // ---- 1. bypass is bit-exact ------------------------------------------
    write_csr(V2_CSR_FILTER, 32'h0000_0000, "0x40 = 0 (filter bypass)");
    write_csr(V2_CSR_LFO,    32'h0000_0000, "0x44 = 0 (LFO off)");
    write_csr(V2_CSR_VOLUME, 32'h0001_0000, "0x90 = unity");
    if (dut.filter_en !== 1'b0 || dut.ci_reg !== 12'd0) $fatal(1, "0x40 unpacking wrong");
    test_values[0] = 0;
    test_values[1] = 1;
    test_values[2] = -1;
    test_values[3] = 32767;
    test_values[4] = -32768;
    test_values[5] = 12345;
    test_values[6] = -12345;
    test_values[7] = 255;
    test_values[8] = -256;
    test_values[9] = 16384;
    test_values[10] = -16384;
    test_values[11] = 7;
    for (i = 0; i < 12; i = i + 1) begin
      drive_raw(test_values[i]);
      #1;
      expect_i(out_now(), test_values[i], "bypass is bit-exact with volume 0x10000");
    end

    // The filter must keep running even while it is bypassed: with filter_en=0
    // the ladder still sees i2s_sample_raw on every sample_ce and its state
    // moves (spec 5.6: bypass is only an output mux).
    write_csr(V2_CSR_FILTER, 32'h0000_00C0, "0x40 = ci 192, filter still bypassed");
    drive_raw(20000);
    for (i = 0; i < 100; i = i + 1) tick;
    expect_range_i(absi(filter_w1_now()), 1000, 20000000,
                   "the bypassed filter still advances its state");
    expect_i(out_now(), 20000, "the bypassed output is still the raw sample");

    // ---- 2. volume --------------------------------------------------------
    write_csr(V2_CSR_VOLUME, 32'h0000_8000, "0x90 = 0x8000 (half)");
    if (dut.volume_reg !== 32'h0000_8000) $fatal(1, "0x90 unpacking wrong");
    for (i = 0; i < 12; i = i + 1) begin
      drive_raw(test_values[i]);
      #1;
      expect_near_i(out_now(), ($signed(test_values[i]) * 32768) >>> 16, 1,
                    "volume 0x8000 halves without wrapping");
    end
    write_csr(V2_CSR_VOLUME, 32'h0002_0000, "0x90 = 0x20000 (double)");
    for (i = 0; i < 12; i = i + 1) begin
      drive_raw(test_values[i]);
      #1;
      expect_i(out_now(), sat16(2 * test_values[i]),
               "volume 0x20000 doubles and saturates without wrapping");
    end
    write_csr(V2_CSR_VOLUME, 32'h0001_0000, "0x90 = unity again");

    // ---- 3. the LFO swings the cutoff index ------------------------------
    write_csr(V2_CSR_FILTER, 32'h0100_00C0, "0x40 = enable, ci 192");
    write_csr(V2_CSR_LFO,    32'h0140_07D0, "0x44 = enable, depth 64, 2000 mHz");
    if (dut.filter_en !== 1'b1 || dut.ci_reg !== 12'd192 ||
        dut.lfo_en !== 1'b1 || dut.lfo_depth !== 8'd64 ||
        dut.lfo_rate_mhz !== 16'd2000 || dut.lfo_retrig !== 1'b0 ||
        dut.lfo_unipolar !== 1'b0 || dut.lfo_wave !== 3'd0)
      $fatal(1, "0x40/0x44 unpacking wrong");
    drive_raw(0);
    ci_min = 4095; ci_max = 0;
    // the value before any tick, then one full LFO period of values
    if (dut.ci_total < ci_min) ci_min = dut.ci_total;
    if (dut.ci_total > ci_max) ci_max = dut.ci_total;
    for (i = 0; i < LFO_SWING_N; i = i + 1) begin
      tick;
      if (dut.ci_total < ci_min) ci_min = dut.ci_total;
      if (dut.ci_total > ci_max) ci_max = dut.ci_total;
    end
    ci_swing = ci_max - ci_min;
    expect_i(ci_min, CI_REG - LFO_DEPTH, "the LFO trough is ci - depth");
    expect_i(ci_max, CI_REG + LFO_DEPTH - 1, "the LFO peak is ci + depth - 1 (truncated)");
    expect_near_i(ci_swing, 128, 2, "the cutoff index swings by 128 ci units");

    // ---- 4. the LIVE-gate case: valid low for 4800 samples ---------------
    // The output already equals the ladder output (filter_en=1, volume=1).
    drive_raw(0);
    for (i = 0; i < FLUSH_N; i = i + 1) tick;
    phase0 = lfo_phase_now();
    w1_0 = filter_w1_now();
    valid_low = 1;
    peak = 0;
    for (i = 0; i < GATE_N; i = i + 1) begin
      drive_raw(rnd(20000.0 * $sin(2.0 * PI * 500.0 * i / FS)));
      tick;
      if (dut.i2s_sample_valid !== 1'b0) valid_low = 0;
      if (i >= GATE_N - 500 && absi(out_now()) > peak) peak = absi(out_now());
    end
    phase1 = lfo_phase_now();
    w1_1 = filter_w1_now();
    expect_i(valid_low, 1, "i2s_sample_valid stayed low for the whole window");
    // phase advanced by exactly GATE_N increments, modulo 2^32
    phase_sum = {32'd0, phase0} + GATE_N * RATE_INC;
    want_phase = phase_sum[31:0];
    if (phase1 !== want_phase)
      $display("FAIL the LFO phase advanced by 4800 samples: got 0x%08h want 0x%08h",
               phase1, want_phase);
    else
      $display("PASS the LFO phase advanced by 4800 samples: 0x%08h", phase1);
    checks = checks + 1;
    if (phase1 !== want_phase) errors = errors + 1;
    checks = checks + 1;
    if (!(absi(w1_1) > 1000) || w1_1 == w1_0) begin
      $display("FAIL the filter state did not advance with valid low: w1 %0d -> %0d", w1_0, w1_1);
      errors = errors + 1;
    end else begin
      $display("PASS the filter state advanced with valid low: w1 %0d -> %0d", w1_0, w1_1);
    end
    expect_range_i(peak, 5000, 9500, "a 500 Hz tone is filtered (not passed through)");
    checks = checks + 1;
    if ($signed(dut.i2s_sample) !== $signed(dut.u_filter.audio_out)) begin
      $display("FAIL filter_en=1 did not select the ladder output");
      errors = errors + 1;
    end else begin
      $display("PASS filter_en=1 selects the ladder output");
    end

    release dut.i2s_sample_raw;
    release dut.sample_ce;

    if (errors != 0)
      $fatal(1, "tb_filter_chain: %0d of %0d checks failed", errors, checks);
    $display("PASS tb_filter_chain: %0d checks on bypass, volume, LFO swing and the LIVE gate",
             checks);
    $finish;
  end

  initial begin : timeout
    #50_000_000;
    $fatal(1, "tb_filter_chain timeout (mode=%0d)", dut.mode_reg);
  end

endmodule
