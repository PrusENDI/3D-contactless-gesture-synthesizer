`timescale 1ns/1ps
// First testbench for the 32-voice engine.
//
// It exists to answer one question the board raised: when a NOTE_ON arrives with
// all 32 voices busy, the engine starts a serialized victim scan
// (`victim_scan_active`); on hardware that flag stayed high forever and held
// `event_ready` low, so the loop scheduler could never drain an event.
//
// The bench fills the engine one voice at a time, asserts the count after each
// event, and then requires the victim scan to finish within a bounded number of
// cycles.
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

  integer i, guard, ce_count, steal_seen;

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
        $fatal(1, "%0s: event_ready never came back after %0d cycles (scan_busy=%b victim=%b)",
               name, guard, dbg_busy[0], dbg_busy[1]);
      @(posedge clk);
      @(negedge clk);
      event_valid = 1'b0;
      event_data = 96'd0;
      repeat (4) @(posedge clk);
    end
  endtask

  initial begin : run_tb
    ce_count = 0;
    steal_seen = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);

    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");

    send_event(make_event(4'd1, 8'd60, 8'd100), "one note");
    if (active_voice_count !== 6'd1)
      $fatal(1, "after 1 note count=%0d", active_voice_count);

    for (i = 1; i < 8; i = i + 1)
      send_event(make_event(4'd1, 8'd40 + i[7:0], 8'd100), "eight notes");
    if (active_voice_count !== 6'd8)
      $fatal(1, "after 8 notes count=%0d", active_voice_count);

    for (i = 8; i < 32; i = i + 1)
      send_event(make_event(4'd1, 8'd40 + i[7:0], 8'd100), "fill voices");
    if (active_voice_count !== 6'd32)
      $fatal(1, "after 32 notes count=%0d", active_voice_count);
    if (voice_steal_count !== 16'd0)
      $fatal(1, "stole %0d voices before the bank was full", voice_steal_count);

    // The 33rd note has no free voice: this is the state that hung on hardware.
    fork
      send_event(make_event(4'd1, 8'd72, 8'd100), "steal");
    join
    guard = 0;
    while (dbg_busy[1] && guard < 200000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (dbg_busy[1])
      $fatal(1, "victim_scan_active never fell (scan_busy=%b) - the board hang reproduces in simulation",
             dbg_busy[0]);
    if (voice_steal_count !== 16'd1)
      $fatal(1, "steal_count=%0d after the 33rd note", voice_steal_count);
    if (active_voice_count !== 6'd32)
      $fatal(1, "count=%0d after stealing", active_voice_count);
    if (voice_overflow) $fatal(1, "voice_overflow asserted on a steal");

    send_event(make_event(4'd2, 8'd60, 8'd100), "note off");
    send_event(make_event(4'd5, 8'd0, 8'd0), "all notes off");
    if (event_ready !== 1'b1) $fatal(1, "engine not ready after all-notes-off");

    $display("PASS tb_voice_engine_banked voices=%0d steals=%0d",
             active_voice_count, voice_steal_count);
    $finish;
  end

  initial begin : timeout
    #50_000_000;
    $fatal(1, "tb_voice_engine_banked timeout (busy=%b victim=%b count=%0d)",
           dbg_busy[0], dbg_busy[1], active_voice_count);
  end
endmodule
