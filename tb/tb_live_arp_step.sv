`timescale 1ns/1ps
// The LIVE step arpeggiator must not step the output on a step.
//
// A tick in arp mode (THRESHOLDS[23] = 1) queues NOTE_OFF + NOTE_ON.  The audible
// LIVE path is u_wt_playback -> -19.9 dB trim -> wt_env multiply -> I2S, and
// u_wt_playback's phase is never reset by an event, so the only quantity the
// NOTE_ON can step is wt_env.  This bench measures that: it plays a sine table at
// G3, captures dut.i2s_sample once per sample_ce, and reports the largest
// |sample[n] - sample[n-1]| around the note-on, first with the arpeggiator off
// (frame-level tracking) and then with it on.
//
// The hand is injected at the cursor filter's output (cursor_x/y/z, cursor_state,
// cursor_frame_done) and the arp tick is pulsed by the bench, so the run is exact
// and does not depend on the 16.6 ms tick divider; everything from that cursor
// boundary to i2s_sample is production logic.  The sine goes through the real
// UART uploader.  u_voice still receives the LIVE events (it is simply not muxed
// into I2S in LIVE), so the bench also counts its activation writes: that is how
// the "phase resets on the event" hypothesis is tested.
//
// Sample alignment: i2s_sample_raw is registered on sample_ce from wt_live_q and
// wt_live_q is registered from the wt_env product, so the envelope change lands
// in samp[] two sample_ce later.  The windows below are wide enough for that, and
// every row is dumped with its own env value so the lead is visible.
//
// Dumps (relative to the vsim working directory, .sim_unit under sim_unit.py):
//   ../artifacts/live_arp_step/live_arp_off.txt   steady samples, arp off
//   ../artifacts/live_arp_step/live_arp_on.txt    samples around each arp step
// If the directory does not exist the files fall back to the working directory.
module tb_live_arp_step;
  localparam integer SINE_AMP = 12288;        // 0x3000, headroom under the trim
  localparam integer CAP      = 4096;         // capture depth
  localparam integer WIN_PRE  = 4;            // samples shown before the note-on
  localparam integer WIN_POST = 12;           // samples shown after the note-on
  // max |sample[n]-sample[n-1]| limit: the sine itself steps about 32 units at
  // this note/amplitude, so 80 is well above the waveform and well below the
  // ~800-unit envelope slam this bench is meant to catch.
  localparam integer STEP_LIMIT = 80;

  logic clk = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  // Hand drive, forced into the cursor filter output boundary.
  logic [1:0]          tb_cursor_state = 2'd1;      // engaged
  logic signed [31:0]  tb_cursor_x = 32'sd0;
  logic signed [31:0]  tb_cursor_y = 32'sd3000;     // map_note -> 55 (G3)
  logic signed [31:0]  tb_cursor_z = 32'sd30000;
  logic                tb_frame_done = 1'b0;
  logic                tb_tick_pulse = 1'b0;

  integer i, j, k, guard, t, n = 0, mark = 0;
  integer off_lo, off_hi, off_max, off_arg, off_sum, off_min, off_maxv;
  integer arp_max, arp_arg, hit_count;
  integer hit_list [0:7];
  integer act_count, act_phase;
  integer diff;

  logic signed [15:0] samp    [0:CAP-1];
  logic [31:0]        env_buf [0:CAP-1];
  logic signed [15:0] live_buf[0:CAP-1];
  logic [9:0]         idx_buf [0:CAP-1];
  logic [31:0]        ph_buf  [0:CAP-1];
  logic               hit_buf [0:CAP-1];

  logic sample_ce_q = 1'b0;
  logic hit_armed   = 1'b0;
  logic [7:0] inject_value;
  logic [15:0] crc;
  logic signed [15:0] sine_tmp;
  integer foff, fon;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(0), .UART_BAUD(40_000_000),
                   .V2_DEBUG_CSR(1)) dut (
    .clk_50m(clk), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck),
    .pcm5102a_din(pcm5102a_din)
  );

  // ---------------------------------------------------------------- capture --
  // One row per sample_ce while LIVE runs.  hit_buf marks the sample edge at
  // which the envelope is (or would be) zeroed: it is raised by live_note_hit and
  // consumed by the next sample edge.
  always @(posedge clk) begin
    if (dut.rst_sys_n) begin
      if (dut.live_note_hit) hit_armed <= 1'b1;
      else if (sample_ce_q)  hit_armed <= 1'b0;
      sample_ce_q <= dut.sample_ce;
      if (sample_ce_q && dut.mode_live) begin
        if (n < CAP) begin
          samp[n]     = dut.i2s_sample;
          env_buf[n]  = dut.wt_env;
          live_buf[n] = dut.wt_live_q;
          idx_buf[n]  = dut.wt_play_index;
          ph_buf[n]   = dut.u_wt_playback.phase;
          hit_buf[n]  = hit_armed;
        end
        if (n < CAP) n = n + 1;
      end
      // The voice engine still writes phase_a = 0 into its bank on activation.
      if (dut.u_voice.pending_activate) begin
        act_count = act_count + 1;
        act_phase = dut.u_voice.bank_wr_data[31:0];
      end
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

  function automatic logic signed [15:0] sine_value(input integer idx);
    real th;
    begin
      th = 6.283185307179586 * idx / 1024.0;
      sine_value = $rtoi($sin(th) * SINE_AMP);
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

  task automatic upload_sine;
    begin
      inject_control(8'h02, 8'h6C, 8'h60, 32'd1024);      // length
      inject_control(8'h02, 8'h64, 8'h61, 32'd0);         // index = 0
      for (i = 0; i < 1024; i = i + 1) begin
        sine_tmp = sine_value(i);
        inject_control(8'h02, 8'h68, i[7:0], {16'd0, sine_tmp});
      end
      crc = 16'hffff;
      for (i = 0; i < 1024; i = i + 1) begin
        sine_tmp = sine_value(i);
        crc = crc_byte(crc, sine_tmp[15:8]);
        crc = crc_byte(crc, sine_tmp[7:0]);
      end
      inject_control(8'h02, 8'h70, 8'h62, {16'd0, crc});  // expected CRC
      inject_control(8'h02, 8'h74, 8'h63, 32'd0);         // version
      inject_control(8'h02, 8'h78, 8'h64, 32'h8000_0000); // APPLY + commit
      guard = 0;
      while (!dut.u_wavetable_loader.wt_active_valid && guard < 200000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (!dut.u_wavetable_loader.wt_active_valid)
        $fatal(1, "the sine never became active (crc=0x%04h reason=%0d)", crc,
               dut.u_wavetable_loader.dbg_apply_reject_reason);
      $display("table active: crc=0x%04h", crc);
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

  task automatic arp_tick;
    begin
      guard = 0;
      while (dut.u_live.arp_state != 2'd0 && guard < 50000) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (dut.u_live.arp_state != 2'd0) $fatal(1, "arp FSM stuck before a tick");
      guard = 0;
      while (dut.live_note_hit && guard < 50000) begin
        @(negedge clk);
        guard = guard + 1;
      end
      @(negedge clk); tb_tick_pulse = 1'b1;
      @(negedge clk); tb_tick_pulse = 1'b0;
      guard = 0;
      while (!dut.live_note_hit && guard < 50000) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (guard >= 50000) $fatal(1, "no NOTE_ON after the arp tick");
    end
  endtask

  // ------------------------------------------------------------------ run ----
  initial begin : run_tb
    act_count = 0;
    act_phase = 0;
    off_sum = 0; off_min = 0; off_maxv = 0;
    off_lo = 0; off_hi = 0; off_max = 0; off_arg = 0;
    arp_max = 0; arp_arg = 0; hit_count = 0;
    for (i = 0; i < 8; i = i + 1) hit_list[i] = 0;

    // 40 clocks covers the power-on reset counter; the loop then waits out any
    // residual X on the internal reset net (an X would compare as "not released").
    repeat (40) @(posedge clk);
    guard = 0;
    while (dut.rst_sys_n !== 1'b1 && guard < 10000) begin @(negedge clk); guard = guard + 1; end
    if (dut.rst_sys_n !== 1'b1) $fatal(1, "reset did not release");
    if (!dut.pll_locked) $fatal(1, "pll_locked is low");

    // Inject the hand at the cursor filter's output and hold the gate up.
    force dut.cursor_state      = tb_cursor_state;
    force dut.cursor_x          = tb_cursor_x;
    force dut.cursor_y          = tb_cursor_y;
    force dut.cursor_z          = tb_cursor_z;
    force dut.cursor_frame_done = tb_frame_done;
    force dut.degraded_frame    = 1'b0;
    force dut.calibrated_gap    = 1'b0;
    force dut.cursor_rebased    = 1'b0;
    force dut.tick_pulse        = tb_tick_pulse;

    inject_control(8'h01, 8'hB0, 8'h30, 32'd0);
    if (dut.rsp_data !== 32'h5A5A_0003) $fatal(1, "0xB0=0x%08h", dut.rsp_data);
    upload_sine;

    // ---- half 1: LIVE with the arpeggiator OFF (frame-level tracking) ------
    inject_control(8'h02, 8'h04, 8'h31, 32'd1);         // MODE = LIVE
    repeat (8) @(negedge clk);
    if (!dut.mode_live) $fatal(1, "MODE=LIVE was rejected");

    // Arm: enter at the left edge, then move right, then hold at x=20000.
    send_frame(16'd0);
    send_frame(16'd0);
    send_frame(16'd5000);
    send_frame(16'd20000);
    guard = 0;
    while (!dut.live_active && guard < 200000) begin @(negedge clk); guard = guard + 1; end
    if (!dut.live_active) $fatal(1, "track mode never emitted a NOTE_ON");
    if (dut.live_active_note !== 8'd55)
      $fatal(1, "track note %0d, want 55 for y=3000", dut.live_active_note);
    wait_samples(700);                                  // attack is 478 samples
    off_lo = n;
    wait_samples(600);
    off_hi = n;
    if (off_hi > CAP) $fatal(1, "capture overflow: %0d", off_hi);

    // ---- half 2: arpeggiator ON, same hand, same pitch ---------------------
    inject_control(8'h02, 8'h30, 8'h32, 32'h0180_0000); // THRESHOLDS[23] = 1
    repeat (8) @(negedge clk);
    if (!dut.u_live.arp_mode) $fatal(1, "arp mode did not latch");
    if (dut.live_active_note !== 8'd55) $fatal(1, "pitch moved into arp mode");

    for (t = 0; t < 3; t = t + 1) begin
      arp_tick();
      wait_samples(400);                                // 400 > the 478-sample attack
    end
    wait_samples(20);
    if (n > CAP) $fatal(1, "capture overflow: %0d", n);

    // ---- arp off: steady-window maximum step -------------------------------
    off_max = 0; off_arg = off_lo;
    for (k = off_lo + 1; k < off_hi; k = k + 1) begin
      diff = samp[k] - samp[k-1];
      if (diff < 0) diff = -diff;
      if (diff > off_max) begin off_max = diff; off_arg = k; end
    end
    off_min = samp[off_lo]; off_maxv = samp[off_lo];
    off_sum = 0;
    for (k = off_lo; k < off_hi; k = k + 1) begin
      if (samp[k] < off_min) off_min = samp[k];
      if (samp[k] > off_maxv) off_maxv = samp[k];
      off_sum = off_sum + samp[k];
    end

    // ---- arp on: maximum step in the window of every note-on --------------
    hit_count = 0;
    for (k = off_hi; k < n; k = k + 1) begin
      if (hit_buf[k] == 1'b1 && hit_count < 8) begin
        hit_list[hit_count] = k;
        hit_count = hit_count + 1;
      end
    end
    if (hit_count == 0) $fatal(1, "no NOTE_ON reached the audio capture in arp mode");
    arp_max = 0; arp_arg = off_hi;
    for (i = 0; i < hit_count; i = i + 1) begin
      j = hit_list[i];
      $display("BOUNDARY note-on at sample %0d", j);
      for (k = (j > WIN_PRE ? j - WIN_PRE : 1); k <= j + WIN_POST && k < n; k = k + 1)
        $display("  n=%0d sample=%0d live=%0d env=%0d idx=%0d phase=0x%08h",
                 k, samp[k], live_buf[k], env_buf[k], idx_buf[k], ph_buf[k]);
      for (k = (j > WIN_PRE ? j - WIN_PRE : 1); k <= j + WIN_POST && k < n; k = k + 1) begin
        diff = samp[k] - samp[k-1];
        if (diff < 0) diff = -diff;
        if (diff > arp_max) begin arp_max = diff; arp_arg = k; end
      end
    end

    // ---- dumps -------------------------------------------------------------
    foff = $fopen("../artifacts/live_arp_step/live_arp_off.txt", "w");
    if (foff == 0) foff = $fopen("live_arp_off.txt", "w");
    if (foff != 0) begin
      $fdisplay(foff, "n sample");
      for (k = off_lo; k < off_hi; k = k + 1) $fdisplay(foff, "%0d %0d", k, samp[k]);
      $fclose(foff);
    end
    fon = $fopen("../artifacts/live_arp_step/live_arp_on.txt", "w");
    if (fon == 0) fon = $fopen("live_arp_on.txt", "w");
    if (fon != 0) begin
      $fdisplay(fon, "n sample live env index phase");
      for (i = 0; i < hit_count; i = i + 1) begin
        j = hit_list[i];
        for (k = (j > WIN_PRE ? j - WIN_PRE : 1); k <= j + WIN_POST && k < n; k = k + 1)
          $fdisplay(fon, "%0d %0d %0d %0d %0d %0d", k, samp[k], live_buf[k],
                    env_buf[k], idx_buf[k], ph_buf[k]);
      end
      $fclose(fon);
    end

    $display("RESULT arp off: max step %0d at sample %0d (window %0d..%0d)",
             off_max, off_arg, off_lo, off_hi);
    $display("RESULT arp off: samples min=%0d max=%0d sum=%0d", off_min, off_maxv, off_sum);
    $display("RESULT arp on: %0d note-on windows, max step %0d at sample %0d",
             hit_count, arp_max, arp_arg);
    $display("RESULT voice engine activations in LIVE: %0d, last bank phase write 0x%08h",
             act_count, act_phase);
    if (ph_buf[arp_arg] == ph_buf[arp_arg - 1] || ph_buf[arp_arg] == 32'd0)
      $display("NOTE audible phase did not look continuous at the boundary");

    if (off_max > STEP_LIMIT)
      $fatal(1, "the arp-off reference already steps %0d (limit %0d)", off_max, STEP_LIMIT);
    if (arp_max > STEP_LIMIT)
      $fatal(1, "FAIL arp step steps the output by %0d (arp off was %0d, limit %0d)",
             arp_max, off_max, STEP_LIMIT);
    $display("PASS live arp step: max sample step %0d arp on, %0d arp off (limit %0d)",
             arp_max, off_max, STEP_LIMIT);
    $finish;
  end

  initial begin : timeout
    #400_000_000;
    $fatal(1, "tb_live_arp_step timeout (mode=%0d active=%0d n=%0d)",
           dut.mode_reg, dut.live_active, n);
  end
endmodule
