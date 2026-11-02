`timescale 1ns/1ps
// Testbench for the per-voice detune.
//
// Each voice runs two oscillators.  Until now they were identical: same step,
// same target, same start phase, so the pair summed to exactly twice one
// oscillator and the voice sounded thin.  This test pins the new activation
// word instead:
//
//   phase_a = 0            phase_b = 0x8000_0000  (half a cycle apart)
//   step_a  = base         step_b  = base - (base >>> shift)
//   target_a = base        target_b = base - (base >>> shift)
//
// with shift = 11 - velocity[7:6], so a harder note detunes wider:
// 0.05% at velocity 0..63, 0.39% at 192..255.
//
// Activation always goes through the one-entry mailbox: the engine parks the
// note at acceptance and writes the bank on the following cycle, so the bank
// write data comes from registers instead of from the event bus through the
// note ROM.  That is why this test watches pending_activate for both a free
// slot and a stolen one.
//
// The detune is only useful if it survives the scan, so the first writeback of
// the free voice is checked as well: after one sample the bank must hold
// phase_a = base and phase_b = 0x8000_0000 + base - detune, i.e. the two
// accumulators really are running at different rates from a half-cycle offset.
module tb_voice_detune;
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

  // The saw path: this test is about the oscillator increments, so the
  // wavetable source is off and the pair is driven by phase alone.
  logic signed [15:0] wt_sample_a = 16'sd0, wt_sample_b = 16'sd0;
  logic [4:0] wt_rd_slot, wt_wr_slot;
  logic wt_phase_we;
  logic [31:0] wt_phase_a, wt_phase_b;

  integer ce_count, guard, i, accept_cycles, before_steal;
  logic [31:0] rom_step_q;
  logic [7:0] last_velocity;

  // Activation writes: the mailbox write is the only one now.
  logic [255:0] act_word;
  integer act_count = 0;
  // First scan writeback of the free voice: proves the preset reached the
  // phase accumulator.
  logic [255:0] first_wb_word;
  logic have_wb = 1'b0;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  always @(posedge clk) begin
    ce_count <= ce_count + 1;
    sample_ce <= (ce_count % 300) == 0;
  end

  v2_voice_engine_banked #(.VOICES(VOICES), .USE_GOWIN_RAM(1),
                           .USE_WT_SOURCE(0)) dut (
    .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
    .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
    .voice_cfg(v2_contract_pkg::V2_VOICE_CFG_DEFAULT),
    .vibrato_hz_q8_8(16'd0), .vibrato_cents_q8_8(16'd0),
    .mixed_sample(mixed_sample), .sample_valid(sample_valid),
    .active_bitmap(active_bitmap), .voice_overflow(voice_overflow),
    .voice_steal_count(voice_steal_count), .revoice_count(revoice_count),
    .active_voice_count(active_voice_count), .dbg_busy(dbg_busy),
    .vibrato_phase(vibrato_phase), .vibrato_delta_cents(vibrato_delta_cents),
    .wt_source_sel(1'b0),
    .wt_sample_a(wt_sample_a), .wt_sample_b(wt_sample_b),
    .wt_rd_slot(wt_rd_slot), .wt_wr_slot(wt_wr_slot), .wt_phase_we(wt_phase_we),
    .wt_phase_a(wt_phase_a), .wt_phase_b(wt_phase_b));

  // The bank write mux has two owners; sample the word in the cycle each one is
  // active, before the write is registered.
  always @(posedge clk) begin
    if (dut.pending_activate) begin
      act_word = dut.bank_wr_data;
      act_count = act_count + 1;
    end
    if (dut.calc_valid && dut.calc_active && (dut.calc_slot == 5'd0) && !have_wb) begin
      first_wb_word = dut.bank_wr_data;
      have_wb = 1'b1;
    end
  end

  // The shift the RTL must use: the top two bits of the velocity byte.
  function automatic integer detune_shift(input logic [7:0] vel);
    detune_shift = 11 - {30'd0, vel[7:6]};
  endfunction

  function automatic logic [31:0] detune_of(input logic [31:0] base, input logic [7:0] vel);
    detune_of = base >> detune_shift(vel);
  endfunction

  function automatic [95:0] make_event(input [3:0] etype, input [7:0] note, input [7:0] vel);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = etype;
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
      // The note ROM is addressed by the event bus, so the increment is only
      // visible while the event is held.
      #1;
      if (e[94:91] == 4'd1) begin
        rom_step_q = dut.rom_step;
        last_velocity = e[63:56];
      end
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

  task automatic wait_silence(input integer limit);
    begin
      guard = 0;
      while (active_voice_count != 6'd0 && guard < limit) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (active_voice_count != 6'd0)
        $fatal(1, "voice never released (%0d left after %0d cycles)", active_voice_count, guard);
    end
  endtask

  task automatic wait_activation(input integer prior, input integer limit,
                                 input [127:0] name);
    begin
      guard = 0;
      while ((act_count == prior) && guard < limit) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (act_count != prior + 1)
        $fatal(1, "%0s: %0d activation writes appeared instead of 1 after %0d cycles",
               name, act_count - prior, guard);
    end
  endtask

  // Check every field of an activation word against the velocity it was
  // played with.
  task automatic check_word(input logic [255:0] w, input logic [7:0] vel,
                            input logic [31:0] base, input [127:0] name);
    logic [31:0] det;
    begin
      det = detune_of(base, vel);
      if (w[31:0] !== 32'd0)
        $fatal(1, "%0s: phase_a 0x%08h, expected 0", name, w[31:0]);
      if (w[63:32] !== 32'h8000_0000)
        $fatal(1, "%0s: phase_b 0x%08h, expected 0x80000000 (half a cycle apart)",
               name, w[63:32]);
      if (w[95:64] !== base)
        $fatal(1, "%0s: step_a 0x%08h, expected 0x%08h", name, w[95:64], base);
      if (det == 32'd0)
        $fatal(1, "%0s: the detune is zero for base 0x%08h, velocity %0d", name, base, vel);
      if (w[127:96] !== (base - det))
        $fatal(1, "%0s: step_b 0x%08h, expected 0x%08h (base - base >>> %0d)",
               name, w[127:96], base - det, detune_shift(vel));
      if (w[159:128] !== base)
        $fatal(1, "%0s: target_a 0x%08h, expected 0x%08h", name, w[159:128], base);
      // target_b must carry the same offset, otherwise bounded_step glides the
      // detuned step back to the base and the detune disappears within a few
      // hundred samples.
      if (w[191:160] !== (base - det))
        $fatal(1, "%0s: target_b 0x%08h, expected 0x%08h; the glide target would cancel the detune",
               name, w[191:160], base - det);
    end
  endtask

  initial begin : run_tb
    ce_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");

    // 1. A hard note: 0.39% detune, half a cycle of phase offset.
    send_event(make_event(4'd1, 8'd69, 8'd255), "note on 69 vel 255");
    wait_activation(0, 20000, "note on 69 vel 255");
    check_word(act_word, 8'd255, rom_step_q, "note on vel 255");

    // 2. The first scan writeback proves the preset reached the accumulator:
    //    phase_a = base, phase_b = 0x8000_0000 + base - detune.
    guard = 0;
    while (!have_wb && guard < 20000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (!have_wb) $fatal(1, "no writeback for slot 0 within %0d cycles", guard);
    if (first_wb_word[31:0] !== rom_step_q)
      $fatal(1, "after one sample phase_a is 0x%08h, expected one step 0x%08h",
             first_wb_word[31:0], rom_step_q);
    // Both accumulators advanced once from their preset, at different rates.
    if (first_wb_word[63:32] !== (32'h8000_0000 + rom_step_q -
                                  detune_of(rom_step_q, 8'd255)))
      $fatal(1, "after one sample phase_b is 0x%08h, expected 0x%08h",
             first_wb_word[63:32],
             32'h8000_0000 + rom_step_q - detune_of(rom_step_q, 8'd255));
    // The two steps must differ, otherwise the voice is still two identical
    // oscillators and there is no beating.
    if (first_wb_word[95:64] === first_wb_word[127:96])
      $fatal(1, "both oscillators run at 0x%08h; the detune vanished",
             first_wb_word[95:64]);

    send_event(make_event(4'd2, 8'd69, 8'd255), "note off 69");
    wait_silence(400000);

    // 3. A soft note detunes four times less: velocity 64..127 uses shift 10.
    have_wb = 1'b0;
    send_event(make_event(4'd1, 8'd69, 8'd64), "note on 69 vel 64");
    wait_activation(1, 20000, "note on 69 vel 64");
    check_word(act_word, 8'd64, rom_step_q, "note on vel 64");
    // A harder note must detune wider.  The relation is exact in the shift and
    // only approximate in the value, because base >> 8 and base >> 10 differ by
    // the truncated low bits (38447 * 4 = 153788, not 153791).
    if (detune_shift(8'd255) !== 8 || detune_shift(8'd64) !== 10)
      $fatal(1, "detune shifts are %0d and %0d, expected 8 and 10",
             detune_shift(8'd255), detune_shift(8'd64));
    if (detune_of(rom_step_q, 8'd255) < 3 * detune_of(rom_step_q, 8'd64) ||
        detune_of(rom_step_q, 8'd255) > 5 * detune_of(rom_step_q, 8'd64))
      $fatal(1, "velocity 255 detune %0d is not about four times velocity 64 (%0d)",
             detune_of(rom_step_q, 8'd255), detune_of(rom_step_q, 8'd64));

    send_event(make_event(4'd2, 8'd69, 8'd64), "note off 69");
    wait_silence(400000);

    // 4. The steal path writes the same word.  Fill all 32 slots, then ask for
    //    a 33rd note: the engine has to release a victim and activate into its
    //    slot.  Note 72 is one of the entries the note ROM actually holds, so
    //    the base increment is not zero.
    before_steal = act_count;
    for (i = 0; i < VOICES; i = i + 1)
      send_event(make_event(4'd1, 8'd36 + i[7:0], 8'd255), "note on to fill the bank");
    if (active_voice_count !== 6'd32)
      $fatal(1, "%0d voices active, expected 32", active_voice_count);
    if (act_count !== before_steal + VOICES)
      $fatal(1, "%0d activation writes for 32 notes", act_count - before_steal);
    before_steal = act_count;
    send_event(make_event(4'd1, 8'd72, 8'd100), "note on 72 over 32 voices");
    if (last_velocity !== 8'd100) $fatal(1, "the tb lost the velocity of the 33rd note");
    if (rom_step_q == 32'd0) $fatal(1, "note 72 has no increment in the ROM");
    // The victim has to finish its bounded release first, so this takes a few
    // hundred samples rather than one cycle.
    wait_activation(before_steal, 500000, "33rd note (stolen slot)");
    if (voice_steal_count != 16'd1)
      $fatal(1, "the 33rd note reported %0d steals", voice_steal_count);
    check_word(act_word, 8'd100, rom_step_q, "33rd note (stolen slot)");

    if (voice_overflow !== 1'b0) $fatal(1, "voice_overflow set with a stealable bank");

    $display("PASS detune: vel 255 shift %0d det 0x%08h, vel 64 shift %0d det 0x%08h, steal path same word, phase_b preset survives the first sample",
             detune_shift(8'd255), detune_of(rom_step_q, 8'd255),
             detune_shift(8'd64), detune_of(rom_step_q, 8'd64));
    $finish;
  end

  initial begin : timeout
    #100_000_000;
    $fatal(1, "tb_voice_detune timeout (active=%0d steals=%0d)", active_voice_count,
           voice_steal_count);
  end
endmodule
