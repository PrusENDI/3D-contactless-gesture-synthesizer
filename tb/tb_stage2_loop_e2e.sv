`timescale 1ns/1ps
// End-to-end stage-2 loop: arm the capture, record 32 ticks, commit, play.
//
// Nothing here forces loop_boundary: the swap must come from the real scheduler
// running in PLAY.  The musical tick is forced so the bench does not have to
// simulate four seconds of audio per loop; everything below the tick (capture,
// DP, store, scheduler, voice engine) is the real logic.
module tb_stage2_loop_e2e;
  logic clk_50m = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  logic [7:0] inject_value;
  logic tb_tick_pulse = 1'b0;
  logic [6:0] tb_tick = 7'd0;
  logic [15:0] tb_y = 16'd0;
  logic tb_engaged = 1'b0;

  integer i, t, guard, boundary_count = 0, voices_seen = 0;
  integer sweep;
  integer all_off_events = 0;
  integer voice_all_off = 0;
  integer stop_cycles = -1;
  integer ev_tick = -1, ev_dur = -1, ev_note = -1, ev_count = 0;
  // Two-track case: what each track handed to the voice engine while PLAY ran,
  // and the largest number of voices that were sounding at the same time.
  integer n, trk, max_voices = 0;
  integer take1_count = 0, take2_count = 0;
  integer boundary_before = 0, note_gap = 0;
  time trk_note_time [0:5];
  integer trk_note [0:5];
  integer trk_note_tick [0:5];
  integer trk_note_count [0:5];

  always #5 clk_50m = ~clk_50m;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(1), .UART_BAUD(1_000_000),
                   .POTTS_HORIZON(32), .V2_DEBUG_CSR(1)) dut (
    .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck), .pcm5102a_din(pcm5102a_din)
  );

  // Drive the musical clock from the bench, and the contour input at the
  // capture block's pins: the sensor path has its own testbenches.
  initial begin
    force dut.tick_pulse = tb_tick_pulse;
    force dut.tick_now = tb_tick;
    force dut.u_contour.y = tb_y;
    force dut.u_contour.engaged = tb_engaged;
  end

  always @(posedge clk_50m) begin
    if (dut.loop_boundary) boundary_count = boundary_count + 1;
    if (dut.loop_event_valid && dut.loop_event_ready &&
        dut.loop_event_data[94:91] == 4'd5) all_off_events = all_off_events + 1;
    if (dut.active_voice_count > 0) voices_seen = voices_seen + 1;
    // The events the DP hands to the writer are the melody that gets stored.
    if (dut.voice_event_valid && dut.voice_event_ready &&
        dut.voice_event_data[94:91] == 4'd5) voice_all_off = voice_all_off + 1;
    if (dut.potts_event_valid && dut.potts_event_ready) begin
      if (ev_count == 0) begin
        ev_tick = dut.potts_event_data[87:80];
        ev_dur = dut.potts_event_data[79:72];
        ev_note = dut.potts_event_data[71:64];
      end
      ev_count = ev_count + 1;
    end
    // Committed events carry no track number (the DP leaves [90:88] zero), so
    // the source track is the one the scheduler is reading from when it hands
    // the held slot over.
    if (dut.active_voice_count > max_voices) max_voices = dut.active_voice_count;
    if (dut.loop_event_valid && dut.loop_event_ready &&
        dut.loop_event_data[94:91] == 4'd1) begin
      trk = dut.loop_read_track;
      if (trk < 6) begin
        if (trk_note_count[trk] == 0) begin
          trk_note[trk] = dut.loop_event_data[71:64];
          trk_note_tick[trk] = dut.loop_event_data[87:80];
          trk_note_time[trk] = $time;
        end
        trk_note_count[trk] = trk_note_count[trk] + 1;
      end
    end
  end

  initial begin
    for (n = 0; n < 6; n = n + 1) begin
      trk_note[n] = -1;
      trk_note_tick[n] = -1;
      trk_note_count[n] = 0;
      trk_note_time[n] = 0;
    end
  end

  function automatic [95:0] make_note_on(input [7:0] tick, input [7:0] note);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = 4'd1;
      e[87:80] = tick;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = 8'd100;
      make_note_on = e;
    end
  endfunction

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
      for (k = 0; k < 11; k = k + 1) inject_byte(b[k]);
      repeat (4) @(posedge clk_50m);
      for (k = 0; k < 200000; k = k + 1) begin
        if (!dut.v2_tx_valid && !dut.uart_tx_busy) k = 200000;
        else @(posedge clk_50m);
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy)
        $fatal(1, "V2 UART response did not drain");
    end
  endtask

  task automatic advance_tick(input integer tick_no, input [15:0] y_value, input logic eng);
    begin
      @(negedge clk_50m);
      tb_tick = tick_no[6:0];
      tb_y = y_value;
      tb_engaged = eng;
      tb_tick_pulse = 1'b1;
      @(negedge clk_50m);
      tb_tick_pulse = 1'b0;
      // One sweep is 576 slots over three passes; each read costs three cycles
      // (read_enable -> read_pending -> read_valid) plus one for the held event,
      // so a sweep needs about 2300 cycles.  Hold each compressed tick longer
      // than that, otherwise a sweep straddles two ticks and half of them are
      // never scanned.
      repeat (2600) @(posedge clk_50m);
    end
  endtask

  // Write 0x28 and wait for the DP to stream its last event.  A new take clears
  // the previous take's done flag on the kick, so wait for run to drop instead
  // of trusting a done flag that may still be set from the take before.
  task automatic commit_wait;
    begin
      guard = 0;
      while (dut.potts_commit_done && !dut.potts_commit_run && guard < 1000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      while ((dut.potts_commit_run || !dut.potts_commit_done) && guard < 3_000_000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (dut.potts_commit_run || !dut.potts_commit_done)
        $fatal(1, "the DP never finished (run=%b done=%b)", dut.potts_commit_run,
               dut.potts_commit_done);
      if (dut.potts_overflow) $fatal(1, "the DP overflowed the event buffer");
    end
  endtask

  task automatic commit_take(input [7:0] seq);
    begin
      inject_control(8'h02, 8'h28, seq, 32'd1);
      commit_wait;
    end
  endtask

  task automatic clear_track_stats;
    begin
      for (n = 0; n < 6; n = n + 1) begin
        trk_note[n] = -1;
        trk_note_tick[n] = -1;
        trk_note_count[n] = 0;
        trk_note_time[n] = 0;
      end
      max_voices = 0;
    end
  endtask

  initial begin : run_tb
    repeat (40) @(posedge clk_50m);
    if (!dut.rst_sys_n || !dut.pll_locked) $fatal(1, "reset/PLL did not release");

    // Selecting another track first proves the protocol step matters: 0x18
    // prepares whichever track is selected, and the commit writes track 0.
    inject_control(8'h02, 8'h0C, 8'h31, 32'd1);
    inject_control(8'h02, 8'h0C, 8'h32, 32'd0);
    inject_control(8'h02, 8'h18, 8'h33, 32'd1);

    // 32 ticks of a rising contour (about 2 note levels per tick), with a
    // two-tick hand-off at ticks 12..13.
    for (t = 0; t < 32; t = t + 1)
      advance_tick(t, 16'd2000 * (t + 1), (t != 12) && (t != 13));
    if (!dut.potts_capture_full) $fatal(1, "capture did not complete after 32 ticks");
    if (!dut.potts_purify_done_seen) $fatal(1, "rest purifier never ran");

    // The host reads the same facts through the CSR window, so check the status
    // word and the auto-incrementing contour dump here: the board script is the
    // only other thing that exercises them.
    inject_control(8'h01, 8'h38, 8'h38, 32'd0);
    if (dut.rsp_data[4] !== 1'b1) $fatal(1, "0x38 full bit not set (0x%08h)", dut.rsp_data);
    if (dut.rsp_data[2] !== 1'b0) $fatal(1, "0x38 overflow set after a clean capture");
    inject_control(8'h01, 8'h3C, 8'h39, 32'd0);
    if (dut.rsp_data[15:0] !== 16'd21600)
      $fatal(1, "0x3C lambda=%0d expected 21600", dut.rsp_data[15:0]);
    inject_control(8'h02, 8'h34, 8'h3A, 32'd0);
    for (i = 0; i < 32; i = i + 1) begin
      inject_control(8'h01, 8'h34, 8'h40 + i[7:0], 32'd0);
      if ((dut.rsp_data & 32'hFFFF) !== ((16'd2000 * (i + 1)) >> 6))
        $fatal(1, "0x34 sample[%0d]=%0d expected %0d", i, dut.rsp_data & 32'hFFFF,
               (16'd2000 * (i + 1)) >> 6);
    end

    // A LIVE note landing in the lead track while RECORD is armed is what broke
    // the board: the recorder owned that track, the shadow count went non-zero,
    // and the commit writer then started at slot 0 against a full track so the
    // store refused every event.  The commit must clear the track first.
    @(negedge clk_50m);
    force dut.live_event_data = make_note_on(8'd0, 8'd64);
    force dut.live_event_valid = 1'b1;
    repeat (2) @(posedge clk_50m);
    release dut.live_event_valid;
    release dut.live_event_data;
    repeat (10) @(posedge clk_50m);
    if (dut.loop_record_count[5:0] == 6'd0)
      $fatal(1, "the injected LIVE event never reached the shadow lead track");

    inject_control(8'h02, 8'h28, 8'h34, 32'd1);
    guard = 0;
    while (!dut.potts_commit_done && guard < 3_000_000) begin
      @(posedge clk_50m);
      guard = guard + 1;
    end
    if (!dut.potts_commit_done) $fatal(1, "commit never finished (busy=%b)", dut.potts_commit_run);
    if (dut.potts_overflow) $fatal(1, "DP overflowed the event buffer");
    if (dut.potts_commit_count < 1) $fatal(1, "the DP produced no events");
    repeat (4) @(posedge clk_50m);
    if (!dut.loop_commit_pending) $fatal(1, "store did not receive COMMIT_REQUEST");
    if (dut.loop_active_valid) $fatal(1, "the swap happened before PLAY");

    inject_control(8'h02, 8'h04, 8'h35, 32'd4);   // MODE=PLAY
    if (!dut.mode_play) $fatal(1, "MODE=PLAY was rejected");

    // Two loops: the first ends the commit and swaps, the second plays it.
    for (sweep = 0; sweep < 2; sweep = sweep + 1)
      for (t = 0; t < 32; t = t + 1) advance_tick(t, 16'd0, 1'b0);

    if (boundary_count < 1) $fatal(1, "no loop boundary came from the scheduler");
    if (!dut.loop_active_valid) $fatal(1, "the bank swap never completed");
    if (dut.loop_commit_pending) $fatal(1, "commit stayed pending after the boundary");
    if (voices_seen == 0) $fatal(1, "the committed tracks never reached the voice engine");

    // Every loop boundary must be preceded by an ALL_NOTES_OFF, otherwise the
    // last note of the previous loop (whose duration ends exactly at the loop
    // length) would hang into the next one.  The bench compresses ticks, so the
    // release envelope cannot be watched here; the delivered event is the
    // checkable fact.
    for (t = 0; t < 5; t = t + 1) advance_tick(t, 16'd0, 1'b0);
    repeat (200) @(posedge clk_50m);
    if (all_off_events < boundary_count)
      $fatal(1, "%0d ALL_NOTES_OFF for %0d boundaries", all_off_events, boundary_count);

    // STOP while a note is sounding (still in PLAY here): the loop must send
    // ALL_NOTES_OFF and the voice must fall silent.  Without it the note hangs,
    // because the scheduler simply stops scanning when PLAY ends.
    guard = 0;
    while (dut.active_voice_count == 0 && guard < 200) begin
      for (t = 0; t < 32 && dut.active_voice_count == 0; t = t + 1)
        advance_tick(t, 16'd0, 1'b0);
      guard = guard + 1;
    end
    if (dut.active_voice_count == 0) $fatal(1, "no note was sounding before STOP");
    voice_all_off = 0;
    inject_control(8'h02, 8'h14, 8'h39, 32'd1);       // STOP (the contract needs data=1)
    repeat (10) @(posedge clk_50m);
    if (dut.mode_play) $fatal(1, "STOP did not leave PLAY (mode_play still high)");
    guard = 0;
    // The release is 1024 per sample (about 64 samples), so allow a few hundred.
    while (dut.active_voice_count != 0 && guard < 300000) begin
      @(posedge clk_50m);
      guard = guard + 1;
    end
    if (voice_all_off == 0)
      $fatal(1, "STOP did not send ALL_NOTES_OFF to the voice engine");
    if (dut.active_voice_count != 0)
      $fatal(1, "%0d voices still sounding after STOP", dut.active_voice_count);
    stop_cycles = guard;

    // Second take: commit without ever filling the contour.  The untouched
    // ticks were cleared at arm time, so they are rests; the melody must be the
    // 12 captured ticks only, not a tail fitted to the zeroed samples and not an
    // empty track.  (Committing does not need a sounding mode.)
    inject_control(8'h02, 8'h18, 8'h36, 32'd1);
    ev_count = 0; ev_tick = -1; ev_dur = -1; ev_note = -1;
    for (t = 0; t < 12; t = t + 1) advance_tick(t, 16'd60000, 1'b1);
    if (dut.potts_capture_full) $fatal(1, "partial capture reported full");
    inject_control(8'h02, 8'h28, 8'h37, 32'd1);
    guard = 0;
    while ((ev_count == 0 || dut.potts_commit_run) && guard < 3_000_000) begin
      @(posedge clk_50m);
      guard = guard + 1;
    end
    if (ev_count != 1)
      $fatal(1, "partial take produced %0d events, expected 1", ev_count);
    if (ev_tick != 0 || ev_dur != 12 || ev_note != 72)
      $fatal(1, "partial take event t%0d/d%0d/n%0d expected t0/d12/n72",
             ev_tick, ev_dur, ev_note);

    // ---- Two tracks ------------------------------------------------------
    // Each take must land on the track that was selected when 0x28 was written,
    // and both tracks must then sound together.
    //
    // The store publishes its whole shadow bank at one loop boundary, so the
    // takes are published one at a time: take 1 to track 0, publish it, then
    // take 2 to track 1.  PREPARE_RECORD copies the active bank into the shadow
    // bank, which is what carries track 0 into the second take.
    //
    // The per-track counts live in the shadow bank and the swap clears the
    // retired bank, so they are read right after each commit, before PLAY.
    inject_control(8'h02, 8'h14, 8'h60, 32'd1);       // STOP: abort the pending partial take
    guard = 0;
    while ((dut.loop_commit_pending || dut.loop_busy) && guard < 100000) begin
      @(posedge clk_50m);
      guard = guard + 1;
    end
    if (dut.loop_commit_pending || dut.loop_busy)
      $fatal(1, "the store did not release the aborted commit");

    // Take 1: the rising contour goes to track 0.
    inject_control(8'h02, 8'h0C, 8'h61, 32'd0);
    inject_control(8'h02, 8'h18, 8'h62, 32'd1);
    for (t = 0; t < 32; t = t + 1)
      advance_tick(t, 16'd2000 * (t + 1), 1'b1);
    if (!dut.potts_capture_full) $fatal(1, "two-track take 1 capture did not complete");
    commit_take(8'h63);
    if (dut.potts_commit_count < 1) $fatal(1, "two-track take 1 produced no events");
    take1_count = dut.potts_commit_count;
    if (dut.loop_record_count[5:0] != take1_count)
      $fatal(1, "take 1 stored %0d events in track 0, the DP produced %0d",
             dut.loop_record_count[5:0], take1_count);
    if (dut.loop_record_count[11:6] != 0)
      $fatal(1, "take 1 leaked %0d events into track 1", dut.loop_record_count[11:6]);
    if (|dut.loop_overflow) $fatal(1, "the store flagged overflow (0x%02h)", dut.loop_overflow);

    // Publish take 1 so the next PREPARE copies it into the new shadow bank.
    inject_control(8'h02, 8'h04, 8'h64, 32'd4);       // MODE=PLAY
    if (!dut.mode_play) $fatal(1, "MODE=PLAY was rejected for take 1");
    for (sweep = 0; sweep < 2; sweep = sweep + 1)
      for (t = 0; t < 32; t = t + 1) advance_tick(t, 16'd0, 1'b0);
    if (!dut.loop_active_valid) $fatal(1, "take 1 was never published");
    if (dut.loop_commit_pending) $fatal(1, "take 1 is still pending after the boundary");

    // Take 2: a held high note goes to track 1 while track 0 stays put.
    inject_control(8'h02, 8'h14, 8'h65, 32'd1);       // STOP -> IDLE
    guard = 0;
    while (dut.active_voice_count != 0 && guard < 300000) begin
      @(posedge clk_50m);
      guard = guard + 1;
    end
    if (dut.mode_play) $fatal(1, "STOP did not leave PLAY before take 2");
    inject_control(8'h02, 8'h0C, 8'h66, 32'd1);       // select track 1
    inject_control(8'h02, 8'h18, 8'h67, 32'd1);       // PREPARE_RECORD copies track 0
    for (t = 0; t < 32; t = t + 1) advance_tick(t, 16'd60000, 1'b1);
    if (!dut.potts_capture_full) $fatal(1, "two-track take 2 capture did not complete");
    inject_control(8'h02, 8'h28, 8'h68, 32'd1);       // COMMIT latches track 1
    // Retarget mid-commit: the latched track must win, so this write may not
    // move the events onto track 0.
    inject_control(8'h02, 8'h0C, 8'h69, 32'd0);
    if (!dut.potts_commit_run)
      $fatal(1, "take 2 finished before the mid-commit 0x0C write; the latch is untested");
    commit_wait;
    if (dut.potts_commit_count != 1)
      $fatal(1, "take 2 produced %0d events, expected 1", dut.potts_commit_count);
    take2_count = dut.potts_commit_count;
    if (dut.loop_record_count[11:6] != take2_count)
      $fatal(1, "take 2 stored %0d events in track 1, expected %0d",
             dut.loop_record_count[11:6], take2_count);
    if (dut.loop_record_count[5:0] != take1_count)
      $fatal(1, "take 2 overwrote track 0 (%0d events, was %0d)",
             dut.loop_record_count[5:0], take1_count);

    // Play both: the two takes must reach the voice engine as separate notes.
    // The first loop still scans the bank from take 1 and publishes the new one
    // at its boundary, so the measurement is taken on the second loop, where
    // every event can only come from the two committed tracks.
    inject_control(8'h02, 8'h04, 8'h6A, 32'd4);       // MODE=PLAY
    if (!dut.mode_play) $fatal(1, "MODE=PLAY was rejected for the two tracks");
    boundary_before = boundary_count;
    for (t = 0; t < 32; t = t + 1) advance_tick(t, 16'd0, 1'b0);
    if (boundary_count <= boundary_before)
      $fatal(1, "the two-track commit never published at a boundary");
    if (!dut.loop_active_valid) $fatal(1, "the store reports no active track");
    if (dut.loop_commit_pending) $fatal(1, "the two-track commit is still pending");

    clear_track_stats;
    for (t = 0; t < 32; t = t + 1) advance_tick(t, 16'd0, 1'b0);
    if (trk_note_count[0] < 1) $fatal(1, "track 0 played no note");
    if (trk_note_count[1] < 1) $fatal(1, "track 1 played no note");
    if (trk_note[0] == trk_note[1])
      $fatal(1, "both tracks play note %0d; the takes are not independent", trk_note[0]);
    if (trk_note_tick[0] != 0 || trk_note_tick[1] != 0)
      $fatal(1, "both tracks should start at tick 0 (t%0d and t%0d)",
             trk_note_tick[0], trk_note_tick[1]);
    // Both first notes were accepted inside one sweep, so the engine holds two
    // different notes at the same tick: that is the two tracks sounding
    // together.  (A sweep scans the six tracks in about 25 us here.)
    if (trk_note_time[0] > trk_note_time[1])
      note_gap = trk_note_time[0] - trk_note_time[1];
    else
      note_gap = trk_note_time[1] - trk_note_time[0];
    if (note_gap > 25000)
      $fatal(1, "the two tracks' first notes are %0d ns apart, not one sweep", note_gap);
    // Sanity number only: the compressed tick (2600 cycles) is about 1.5 audio
    // samples, so a single track's release tails overlap by themselves and the
    // count can exceed 2.  Two voices at once is the floor, not the proof.
    if (max_voices < 2)
      $fatal(1, "at most %0d voice(s) sounded at once", max_voices);
    if (dut.voice_steal_count != 0)
      $fatal(1, "the voice engine stole %0d voices for two tracks", dut.voice_steal_count);

    inject_control(8'h02, 8'h14, 8'h6B, 32'd1);       // STOP after the two-track play
    guard = 0;
    while (dut.active_voice_count != 0 && guard < 300000) begin
      @(posedge clk_50m);
      guard = guard + 1;
    end
    if (dut.active_voice_count != 0)
      $fatal(1, "%0d voices still sounding after the two-track STOP",
             dut.active_voice_count);
    if (dut.loop_commit_pending)
      $fatal(1, "the store still holds a commit after the two-track STOP");

    $display("PASS tb_stage2_loop_e2e boundaries=%0d voices_seen=%0d commit_events=%0d stop_cycles=%0d",
             boundary_count, voices_seen, dut.potts_commit_count, stop_cycles);
    $display("PASS two tracks t0=%0d events/t1=%0d events notes=%0d/%0d max_voices=%0d steals=0",
             take1_count, take2_count, trk_note[0], trk_note[1], max_voices);
    $display("PASS two tracks first notes %0d ns apart, both at tick %0d",
             note_gap, trk_note_tick[0]);
    $finish;
  end

  initial begin : timeout
    #120_000_000;
    $fatal(1, "tb_stage2_loop_e2e timeout (full=%b run=%b done=%b)",
           dut.potts_capture_full, dut.potts_commit_run, dut.potts_commit_done);
  end
endmodule
