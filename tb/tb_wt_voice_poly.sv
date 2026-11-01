`timescale 1ns/1ps
// Worst-case load test for the wavetable voice path.
//
// 32 voices, each running two oscillators that read a full-scale wavetable
// sample, with the velocity and both per-voice mixes at maximum (255: no extra
// attenuation, the loudest a voice can be).  At sustain the only scaling left is
// WT_VOICE_SHIFT = 6, so the expected peak is 32 * 2 * (32767 >>> 6) = 32704 and
// the negative peak is 32 * 2 * (-32768 >>> 6) = -32768: full scale and still
// inside int16, which is what the default shift buys.
module tb_wt_voice_poly;
  localparam integer VOICES = 32;
  // The table engine has already applied WT_VOICE_SHIFT = 6 to these, so they
  // are the largest samples the voice engine can ever see (32767 >>> 6, and the
  // most negative value, -32768 >>> 6).
  localparam logic signed [15:0] PEAK_POS = 16'sd511;
  localparam logic signed [15:0] PEAK_NEG = -16'sd512;

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

  logic signed [15:0] wt_sample_a = PEAK_POS, wt_sample_b = PEAK_POS;
  logic [4:0] wt_rd_slot, wt_wr_slot;
  logic wt_phase_we;
  logic [31:0] wt_phase_a, wt_phase_b;

  integer ce_count, guard, i, accept_cycles;
  integer max_seen = -40000, min_seen = 40000;
  integer pos_peak = 0, neg_peak = 0;
  integer samples_seen;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  always @(posedge clk) begin
    ce_count <= ce_count + 1;
    sample_ce <= (ce_count % 300) == 0;
  end

  v2_voice_engine_banked #(.VOICES(VOICES), .USE_GOWIN_RAM(1),
                           .USE_WT_SOURCE(1)) dut (
    .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
    .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
    .vibrato_hz_q8_8(16'd0), .vibrato_cents_q8_8(16'd0),
    .mixed_sample(mixed_sample), .sample_valid(sample_valid),
    .active_bitmap(active_bitmap), .voice_overflow(voice_overflow),
    .voice_steal_count(voice_steal_count), .revoice_count(revoice_count),
    .active_voice_count(active_voice_count), .dbg_busy(dbg_busy),
    .vibrato_phase(vibrato_phase), .vibrato_delta_cents(vibrato_delta_cents),
    .wt_source_sel(1'b1),
    .wt_sample_a(wt_sample_a), .wt_sample_b(wt_sample_b),
    .wt_rd_slot(wt_rd_slot), .wt_wr_slot(wt_wr_slot), .wt_phase_we(wt_phase_we),
    .wt_phase_a(wt_phase_a), .wt_phase_b(wt_phase_b));

  // Velocity 255 and mix 255 on both oscillators: the loudest a voice can be.
  function automatic [95:0] make_note_on(input [7:0] note);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = 4'd1;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = 8'd255;
      e[39:24] = 16'hFFFF;
      make_note_on = e;
    end
  endfunction

  function automatic [95:0] make_note_off(input [7:0] note);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = 4'd2;
      e[79:72] = 8'd4;
      e[71:64] = note;
      make_note_off = e;
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
        $fatal(1, "%0s: event_ready never came back (scan_busy=%b)", name, dbg_busy[0]);
      accept_cycles = guard;
      @(posedge clk);
      @(negedge clk);
      event_valid = 1'b0;
      event_data = 96'd0;
      repeat (4) @(posedge clk);
    end
  endtask

  // Watch the mixed sample of every produced audio frame.
  always @(negedge clk) begin
    if (sample_valid) begin
      if ($signed(mixed_sample) > max_seen) max_seen = $signed(mixed_sample);
      if ($signed(mixed_sample) < min_seen) min_seen = $signed(mixed_sample);
      samples_seen = samples_seen + 1;
    end
  end

  task automatic hold_samples(input integer n);
    begin
      repeat (n * 300) @(posedge clk);
    end
  endtask

  initial begin : run_tb
    ce_count = 0;
    samples_seen = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");

    // Two octaves of notes so the phases are all different; the amplitude does
    // not depend on the pitch because the sample pair is constant.
    for (i = 0; i < VOICES; i = i + 1)
      send_event(make_note_on(8'd36 + i[7:0]), "note on");
    if (active_voice_count !== 6'd32)
      $fatal(1, "%0d voices active after 32 note-ons", active_voice_count);
    if (voice_overflow !== 1'b0) $fatal(1, "voice_overflow set with exactly 32 notes");

    // Let the envelopes reach sustain (attack 16 + decay 64 samples), then look
    // at a window of audio.
    hold_samples(120);
    max_seen = -40000; min_seen = 40000; samples_seen = 0;
    hold_samples(40);
    if (samples_seen < 20) $fatal(1, "only %0d audio frames in the window", samples_seen);
    if (max_seen !== 32704)
      $fatal(1, "positive peak %0d, expected 32704 (32 voices x 2 oscillators)", max_seen);
    if (max_seen > 32767 || min_seen < -32768)
      $fatal(1, "the mix clipped: max %0d min %0d", max_seen, min_seen);
    pos_peak = max_seen;
    if (voice_steal_count !== 16'd0) $fatal(1, "32 notes stole %0d voices", voice_steal_count);

    // Negative full-scale samples must land on -32768, not wrap.
    wt_sample_a = PEAK_NEG; wt_sample_b = PEAK_NEG;
    hold_samples(2);
    max_seen = -40000; min_seen = 40000; samples_seen = 0;
    hold_samples(40);
    if (min_seen !== -32768)
      $fatal(1, "negative peak %0d, expected -32768", min_seen);
    if (max_seen > 32767) $fatal(1, "positive side wrapped to %0d", max_seen);
    neg_peak = min_seen;
    wt_sample_a = PEAK_POS; wt_sample_b = PEAK_POS;

    // Release one voice at a time and check the count follows exactly.
    for (i = 0; i < VOICES; i = i + 1) begin
      send_event(make_note_off(8'd36 + i[7:0]), "note off");
      guard = 0;
      while (active_voice_count > (VOICES - 1 - i) && guard < 120000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (active_voice_count !== (VOICES - 1 - i))
        $fatal(1, "%0d voices active after %0d note-offs, expected %0d", active_voice_count,
               i + 1, VOICES - 1 - i);
    end
    hold_samples(2);
    if (mixed_sample !== 16'sd0)
      $fatal(1, "silent engine still produced %0d", mixed_sample);

    $display("PASS 32 voices: peak %0d / %0d (no clip), all released one by one",
             pos_peak, neg_peak);
    $finish;
  end

  initial begin : timeout
    #200_000_000;
    $fatal(1, "tb_wt_voice_poly timeout (active=%0d)", active_voice_count);
  end
endmodule
