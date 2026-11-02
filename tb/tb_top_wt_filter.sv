`timescale 1ns/1ps
// Diagnostic top-level bench: reproduce the board's WT_PLAY + filter + volume
// listening test and measure the numbers instead of guessing.
//
// The board observation under investigation: in MODE = 6 (WT_PLAY), with a
// 1024-point sine in table 0 and THRESHOLDS[7:0] = 72, the tone did not change
// when 0x40 enabled the ladder at ci = 144 and did not change when 0x90 doubled
// the master volume.  This bench plays exactly that table through the real UART
// path and the real audio chain, then measures the peak of dut.i2s_sample:
//
//   A = everything bypassed, volume 1.0        (the baseline peak)
//   B = 0x40 = 0x0100_0090, filter on, ci 144  (must fall well below A/4)
//   C = 0x40 = 0, 0x90 = 0x0002_0000           (must be about 2 x A)
//
// Two deliberate measurement notes:
//
//   1. The requested step 6 writes 0x90 = unity and 0x44 = LFO after step 5
//      wrote 0x40 = 0.  With the filter bypassed the LFO only moves
//      dut.ci_total; it can never reach dut.i2s_sample, so that window must be
//      flat.  The bench measures it anyway as a control, then re-enables the
//      step-4 filter word (0x40 = 0x0100_0090, ci 144) for the real LFO check.
//      Nothing is forced: every value comes from the shipped wiring.
//
//   2. 2000 samples at 48 kHz are 5.3 % of the 1.28 Hz LFO period, and by the
//      time this bench reaches the LFO the triangle sits near its trough, where
//      a 523 Hz tone is below the noise floor.  For the LFO check the bench
//      therefore waits until the rising triangle reaches ci_total >= 165 and
//      then measures 2000 samples, the same length the procedure asks for.
//      The wait is counted in samples and guarded; it is not a change to the
//      RTL or to the register values.
//
// The UART runs at 40 Mbaud (the table upload is 1024 WT_DATA writes and the
// 22-byte replies alone would cost about 18M cycles at the production 1 Mbaud).
// The wavetable, filter and volume paths do not depend on the byte rate.
module tb_top_wt_filter;
  import v2_contract_pkg::*;

  localparam integer N = 1024;
  localparam real    PI = 3.141592653589793;
  localparam real    AMP = 12288.0;              // 0x3000, the requested amplitude

  localparam logic [31:0] THRESHOLDS_WORD = 32'hFFFF_0048;  // note 72 = C5 ~523 Hz
  localparam logic [31:0] WT_SELECT_WORD  = 32'h0000_0020;  // table 0, shift 2
  localparam logic [31:0] FILTER_WORD     = 32'h0100_0090;  // filter on, res 0, ci 144
  localparam logic [31:0] VOLUME_2_WORD   = 32'h0002_0000;  // 2.0
  localparam logic [31:0] VOLUME_1_WORD   = 32'h0001_0000;  // 1.0
  localparam logic [31:0] LFO_WORD        = 32'h0180_0500;  // LFO on, 1280 mHz, depth 128

  localparam integer SETTLE_N    = 400;   // let the four-stage trim chain fill
  localparam integer WINDOW_N    = 400;   // A / B / C window
  localparam integer LFO_N       = 2000;  // requested LFO window
  localparam integer LFO_TARGET  = 165;   // wait for the rising triangle to reach this ci
  localparam integer LFO_GUARD_N = 26000; // one period is 37500 samples; the phase is near 0

  logic clk_50m = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  logic [7:0]  inject_value;
  logic [7:0]  seqn = 8'h50;
  logic [15:0] crc, crc_final;
  integer i, guard;
  integer cur;
  integer peak_a, peak_b, peak_b_ss, peak_c;
  integer lfo1_min, lfo1_max;
  integer lfo2_min, lfo2_max, lfo_ci_min, lfo_ci_max;
  integer f_bad, v_bad, l_bad;
  integer s0, s1, s2, s3, s4, s5, s6, s7;
  integer ci_v, fe_v, raw_v;
  logic [31:0] vol_v, rback;

  logic signed [15:0] sine_tab [0:N-1];

  always #5 clk_50m = ~clk_50m;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(1), .UART_BAUD(40_000_000),
                   .POTTS_HORIZON(32), .V2_DEBUG_CSR(1)) dut (
    .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck), .pcm5102a_din(pcm5102a_din)
  );

  // ------------------------------------------------------------------ helpers
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

  function automatic integer rnd(input real x);
    rnd = (x >= 0.0) ? $rtoi(x + 0.5) : -$rtoi(-x + 0.5);
  endfunction

  task automatic build_sine;
    integer n;
    begin
      for (n = 0; n < N; n = n + 1)
        sine_tab[n] = rnd(AMP * $sin(2.0 * PI * n / N));
    end
  endtask

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

  task automatic inject_control(input [7:0] op, input [7:0] address,
                                input [7:0] seq, input [31:0] data);
    reg [7:0] b [0:10];
    reg [15:0] c;
    integer k;
    begin
      b[0] = 8'ha5; b[1] = 8'h02; b[2] = op; b[3] = address; b[4] = seq;
      b[5] = data[31:24]; b[6] = data[23:16]; b[7] = data[15:8]; b[8] = data[7:0];
      c = 16'hffff;
      for (k = 0; k < 9; k = k + 1) c = crc_byte(c, b[k]);
      b[9] = c[15:8]; b[10] = c[7:0];
      // The link holds one outstanding transaction, and an APPLY replies only
      // after its CRC scan, long after the command was accepted.  Starting the
      // next frame while that reply is still going out drops it.
      guard = 0;
      while ((dut.v2_tx_valid || dut.uart_tx_busy) && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "the previous reply never finished");
      for (k = 0; k < 11; k = k + 1) inject_byte(b[k]);
      repeat (4) @(posedge clk_50m);
      for (k = 0; k < 20000; k = k + 1) begin
        if (!dut.v2_tx_valid && !dut.uart_tx_busy) k = 20000;
        else @(posedge clk_50m);
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy)
        $fatal(1, "V2 UART response did not drain");
      if (dut.rsp_error !== 8'd0)
        $fatal(1, "op=0x%02h addr=0x%02h seq=0x%02h NACKed err=0x%02h",
               op, address, seq, dut.rsp_error);
    end
  endtask

  // Every frame gets a fresh sequence byte: a repeated value is V2_ERR_SEQUENCE.
  task automatic csr_write(input [7:0] address, input [31:0] data);
    begin
      inject_control(8'h02, address, seqn, data);
      seqn = seqn + 8'd1;
    end
  endtask

  task automatic csr_read(input [7:0] address, output [31:0] value);
    begin
      inject_control(8'h01, address, seqn, 32'd0);
      seqn = seqn + 8'd1;
      value = dut.rsp_data;
    end
  endtask

  task automatic upload_sine;
    begin
      // length, index = 0 (this also reloads the upload pointer)
      csr_write(8'h6C, 32'd1024);
      csr_write(8'h64, 32'd0);
      for (i = 0; i < N; i = i + 1)
        csr_write(8'h68, {16'd0, sine_tab[i]});
      crc = 16'hffff;
      for (i = 0; i < N; i = i + 1) begin
        crc = crc_byte(crc, sine_tab[i][15:8]);
        crc = crc_byte(crc, sine_tab[i][7:0]);
      end
      crc_final = crc;
      csr_write(8'h70, {16'd0, crc_final});
      csr_write(8'h74, 32'd0);                       // WT_VERSION
      csr_write(8'h78, 32'h8000_0000);               // APPLY + commit bit
      guard = 0;
      while (!dut.u_wavetable_loader.wt_active_valid && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (!dut.u_wavetable_loader.wt_active_valid)
        $fatal(1, "the sine table never became active (crc=0x%04h reason=%0d)",
               crc_final, dut.u_wavetable_loader.dbg_apply_reject_reason);
    end
  endtask

  // --------------------------------------------------------------- measurement
  // wt_play_valid is one system clock wide, once per sample_ce.  The audio
  // registers and that valid pulse are written on the same edge, so the
  // following negedge sees the pair the I2S transmitter will consume.
  task automatic next_sample;
    integer g;
    begin
      g = 0;
      while (1) begin
        @(negedge dut.clk_sys_100m);
        if (dut.wt_play_valid) begin
          cur = $signed(dut.i2s_sample);
          break;
        end
        g = g + 1;
        if (g > 300000)
          $fatal(1, "no wt_play_valid pulse in WT_PLAY (mode=%0d filter_en=%0d)",
                 dut.mode_reg, dut.filter_en);
      end
    end
  endtask

  task automatic measure_peak(input integer n, output integer peak);
    integer j, v;
    begin
      peak = 0;
      for (j = 0; j < n; j = j + 1) begin
        next_sample;
        v = cur;
        if (v < 0) v = -v;
        if (v > peak) peak = v;
      end
    end
  endtask

  task automatic measure_minmax(input integer n, output integer mn, output integer mx);
    integer j;
    begin
      mn = 32767;
      mx = -32768;
      for (j = 0; j < n; j = j + 1) begin
        next_sample;
        if (cur < mn) mn = cur;
        if (cur > mx) mx = cur;
      end
    end
  endtask

  task automatic measure_lfo(input integer n, output integer mn, output integer mx,
                             output integer cmin, output integer cmax);
    integer j;
    begin
      mn = 32767;
      mx = -32768;
      cmin = 4095;
      cmax = 0;
      for (j = 0; j < n; j = j + 1) begin
        next_sample;
        if (cur < mn) mn = cur;
        if (cur > mx) mx = cur;
        if (dut.ci_total < cmin) cmin = dut.ci_total;
        if (dut.ci_total > cmax) cmax = dut.ci_total;
      end
    end
  endtask

  // The triangle must be rising (phase[31] == 0) and high enough that the 523 Hz
  // tone is inside the ladder's passband.
  task automatic wait_lfo_ci(input integer target);
    integer g;
    begin
      g = 0;
      while (!(dut.u_lfo.phase[31] == 1'b0 && dut.ci_total >= target)) begin
        next_sample;
        g = g + 1;
        if (g > LFO_GUARD_N)
          $fatal(1, "the LFO never reached ci_total=%0d (stuck at %0d, phase=0x%08h)",
                 target, dut.ci_total, dut.u_lfo.phase);
      end
    end
  endtask

  // ------------------------------------------------------------------ the test
  initial begin : run_tb
    repeat (40) @(posedge clk_50m);
    if (!dut.rst_sys_n || !dut.pll_locked) $fatal(1, "reset/PLL did not release");

    build_sine;

    csr_read(8'hB0, rback);
    $display("0xB0 = 0x%08h", rback);
    if (rback !== 32'h5A5A_0003) $fatal(1, "0xB0=0x%08h", rback);

    // ---- boot the WT_PLAY scenario --------------------------------------
    upload_sine;
    $display("sine table 0 applied: 1024 points, amplitude 0x%04h, crc=0x%04h",
             16'h3000, crc_final);

    csr_write(8'h30, THRESHOLDS_WORD);          // THRESHOLDS[7:0] = 72
    csr_write(8'h60, WT_SELECT_WORD);           // table 0, shift 2
    csr_read(8'h60, rback);
    if (rback[7:4] !== 4'd2 || rback[1:0] !== 2'd0)
      $fatal(1, "WT_SELECT readback 0x%08h, expected shift 2 table 0", rback);
    csr_write(8'h04, 32'd6);                    // MODE = WT_PLAY
    if (!dut.mode_wt_play) $fatal(1, "MODE=6 (WT_PLAY) was rejected");
    $display("MODE=6 WT_PLAY, THRESHOLDS[7:0]=%0d (note 72), WT_SELECT=0x%08h",
             dut.thresholds_reg[7:0], rback);

    // ---- step 3: settle, then peak A -----------------------------------
    for (i = 0; i < SETTLE_N; i = i + 1) next_sample;
    measure_peak(WINDOW_N, peak_a);
    $display("A = %0d  peak |i2s_sample|, filter bypassed, volume 1.0 (LFO off)", peak_a);

    // ---- step 4: filter on at ci 144 -----------------------------------
    csr_write(8'h40, FILTER_WORD);
    csr_read(8'h40, rback);
    if (dut.filter_en !== 1'b1 || dut.ci_reg !== 12'd144)
      $fatal(1, "0x40 unpacking wrong: readback 0x%08h filter_en=%0d ci=%0d",
             rback, dut.filter_en, dut.ci_reg);
    measure_peak(WINDOW_N, peak_b);
    $display("B = %0d  peak |i2s_sample|, 0x40=0x%08h filter on ci=144 (readback 0x%08h)",
             peak_b, FILTER_WORD, rback);
    // The 400-sample window that starts on the 0x40 write also contains the
    // ladder's startup transient: the states were tracking at ci = 0 (fc 40 Hz)
    // until the coefficient changed.  A second window after four time constants
    // (fc 320 Hz -> ~24 samples) measures the filter's own attenuation, not the
    // step; both are printed because the board listener hears the same two.
    for (i = 0; i < 200; i = i + 1) next_sample;
    measure_peak(WINDOW_N, peak_b_ss);
    $display("B settled = %0d  peak |i2s_sample| after the filter transient (ci_total=%0d g_r=0x%04h)",
             peak_b_ss, dut.ci_total, dut.u_filter.g_r);

    // ---- step 5: filter off, volume 2.0 --------------------------------
    csr_write(8'h40, 32'd0);
    csr_write(8'h90, VOLUME_2_WORD);
    csr_read(8'h90, rback);
    if (dut.filter_en !== 1'b0 || dut.volume_reg !== VOLUME_2_WORD)
      $fatal(1, "0x40/0x90 unpacking wrong: filter_en=%0d volume=0x%08h",
             dut.filter_en, dut.volume_reg);
    measure_peak(WINDOW_N, peak_c);
    $display("C = %0d  peak |i2s_sample|, 0x40=0 (bypass) 0x90=0x%08h volume 2.0",
             peak_c, dut.volume_reg);

    // ---- step 6: LFO, exactly the requested write order -----------------
    csr_write(8'h90, VOLUME_1_WORD);
    csr_write(8'h44, LFO_WORD);
    $display("LFO on: 0x44=0x%08h (enable, 1280 mHz, depth 128), phase=0x%08h ci_total=%0d filter_en=%0d",
             LFO_WORD, dut.u_lfo.phase, dut.ci_total, dut.filter_en);
    measure_minmax(LFO_N, lfo1_min, lfo1_max);
    $display("LFO window as specified (0x40 still 0, filter bypassed): min=%0d max=%0d swing=%0d  (must be flat: a bypassed ladder cannot reach i2s_sample)",
             lfo1_min, lfo1_max, lfo1_max - lfo1_min);

    // ---- the LFO can only move the level with the ladder selected ------
    // Restore the step-4 word (enable, ci 144) and wait for the rising triangle
    // to reach the middle of its range, where the 523 Hz tone is on the filter's
    // slope.  Same 2000-sample window as the procedure asks for.
    csr_write(8'h40, FILTER_WORD);
    wait_lfo_ci(LFO_TARGET);
    $display("LFO window with 0x40=0x%08h re-asserted: starting at phase=0x%08h ci_total=%0d",
             FILTER_WORD, dut.u_lfo.phase, dut.ci_total);
    measure_lfo(LFO_N, lfo2_min, lfo2_max, lfo_ci_min, lfo_ci_max);
    $display("LFO swing: min=%0d max=%0d swing=%0d over %0d samples, ci_total %0d..%0d",
             lfo2_min, lfo2_max, lfo2_max - lfo2_min, LFO_N, lfo_ci_min, lfo_ci_max);

    // ---- the STOP/STATUS pair the board reported -----------------------
    csr_write(8'h14, 32'd1);                    // STOP
    repeat (8) @(posedge dut.clk_sys_100m);
    csr_read(8'h00, rback);
    $display("STATUS after STOP = 0x%08h (mode=%0d active=%0d fault=%0d)",
             rback, rback[2:0], rback[8], rback[9]);

    // ---- verdict -------------------------------------------------------
    f_bad = !(peak_b < peak_a / 4);
    v_bad = !(peak_c >= (peak_a * 18) / 10 && peak_c <= (peak_a * 22) / 10);
    l_bad = !(lfo2_max - lfo2_min > peak_a / 10 && lfo2_max > lfo2_min);

    if (f_bad || v_bad || l_bad) begin
      next_sample; s0 = cur;
      next_sample; s1 = cur;
      next_sample; s2 = cur;
      next_sample; s3 = cur;
      next_sample; s4 = cur;
      next_sample; s5 = cur;
      next_sample; s6 = cur;
      next_sample; s7 = cur;
      ci_v  = dut.ci_total;
      fe_v  = dut.filter_en;
      vol_v = dut.volume_reg;
      raw_v = $signed(dut.i2s_sample_raw);
      $display("FAIL eight consecutive dut.i2s_sample: %0d %0d %0d %0d %0d %0d %0d %0d",
               s0, s1, s2, s3, s4, s5, s6, s7);
      $display("FAIL internals at that moment: ci_total=%0d filter_en=%0d volume_reg=0x%08h i2s_sample_raw=%0d",
               ci_v, fe_v, vol_v, raw_v);
      $fatal(1, "EXPECTATION BROKEN filter=%0d volume=%0d lfo=%0d: A=%0d B=%0d (need B < A/4=%0d) C=%0d (need about 2*A=%0d) lfo=%0d..%0d (need swing > A/10=%0d); internals ci_total=%0d filter_en=%0d volume_reg=0x%08h i2s_sample_raw=%0d; samples %0d %0d %0d %0d %0d %0d %0d %0d",
             f_bad, v_bad, l_bad, peak_a, peak_b, peak_a / 4, peak_c, peak_a * 2,
             lfo2_min, lfo2_max, peak_a / 10,
             ci_v, fe_v, vol_v, raw_v, s0, s1, s2, s3, s4, s5, s6, s7);
    end

    $display("PASS tb_top_wt_filter: sine A=%0d, filter ci=144 B=%0d (settled %0d, < A/4), volume 2.0 C=%0d (~2A), LFO swing %0d..%0d",
             peak_a, peak_b, peak_b_ss, peak_c, lfo2_min, lfo2_max);
    $finish;
  end

  initial begin : timeout
    #600_000_000;
    $fatal(1, "tb_top_wt_filter timeout (mode=%0d filter_en=%0d ci_total=%0d sample_index=%0d)",
           dut.mode_reg, dut.filter_en, dut.ci_total, dut.sample_index);
  end
endmodule
