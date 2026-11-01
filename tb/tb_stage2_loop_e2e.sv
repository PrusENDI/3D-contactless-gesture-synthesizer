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
  integer ev_tick = -1, ev_dur = -1, ev_note = -1, ev_count = 0;

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
    if (dut.potts_event_valid && dut.potts_event_ready) begin
      if (ev_count == 0) begin
        ev_tick = dut.potts_event_data[87:80];
        ev_dur = dut.potts_event_data[79:72];
        ev_note = dut.potts_event_data[71:64];
      end
      ev_count = ev_count + 1;
    end
  end

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

    // Second take: commit without ever filling the contour.  The untouched
    // ticks were cleared at arm time, so they are rests; the melody must be the
    // 12 captured ticks only, not a tail fitted to the zeroed samples and not an
    // empty track.
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

    $display("PASS tb_stage2_loop_e2e boundaries=%0d voices_seen=%0d commit_events=%0d",
             boundary_count, voices_seen, dut.potts_commit_count);
    $finish;
  end

  initial begin : timeout
    #50_000_000;
    $fatal(1, "tb_stage2_loop_e2e timeout (full=%b run=%b done=%b)",
           dut.potts_capture_full, dut.potts_commit_run, dut.potts_commit_done);
  end
endmodule
