`timescale 1ns/1ps
// Testbench for the wavetable oscillator source inside the 32-voice engine.
//
// With USE_WT_SOURCE=1 the engine must stop looking at its own saw phases: the
// value it feeds into the envelope/velocity/mix attenuation is the sample pair
// the wavetable engine produced, so the output only depends on (wt_sample_a,
// wt_sample_b, stage, velocity, mix) and not on the note's pitch.
//
// The scan still owns the phases, so the same test also pins the phase mirror
// that feeds the buffers: exactly one phase write per active voice per sample,
// aimed at that voice's slot, carrying the next phase.
module tb_voice_wt_source;
  localparam integer VOICES = 32;
  localparam logic [1:0] ENV_ATTACK = 2'd0;

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

  // Wavetable side: the tb plays the role of the table engine's sample buffer.
  logic signed [15:0] wt_sample_a = 16'sd1000, wt_sample_b = 16'sd0;
  logic [4:0] wt_rd_slot, wt_wr_slot;
  logic wt_phase_we;
  logic [31:0] wt_phase_a, wt_phase_b;

  integer ce_count, guard, accept_cycles;
  logic signed [15:0] want;
  logic [31:0] rom_step_q;
  // Phase-write observations, one sample interval at a time.
  integer we_cur = 0, we_per_sample = -1, we_slot, we_count_total = 0;
  logic [31:0] we_phase_a;

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

  // Independent copy of the attenuation: stage, velocity and mix each remove
  // bits from the sample before it reaches the mix accumulator.
  function automatic logic signed [47:0] att(input logic signed [47:0] raw,
                                             input logic [1:0] stage,
                                             input logic [7:0] velocity,
                                             input logic [7:0] mix);
    integer a;
    begin
      a = 0;
      if (stage == 2'd0) a = a + 2;        // ENV_ATTACK
      if (stage == 2'd1) a = a + 1;        // ENV_DECAY
      if (stage == 2'd3) a = a + 3;        // ENV_RELEASE
      if (velocity < 8'd64) a = a + 3;
      else if (velocity < 8'd128) a = a + 2;
      else if (velocity < 8'd192) a = a + 1;
      if (mix < 8'd64) a = a + 3;
      else if (mix < 8'd128) a = a + 2;
      else if (mix < 8'd192) a = a + 1;
      att = raw >>> a;
    end
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
      // visible while the event is held.  Wait for the combinational path to
      // settle before sampling it.
      #1;
      if (e[94:91] == 4'd1) rom_step_q = dut.rom_step;
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

  task automatic wait_sample(input [127:0] what);
    begin
      guard = 0;
      while (1) begin
        @(negedge clk);
        if (sample_valid) begin
          @(negedge clk);      // let the phase-write monitor finish this sample
          break;
        end
        guard = guard + 1;
        if (guard > 20000) $fatal(1, "%0s: no sample_valid within %0d cycles", what, guard);
      end
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

  // Count the phase writes of one sample and remember the last one.
  always @(negedge clk) begin
    if (wt_phase_we) begin
      we_cur = we_cur + 1;
      we_slot = wt_wr_slot;
      we_phase_a = wt_phase_a;
      we_count_total = we_count_total + 1;
    end
    if (sample_valid) begin
      we_per_sample = we_cur;
      we_cur = 0;
    end
  end

  initial begin : run_tb
    ce_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");
    if (wt_phase_we !== 1'b0) $fatal(1, "phase write is high before any scan");

    // 1. A note takes its sample from the wavetable pair, not from the saw.
    //    1000 with attack (+2), velocity 127 (+2) and mix 128 (+1) is 1000 >>> 5.
    wt_sample_a = 16'sd1000; wt_sample_b = 16'sd0;
    we_count_total = 0;
    send_event(make_event(4'd1, 8'd69, 8'd127), "note on 69");
    wait_sample("sample after note on");
    if (active_voice_count != 6'd1)
      $fatal(1, "expected one active voice, got %0d", active_voice_count);
    want = att(48'sd1000, ENV_ATTACK, 8'd127, 8'd128);
    if (mixed_sample !== want)
      $fatal(1, "sample %0d expected %0d (wt 1000 at attack/v127/mix128)",
             mixed_sample, want);

    // 2. The phase mirror published this voice's next phase for that sample.
    //    The interval also contains the activation write (phase zero), so the
    //    last write is the scan write: phase 0 + one step.
    if (we_phase_a !== rom_step_q)
      $fatal(1, "phase mirror wrote 0x%08h, expected one step 0x%08h",
             we_phase_a, rom_step_q);
    // From the second sample on there is exactly one phase write per active
    // voice per sample, aimed at that voice's slot.
    we_phase_a = 32'hDEAD_BEEF;
    wait_sample("second sample");
    if (we_per_sample != 1)
      $fatal(1, "%0d phase writes for one voice in one sample", we_per_sample);
    if (we_slot != 0) $fatal(1, "phase mirror wrote slot %0d, expected 0", we_slot);
    if (we_phase_a !== (rom_step_q << 1))
      $fatal(1, "second sample phase 0x%08h, expected two steps 0x%08h",
             we_phase_a, (rom_step_q << 1));

    // 3. A negative sample keeps its sign: -1000 >>> 5 is -32, not 2055.
    wt_sample_a = -16'sd1000;
    wait_sample("sample with a negative wavetable value");
    want = att(-48'sd1000, ENV_ATTACK, 8'd127, 8'd128);
    if (mixed_sample !== want)
      $fatal(1, "negative sample %0d expected %0d", mixed_sample, want);

    // 4. Silence in the buffer means silence out: the saw must not leak through.
    wt_sample_a = 16'sd0; wt_sample_b = 16'sd0;
    wait_sample("sample with an empty buffer");
    if (mixed_sample !== 16'sd0)
      $fatal(1, "empty wavetable buffer produced %0d", mixed_sample);
    wt_sample_a = 16'sd1000;

    // 5. Pitch no longer matters: same pair, note an octave and a fifth higher
    //    after the first voice has released, same output.
    send_event(make_event(4'd2, 8'd69, 8'd127), "note off 69");
    wait_silence(400000);
    send_event(make_event(4'd1, 8'd84, 8'd127), "note on 84");
    wait_sample("sample after the second note");
    if (active_voice_count != 6'd1)
      $fatal(1, "expected one active voice for the second note, got %0d",
             active_voice_count);
    want = att(48'sd1000, ENV_ATTACK, 8'd127, 8'd128);
    if (mixed_sample !== want)
      $fatal(1, "note 84 sample %0d expected %0d; the output still follows the pitch",
             mixed_sample, want);

    // 6. Nothing overflowed or was stolen for two single notes.
    if (voice_steal_count !== 16'd0)
      $fatal(1, "single notes stole %0d voices", voice_steal_count);
    if (voice_overflow !== 1'b0) $fatal(1, "voice_overflow set for single notes");

    $display("PASS wavetable source: 1000 -> %0d, -1000 -> -32, one phase write per voice per sample",
             att(48'sd1000, ENV_ATTACK, 8'd127, 8'd128));
    $finish;
  end
endmodule
