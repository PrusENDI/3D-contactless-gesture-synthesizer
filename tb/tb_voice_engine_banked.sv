`timescale 1ns/1ps
// Testbench for the 32-voice engine.
//
// Three things are pinned here:
//   1. the normal event stream (one note per 125 ms, release completes in about
//      64 samples) never runs the engine out of voices, so the stealing path
//      must never fire in ordinary use;
//   2. when the bank really is full, a NOTE_ON is accepted within a few cycles
//      instead of stalling event_ready for a 32-step metadata scan;
//   3. a voice that is already releasing is the one stolen.
module tb_voice_engine_banked;
  localparam integer VOICES = 32;

  logic clk = 0, rst_n = 0, sample_ce = 0;
  logic event_valid = 0;
  logic event_ready;
  logic [95:0] event_data = 0;
  logic signed [15:0] mixed_sample;
  logic sample_valid;
  logic [VOICES-1:0] active_bitmap;
  logic voice_overflow;
  logic [15:0] voice_steal_count;
  logic [7:0] revoice_count;
  logic [5:0] active_voice_count;
  logic [1:0] dbg_busy;
  logic [15:0] vibrato_phase;
  logic signed [15:0] vibrato_delta_cents;

  integer i, guard, ce_count, accept_cycles, slot74;
  logic [VOICES-1:0] rel_mask;

  always #5 clk = ~clk;
  // The DPB storage path needs the global set/reset model.
  GSR GSR(.GSRI(1'b1));

  // One sample period; the scan plus the bank read pipeline fits comfortably.
  always @(posedge clk) begin
    ce_count <= ce_count + 1;
    sample_ce <= (ce_count % 300) == 0;
  end

  v2_voice_engine_banked #(.VOICES(VOICES), .USE_GOWIN_RAM(1)) dut (
    .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
    .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
    .vibrato_hz_q8_8(16'd0), .vibrato_cents_q8_8(16'd0),
    .mixed_sample(mixed_sample), .sample_valid(sample_valid),
    .active_bitmap(active_bitmap), .voice_overflow(voice_overflow),
    .voice_steal_count(voice_steal_count), .revoice_count(revoice_count),
    .active_voice_count(active_voice_count), .dbg_busy(dbg_busy),
    .vibrato_phase(vibrato_phase), .vibrato_delta_cents(vibrato_delta_cents));

  function automatic [95:0] make_event(input [3:0] etype, input [7:0] note, input [7:0] vel);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = etype;
      e[90:88] = 3'd0;
      e[87:80] = 8'd0;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = vel;
      make_event = e;
    end
  endfunction

  task automatic send_event(input [95:0] e, input [127:0] name);
    begin
      @(negedge clk);
      event_data = e;
      event_valid = 1'b1;
      guard = 0;
      while (!event_ready && guard < 200000) begin
        @(posedge clk);
        #1;
        guard = guard + 1;
      end
      if (!event_ready)
        $fatal(1, "%0s: event_ready never came back after %0d cycles (scan_busy=%b)",
               name, guard, dbg_busy[0]);
      accept_cycles = guard;
      @(posedge clk);
      @(negedge clk);
      event_valid = 1'b0;
      event_data = 96'd0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic hold_samples(input integer n);
    begin
      repeat (n * 300) @(posedge clk);
    end
  endtask

  initial begin : run_tb
    ce_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");

    // 1) Ordinary use: 200 note pairs, one pair every eight sample periods
    //    (about 8 notes per second).  The release tail is ~64 samples, so the
    //    engine should never be short of voices.  A steal here means the event
    //    source or the release path is wrong, not that the bank is too small.
    for (i = 0; i < 200; i = i + 1) begin
      send_event(make_event(4'd1, 8'd48, 8'd100), "normal note on");
      hold_samples(4);
      send_event(make_event(4'd2, 8'd48, 8'd100), "normal note off");
      hold_samples(4);
      if (active_voice_count > 6'd3)
        $fatal(1, "concurrency grew to %0d voices at event %0d", active_voice_count, i);
    end
    if (voice_steal_count !== 16'd0)
      $fatal(1, "ordinary stream stole %0d voices", voice_steal_count);

    // 2) Fill the bank and steal.  Wait for the last release tail to finish so
    //    the fill starts from zero active voices.
    guard = 0;
    while (active_voice_count != 6'd0 && guard < 400000) begin
      @(posedge clk);
      #1;
      guard = guard + 1;
    end
    if (active_voice_count != 6'd0)
      $fatal(1, "engine still holds %0d voices after the ordinary stream", active_voice_count);
    for (i = 0; i < VOICES; i = i + 1)
      send_event(make_event(4'd1, 8'd40 + i[7:0], 8'd100), "fill voices");
    if (active_voice_count !== 6'd32)
      $fatal(1, "after filling count=%0d", active_voice_count);
    send_event(make_event(4'd1, 8'd72, 8'd100), "steal");
    if (accept_cycles > 6)
      $fatal(1, "stealing stalled event_ready for %0d cycles", accept_cycles);
    if (voice_steal_count !== 16'd1)
      $fatal(1, "steal_count=%0d after the 33rd note", voice_steal_count);
    if (active_voice_count !== 6'd32)
      $fatal(1, "count=%0d after stealing", active_voice_count);
    if (voice_overflow) $fatal(1, "voice_overflow asserted on a steal");

    // 3) The victim must be a voice that is already releasing.  Snapshot the
    //    release mask, steal for note 74, then find which slot took it and check
    //    that slot was releasing before the event.
    send_event(make_event(4'd2, 8'd60, 8'd100), "release 60");
    rel_mask = dut.releasing;
    if (rel_mask == 0) $fatal(1, "no voice is releasing before the second steal");
    send_event(make_event(4'd1, 8'd74, 8'd100), "steal released");
    // The victim keeps its release tail for the bounded steal hold and is only
    // then re-activated with the new note.
    slot74 = -1;
    guard = 0;
    while (slot74 < 0 && guard < 600) begin
      hold_samples(1);
      for (i = 0; i < VOICES; i = i + 1)
        if (dut.note[i] == 8'd74) slot74 = i;
      guard = guard + 1;
    end
    if (slot74 < 0) $fatal(1, "note 74 never reached the bank");
    if (!rel_mask[slot74])
      $fatal(1, "steal took slot %0d which was not releasing", slot74);
    if (voice_steal_count !== 16'd2)
      $fatal(1, "steal_count=%0d after the second steal", voice_steal_count);

    send_event(make_event(4'd5, 8'd0, 8'd0), "all notes off");
    if (event_ready !== 1'b1) $fatal(1, "engine not ready after all-notes-off");

    $display("PASS tb_voice_engine_banked voices=%0d steals=%0d accept_cycles=%0d",
             active_voice_count, voice_steal_count, accept_cycles);
    $finish;
  end

  initial begin : timeout
    #200_000_000;
    $fatal(1, "tb_voice_engine_banked timeout (busy=%b count=%0d)",
           dbg_busy[0], active_voice_count);
  end
endmodule
