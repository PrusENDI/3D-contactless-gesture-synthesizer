`timescale 1ns/1ps
// The production LIVE path, end to end: 32-voice engine -> u_fx_lite -> I2S.
//
// Before this change LIVE was audible from u_wt_playback times an ad-hoc
// envelope, so neither the P2b voice parameters nor the 0x84/0x88/0x8C effects
// could reach the output.  LIVE now muxes u_voice's mixed_sample through
// u_fx_lite (the same -12 dB trim PLAY uses) and reads the wavetable instead of
// the saw.  This bench proves that on the production top, with a hand injected
// at the cursor filter's output and every table written through the real UART
// uploader:
//
//   (a) i2s_sample is exactly the registered trim of the FX output, and that
//       output is non-zero: LIVE is the engine through the FX chain;
//   (b) the P2b ADSR shapes LIVE: sustain 0 with a fast decay reaches silence
//       while the hand and the voice are still there, and a slow attack swells;
//   (c) arp mode still makes sound on every step (a level floor per step);
//   (d) two very different tables (sine, then a pure 5th harmonic) produce
//       clearly different shapes at the same level, so the wavetable really is
//       in the engine's path;
//   (e) the board's FX reset words (0x84 = 0x0015_0000) leave LIVE within a few
//       percent of the FX's level-0 bypass, i.e. the default instrument does
//       not change;
//   (f) 0x84 level 2 + 0x88 delay + 0x8C feedback audibly change LIVE.
//
// FX_ENABLE=1/FX_LEVEL=1 mirror the board build, so the reset value of 0x84 is
// 0x0015_0000 (enable, level 1, unity gain) exactly as on hardware.
//
// cursor_velocity and cursor_depth are forced at the cursor-filter boundary:
// with no MGC reader their natural value is 0, which would mute the P2b
// velocity depth and leave the engine's two oscillators in perfect anti-phase
// (a table sine would cancel itself).  Depth 0xC000 gives mix_a = 0xC0 and
// mix_b = 0x00, one strong and one weak oscillator, which is a legal timbre and
// makes the level measurement stable.
//
// Sample alignment: rows are taken mid-cycle after the sample_ce edge, so
// i2s_sample_raw was registered from the previous row's fx_sample; therefore
// samp[k] == fx[k-1] >>> 2 exactly.
module tb_live_engine;
  localparam integer SINE_AMP   = 12288;   // 0x3000, same table level as the other LIVE benches
  localparam integer CAP        = 16000;
  localparam integer STEP_LIMIT = 80;

  logic clk = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  logic [1:0]         tb_cursor_state = 2'd0;
  logic signed [31:0] tb_cursor_x = 32'sd20000;
  logic signed [31:0] tb_cursor_y = 32'sd3000;     // map_note -> 55 (G3)
  logic signed [31:0] tb_cursor_z = 32'sd30000;
  logic [15:0]        tb_cursor_velocity = 16'h00ff;
  logic [15:0]        tb_cursor_depth    = 16'hC000;
  logic               tb_frame_done = 1'b0;
  logic               tb_tick_pulse = 1'b0;

  integer i, k, guard, n = 0, mark = 0;
  integer mark_a, mark_e1, mark_e2, mark_f, mark_b1, mark_b2, mark_c;
  integer mark_sine, mark_harm, mark_g;
  integer xings_sine, xings_harm, peak_sine, peak_harm;
  integer early_peak, late_peak, tail_peak, step_peak, track_bad;
  integer sum_reset, sum_bypass, sum_fx;
  integer act_pulses, act0, rev0;

  logic signed [15:0] samp  [0:CAP-1];
  logic signed [15:0] fx    [0:CAP-1];
  logic signed [15:0] voice [0:CAP-1];
  logic               hit   [0:CAP-1];
  logic ce_q = 1'b0, act_armed = 1'b0;

  logic [7:0] inject_value;
  logic [15:0] crc;
  logic signed [15:0] tbl_tmp;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(0), .UART_BAUD(40_000_000),
                   .V2_DEBUG_CSR(1), .FX_ENABLE(1), .FX_LEVEL(1)) dut (
    .clk_50m(clk), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck),
    .pcm5102a_din(pcm5102a_din)
  );

  // One row per 48 kHz sample while LIVE runs, taken mid-cycle after the
  // sample_ce edge so the registered values are stable.
  always @(posedge clk) begin
    if (dut.rst_sys_n) begin
      ce_q <= dut.sample_ce;
      if (dut.u_voice.pending_activate) begin
        act_armed <= 1'b1;
        act_pulses <= act_pulses + 1;
      end
    end
  end
  always @(negedge clk) begin
    if (ce_q && dut.mode_live) begin
      if (n < CAP) begin
        samp[n]  = dut.i2s_sample;
        fx[n]    = dut.fx_sample;
        voice[n] = dut.voice_sample;
        hit[n]   = act_armed;
      end
      act_armed <= 1'b0;
      if (n < CAP) n = n + 1;
    end
  end

  // --------------------------------------------------------------- helpers ---
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

  // kind 0 = one sine period, kind 1 = one period of the 5th harmonic.  Both
  // have the same peak, so any difference in the output is shape, not level.
  function automatic logic signed [15:0] table_value(input integer idx, input integer kind_sel);
    real th;
    begin
      th = 6.283185307179586 * idx / 1024.0;
      if (kind_sel == 0) table_value = $rtoi($sin(th) * SINE_AMP);
      else               table_value = $rtoi($sin(5.0 * th) * SINE_AMP);
    end
  endfunction

  task automatic inject_byte(input [7:0] value);
    begin
      inject_value = value;
      force dut.uart_byte = inject_value;
      force dut.uart_byte_valid = 1'b1;
      @(posedge clk);
      #1;
      force dut.uart_byte_valid = 1'b0;
      @(posedge clk);
      #1;
      release dut.uart_byte_valid;
      release dut.uart_byte;
    end
  endtask

  task automatic inject_control(input [7:0] op, input [7:0] address,
                                input [7:0] sq, input [31:0] data);
    reg [7:0] b [0:10];
    reg [15:0] c;
    integer kk;
    begin
      b[0] = 8'ha5; b[1] = 8'h02; b[2] = op; b[3] = address; b[4] = sq;
      b[5] = data[31:24]; b[6] = data[23:16]; b[7] = data[15:8]; b[8] = data[7:0];
      c = 16'hffff;
      for (kk = 0; kk < 9; kk = kk + 1) c = crc_byte(c, b[kk]);
      b[9] = c[15:8]; b[10] = c[7:0];
      guard = 0;
      while ((dut.v2_tx_valid || dut.uart_tx_busy) && guard < 200000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "the previous reply never finished");
      for (kk = 0; kk < 11; kk = kk + 1) inject_byte(b[kk]);
      repeat (4) @(posedge clk);
      for (kk = 0; kk < 20000; kk = kk + 1) begin
        if (!dut.v2_tx_valid && !dut.uart_tx_busy) kk = 20000;
        else @(posedge clk);
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy)
        $fatal(1, "V2 UART response did not drain");
      if (dut.rsp_error !== 8'd0)
        $fatal(1, "op=0x%02h addr=0x%02h seq=0x%02h NACKed err=0x%02h",
               op, address, sq, dut.rsp_error);
    end
  endtask

  task automatic upload_table(input integer kind_sel);
    integer t;
    begin
      inject_control(8'h02, 8'h6C, 8'h60, 32'd1024);      // length
      inject_control(8'h02, 8'h64, 8'h61, 32'd0);         // index = 0
      for (t = 0; t < 1024; t = t + 1) begin
        tbl_tmp = table_value(t, kind_sel);
        inject_control(8'h02, 8'h68, 8'h60 + t[7:0], {16'd0, tbl_tmp});
      end
      crc = 16'hffff;
      for (t = 0; t < 1024; t = t + 1) begin
        tbl_tmp = table_value(t, kind_sel);
        crc = crc_byte(crc, tbl_tmp[15:8]);
        crc = crc_byte(crc, tbl_tmp[7:0]);
      end
      inject_control(8'h02, 8'h70, 8'h62, {16'd0, crc});  // expected CRC
      inject_control(8'h02, 8'h74, 8'h63, 32'd0);         // version
      inject_control(8'h02, 8'h78, 8'h64, 32'h8000_0000); // APPLY + commit
      guard = 0;
      while (!dut.u_wavetable_loader.wt_active_valid && guard < 300000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (!dut.u_wavetable_loader.wt_active_valid)
        $fatal(1, "table %0d never became active (crc=0x%04h reason=%0d)",
               kind_sel, crc, dut.u_wavetable_loader.dbg_apply_reject_reason);
      $display("table %0d active: crc=0x%04h", kind_sel, crc);
    end
  endtask

  task automatic send_frame(input [15:0] xv);
    begin
      tb_cursor_x = {16'd0, xv};
      @(negedge clk); tb_frame_done = 1'b1;
      @(negedge clk); tb_frame_done = 1'b0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic wait_samples(input integer count);
    begin
      mark = n;
      while ((n - mark) < count) @(negedge clk);
    end
  endtask

  task automatic note_on;
    begin
      tb_cursor_state = 2'd1;
      send_frame(16'd0);
      send_frame(16'd0);
      send_frame(16'd5000);
      send_frame(16'd20000);
      guard = 0;
      while (!dut.live_active && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      if (!dut.live_active) $fatal(1, "no LIVE NOTE_ON (hand held at x=20000, y=3000)");
      if (dut.live_active_note !== 8'd55)
        $fatal(1, "LIVE note %0d, want 55 for y=3000", dut.live_active_note);
    end
  endtask

  task automatic release_note;
    begin
      tb_cursor_state = 2'd0;
      for (i = 0; i < 6; i = i + 1) send_frame(16'd20000);
      guard = 0;
      while (dut.live_active && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      if (dut.live_active) $fatal(1, "the LIVE NOTE_OFF never came");
      // The NOTE_OFF must also drain out of the rule engine before the mode
      // changes: a held event would otherwise block the next NOTE_ON.
      guard = 0;
      while (dut.live_event_valid && guard < 50000) begin @(negedge clk); guard = guard + 1; end
      if (dut.live_event_valid) $fatal(1, "the LIVE NOTE_OFF never drained");
      wait_samples(220);                                // let the release finish
    end
  endtask

  task automatic peak_abs(input integer lo, input integer hi, output integer pk);
    integer kk;
    begin
      pk = 0;
      for (kk = lo; kk < hi; kk = kk + 1) begin
        if (samp[kk] < 0) begin if (-samp[kk] > pk) pk = -samp[kk]; end
        else if (samp[kk] > pk) pk = samp[kk];
      end
    end
  endtask

  task automatic sum_abs(input integer lo, input integer hi, output integer sm);
    integer kk;
    begin
      sm = 0;
      for (kk = lo; kk < hi; kk = kk + 1) begin
        if (samp[kk] < 0) sm = sm - samp[kk];
        else sm = sm + samp[kk];
      end
    end
  endtask

  task automatic crossings(input integer lo, input integer hi, output integer cnt);
    integer kk;
    begin
      cnt = 0;
      for (kk = lo + 1; kk < hi; kk = kk + 1)
        if (voice[kk-1] <= 0 && voice[kk] > 0) cnt = cnt + 1;
    end
  endtask

  // ------------------------------------------------------------------ run ----
  initial begin : run_tb
    act_pulses = 0;
    repeat (40) @(posedge clk);
    guard = 0;
    while (dut.rst_sys_n !== 1'b1 && guard < 10000) begin @(negedge clk); guard = guard + 1; end
    if (dut.rst_sys_n !== 1'b1) $fatal(1, "reset did not release");
    if (!dut.pll_locked) $fatal(1, "pll_locked is low");

    force dut.cursor_state      = tb_cursor_state;
    force dut.cursor_x          = tb_cursor_x;
    force dut.cursor_y          = tb_cursor_y;
    force dut.cursor_z          = tb_cursor_z;
    force dut.cursor_velocity   = tb_cursor_velocity;
    force dut.cursor_depth      = tb_cursor_depth;
    force dut.cursor_frame_done = tb_frame_done;
    force dut.degraded_frame    = 1'b0;
    force dut.calibrated_gap    = 1'b0;
    force dut.cursor_rebased    = 1'b0;
    force dut.tick_pulse        = tb_tick_pulse;

    inject_control(8'h01, 8'hB0, 8'h30, 32'd0);
    if (dut.rsp_data !== 32'h5A5A_0003) $fatal(1, "0xB0=0x%08h", dut.rsp_data);

    // ---- (a) LIVE is the engine through the FX, trimmed and registered ----
    inject_control(8'h02, 8'h60, 8'h5F, 32'h0000_0020); // table 0, shift 2
    inject_control(8'h01, 8'h60, 8'h5E, 32'd0);
    if (dut.rsp_data[2:0] !== 3'b000 || dut.rsp_data[7:4] !== 4'd2)
      $fatal(1, "WT_SELECT is 0x%08h, expected table 0 shift 2", dut.rsp_data);
    upload_table(0);

    inject_control(8'h02, 8'h04, 8'h31, 32'd1);         // MODE = LIVE
    repeat (8) @(negedge clk);
    if (!dut.mode_live) $fatal(1, "MODE=LIVE was rejected");
    note_on;
    wait_samples(400);                                  // default attack 16 + decay 64
    mark_a = n;
    wait_samples(600);
    mark_sine = n;

    peak_abs(mark_a + 20, mark_a + 580, peak_sine);
    if (peak_sine == 0)
      $fatal(1, "(a) i2s_sample is silent in LIVE (voice_sample=%0d fx_sample=%0d)",
             dut.voice_sample, dut.fx_sample);
    track_bad = 0;
    for (k = mark_a + 1; k < mark_a + 580; k = k + 1)
      if (samp[k] !== (fx[k-1] >>> 2)) track_bad = track_bad + 1;
    if (track_bad != 0)
      $fatal(1, "(a) %0d of 579 i2s samples are not fx_sample[n-1] >>> 2 (LIVE is not on the FX path)",
             track_bad);
    if (dut.active_voice_count == 0)
      $fatal(1, "(a) no active voice while LIVE is sounding");
    $display("PASS (a) LIVE audio = FX(engine) >>> 2: 579 of 579 samples exact, peak %0d",
             peak_sine);

    // ---- (d) the sine table, and (e) the level behind the reset words ----
    mark_sine = n;
    wait_samples(2048);
    crossings(mark_sine + 50, mark_sine + 2048, xings_sine);
    peak_abs(mark_sine + 50, mark_sine + 2048, peak_sine);
    if (peak_sine == 0 || xings_sine < 2)
      $fatal(1, "(d) sine table gave no usable engine output (peak=%0d xings=%0d)",
             peak_sine, xings_sine);

    release_note;
    inject_control(8'h01, 8'h84, 8'h65, 32'd0);
    if (dut.rsp_data !== 32'h0015_0000)
      $fatal(1, "(e) 0x84 reset is 0x%08h, expected the board word 0x0015_0000",
             dut.rsp_data);
    note_on;
    wait_samples(400);
    mark_e1 = n;
    wait_samples(600);
    sum_abs(mark_e1, mark_e1 + 600, sum_reset);
    if (sum_reset == 0) $fatal(1, "(e) LIVE is silent behind the FX reset words");

    release_note;
    inject_control(8'h02, 8'h84, 8'h66, 32'h0001_0000); // enable 0 => level 0 bypass
    note_on;
    wait_samples(400);
    mark_e2 = n;
    wait_samples(600);
    sum_abs(mark_e2, mark_e2 + 600, sum_bypass);
    if (sum_bypass == 0) $fatal(1, "(e) the level-0 bypass is silent");
    if ((sum_reset > sum_bypass * 103 / 100) || (sum_reset * 103 / 100 < sum_bypass))
      $fatal(1, "(e) FX at its reset words changed LIVE by more than 3%%: %0d vs bypass %0d",
             sum_reset, sum_bypass);
    $display("PASS (e) FX reset (0x0015_0000) leaves LIVE within 3%% of the bypass: %0d vs %0d",
             sum_reset, sum_bypass);

    // ---- (f) 0x84/0x88/0x8C audibly change LIVE --------------------------
    release_note;
    inject_control(8'h02, 8'h84, 8'h67, 32'h0019_0000); // enable, level 2, unity gain
    inject_control(8'h02, 8'h88, 8'h68, 32'hFFFF_00F0); // max cutoff, 240-sample delay
    inject_control(8'h02, 8'h8C, 8'h69, 32'h0000_4000); // feedback 0.5, no reverb
    note_on;
    wait_samples(700);
    mark_f = n;
    wait_samples(600);
    sum_abs(mark_f, mark_f + 600, sum_fx);
    if (sum_fx <= sum_reset * 130 / 100)
      $fatal(1, "(f) level 2 + delay did not change LIVE: %0d vs reset %0d",
             sum_fx, sum_reset);
    $display("PASS (f) FX level 2 with a 240-sample delay changes LIVE: %0d vs reset %0d",
             sum_fx, sum_reset);
    release_note;

    // Restore the board reset words before the remaining audio tests.
    inject_control(8'h02, 8'h84, 8'h6A, 32'h0015_0000);
    inject_control(8'h02, 8'h88, 8'h6B, 32'hFFFF_0000);
    inject_control(8'h02, 8'h8C, 8'h6C, 32'h0000_0000);

    // ---- (b1) sustain 0 + fast decay is silence while the hand stays ------
    inject_control(8'h02, 8'h98, 8'h6D, {16'd1024, 16'd0});      // release 1024, sustain 0
    inject_control(8'h02, 8'h94, 8'h6E, {16'd4096, 16'd4096});   // decay 4096, attack 4096
    note_on;
    mark_b1 = n;
    wait_samples(500);
    peak_abs(mark_b1 + 1, mark_b1 + 60, early_peak);
    peak_abs(mark_b1 + 200, mark_b1 + 500, tail_peak);
    if (early_peak < 2)
      $fatal(1, "(b1) the sustain-0 note never sounded on the way down (peak=%0d)", early_peak);
    if (tail_peak > 1)
      $fatal(1, "(b1) sustain 0 did not reach silence: tail peak %0d", tail_peak);
    if (dut.active_voice_count == 0)
      $fatal(1, "(b1) the voice vanished instead of holding at sustain 0");
    $display("PASS (b1) sustain 0: attack peak %0d -> tail peak %0d, %0d voices still active",
             early_peak, tail_peak, dut.active_voice_count);

    // ---- (b2) a slow attack swells ---------------------------------------
    release_note;
    inject_control(8'h02, 8'h98, 8'h6F, {16'd1024, 16'd49152});  // sustain 49152
    inject_control(8'h02, 8'h94, 8'h70, {16'd4096, 16'd32});     // decay 4096, attack 32
    note_on;
    mark_b2 = n;
    wait_samples(2600);
    peak_abs(mark_b2 + 60, mark_b2 + 360, early_peak);
    peak_abs(mark_b2 + 2200, mark_b2 + 2600, late_peak);
    if (late_peak < 4 * (early_peak + 1))
      $fatal(1, "(b2) no attack swell: early peak %0d, late peak %0d",
             early_peak, late_peak);
    if (late_peak < 2)
      $fatal(1, "(b2) the slow-attack note stayed silent");
    $display("PASS (b2) slow attack: early peak %0d -> late peak %0d", early_peak, late_peak);

    // ---- (c) arp mode still makes sound on every step ---------------------
    release_note;
    inject_control(8'h02, 8'h94, 8'h71, {16'd256, 16'd4096});    // default attack/decay
    inject_control(8'h02, 8'h30, 8'h72, 32'h0180_0000);          // arp mode on
    repeat (8) @(negedge clk);
    if (!dut.u_live.arp_mode) $fatal(1, "(c) arp mode did not latch");
    tb_cursor_state = 2'd1;
    send_frame(16'd20000);
    send_frame(16'd20000);
    mark_c = n;
    for (i = 0; i < 3; i = i + 1) begin
      guard = 0;
      while (dut.u_live.arp_state != 2'd0 && guard < 50000) begin @(negedge clk); guard = guard + 1; end
      @(negedge clk); tb_tick_pulse = 1'b1;
      @(negedge clk); tb_tick_pulse = 1'b0;
      wait_samples(230);
    end
    if ((n - mark_c) < 690) $fatal(1, "(c) the arp capture is short");
    for (i = 0; i < 3; i = i + 1) begin
      peak_abs(mark_c + i * 230 + 40, mark_c + i * 230 + 220, step_peak);
      if (step_peak < 2)
        $fatal(1, "(c) arp step %0d is silent (peak %0d)", i, step_peak);
    end
    $display("PASS (c) arp steps 0..2 each carry sound past a level floor");
    release_note;

    // ---- (d) the 5th-harmonic table: same level, different shape ----------
    inject_control(8'h02, 8'h04, 8'h73, 32'd0);                   // MODE = IDLE
    repeat (8) @(negedge clk);
    if (dut.mode_live) $fatal(1, "(d) MODE=IDLE was rejected");
    inject_control(8'h02, 8'h30, 8'h76, 32'h0100_0000);           // arp mode off (bit 23 = 0)
    repeat (8) @(negedge clk);
    if (dut.u_live.arp_mode) $fatal(1, "(d) arp mode did not clear");
    inject_control(8'h02, 8'h60, 8'h74, 32'h0000_0021);           // table 1, shift 2
    upload_table(1);
    inject_control(8'h02, 8'h04, 8'h75, 32'd1);                   // MODE = LIVE
    repeat (8) @(negedge clk);
    if (!dut.mode_live) $fatal(1, "(d) second MODE=LIVE was rejected");
    note_on;
    wait_samples(400);
    mark_harm = n;
    wait_samples(2048);
    crossings(mark_harm + 50, mark_harm + 2048, xings_harm);
    peak_abs(mark_harm + 50, mark_harm + 2048, peak_harm);
    if (peak_harm == 0)
      $fatal(1, "(d) the 5th-harmonic table is silent");
    if (xings_harm < 3 * xings_sine || xings_harm > 7 * xings_sine)
      $fatal(1, "(d) shape did not change with the table: sine %0d crossings, harmonic %0d",
             xings_sine, xings_harm);
    if (peak_harm * 2 < peak_sine || peak_harm > peak_sine * 2)
      $fatal(1, "(d) the two tables differ in level, not shape: peak %0d vs %0d",
             peak_sine, peak_harm);
    $display("PASS (d) wavetable is in the path: sine %0d crossings / peak %0d, 5th harmonic %0d crossings / peak %0d",
             xings_sine, peak_sine, xings_harm, peak_harm);

    // ---- (g) a pitch change retunes the engine without a new activation ---
    // Frame-level tracking sends REVOICE for a pitch change.  A REVOICE naming
    // the new note matches no sounding voice, so the engine treats it as a
    // legato retune of the newest voice: the bank note follows the pitch and
    // the step glides there.  The old single-voice path used to carry this
    // pitch; the engine has to carry it now.
    act0 = act_pulses;
    rev0 = dut.u_voice.revoice_count;
    mark_g = n;
    tb_cursor_y = 32'sd20000;                            // map_note -> 60 (C4)
    send_frame(16'd20000);
    send_frame(16'd20000);
    guard = 0;
    while (dut.live_active_note != 8'd60 && guard < 200000) begin
      @(negedge clk);
      guard = guard + 1;
    end
    if (dut.live_active_note !== 8'd60)
      $fatal(1, "(g) the pitch change never reached the rule engine");
    wait_samples(600);
    if (dut.u_voice.revoice_count == rev0)
      $fatal(1, "(g) the pitch change did not reach the engine (revoice_count stuck at %0d)",
             rev0);
    if (dut.u_voice.note[dut.u_voice.last_active_slot] !== 8'd60)
      $fatal(1, "(g) the engine still holds note %0d, expected 60",
             dut.u_voice.note[dut.u_voice.last_active_slot]);
    if (act_pulses != act0)
      $fatal(1, "(g) the pitch change reactivated the engine (%0d -> %0d)",
             act0, act_pulses);
    peak_abs(mark_g + 300, mark_g + 600, step_peak);
    if (step_peak < 2)
      $fatal(1, "(g) the retuned note is silent (peak %0d)", step_peak);
    $display("PASS (g) legato pitch change: revoice_count %0d -> %0d, note 60, no reactivation, peak %0d",
             rev0, dut.u_voice.revoice_count, step_peak);

    $display("TB_LIVE_ENGINE RESULT: PASS");
    $finish;
  end

  initial begin : timeout
    #2_000_000_000;
    $fatal(1, "tb_live_engine timeout (mode=%0d active=%0d n=%0d)",
           dut.mode_reg, dut.live_active, n);
  end
endmodule
