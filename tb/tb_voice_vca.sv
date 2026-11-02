`timescale 1ns/1ps
// Testbench for the per-voice VCA.
//
// Until now the per-voice envelope only decided *when* a voice was released and
// freed; it never touched the audio, so every note was a constant-amplitude
// on/off click.  This test pins the new behaviour:
//
//   mixed_sample = saturate(SUM_slot ( osc_sum * (env * gain >> 8) >> 16 ))
//
// with env the 16-bit bank envelope (0 at activation, 49152 in sustain) and gain
// the event's velocity byte.  The consequences that matter are checked here:
//
//   * the first sample after note-on is exactly silent (no click, no blast),
//   * the attack ramps up instead of jumping to full scale,
//   * the sustain level equals the formula exactly,
//   * velocity 0 is exactly silent, not "quiet",
//   * velocity scales the amplitude linearly once the legacy attenuation bucket
//     is the same.
//
// The wavetable source is used (USE_WT_SOURCE=1) so the oscillator value is a
// constant and the only variable left is the VCA itself.
module tb_voice_vca;
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

  // Constant oscillator pair: 2047 each.  With mix 128 the engine attenuates by
  // one bit, so the saw-free osc_sum is 1023 + 1023 in sustain.
  localparam logic signed [15:0] WT_VALUE = 16'sd2047;
  logic signed [15:0] wt_sample_a = WT_VALUE, wt_sample_b = WT_VALUE;
  logic [4:0] wt_rd_slot, wt_wr_slot;
  logic wt_phase_we;
  logic [31:0] wt_phase_a, wt_phase_b;

  integer ce_count, guard, i;
  integer j;
  logic signed [15:0] want;
  logic signed [15:0] p255, p128, p192;
  logic signed [15:0] prev, peak;

  // The 16-bit envelope constants of the engine.
  localparam logic [15:0] SUSTAIN_LEVEL = 16'd49152;
  localparam logic [15:0] ATTACK_STEP = 16'd4096;

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
    .voice_cfg(v2_contract_pkg::V2_VOICE_CFG_DEFAULT),
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

  // Independent copy of the engine's pre-VCA attenuation.  It still runs, so
  // the expected osc_sum must include it; the VCA is the new factor on top.
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

  // The VCA transfer function under test: envelope and velocity become the
  // amplitude, applied after the legacy attenuation and before the saturator.
  function automatic logic signed [15:0] vca(input logic signed [47:0] osc_sum,
                                             input logic [15:0] env,
                                             input logic [7:0] gain);
    logic signed [31:0] env_gain;
    logic signed [63:0] product;
    begin
      env_gain = (env * {8'd0, gain}) >>> 8;
      product = $signed(osc_sum[31:0]) * env_gain;
      vca = product >>> 16;
    end
  endfunction

  // Steady-state expectation for a given velocity, in sustain.
  function automatic logic signed [15:0] expect_sustain(input logic [7:0] vel);
    logic signed [47:0] sum;
    begin
      sum = att({32'd0, WT_VALUE}, 2'd2, vel, 8'd128)
          + att({32'd0, WT_VALUE}, 2'd2, vel, 8'd128);
      expect_sustain = vca(sum, SUSTAIN_LEVEL, vel);
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
      guard = 0;
      while (!event_ready && guard < 200000) begin
        @(posedge clk);
        #1;
        guard = guard + 1;
      end
      if (!event_ready)
        $fatal(1, "%0s: event_ready never came back (scan_busy=%b)", name, dbg_busy[0]);
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
        if (sample_valid) break;
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

  // Play one note and check the attack head, then return its sustain level.
  task automatic play_and_settle(input logic [7:0] vel, input [127:0] name,
                                 output logic signed [15:0] sustain);
    begin
      send_event(make_event(4'd1, 8'd69, vel), name);
      if (active_voice_count != 6'd1)
        $fatal(1, "%0s: expected one active voice, got %0d", name, active_voice_count);

      // The envelope starts at zero in the bank, so the very first sample the
      // VCA sees must be silent.  Anything else is the note-on click.
      wait_sample(name);
      if (mixed_sample !== 16'sd0)
        $fatal(1, "%0s: first sample after note on is %0d, expected exactly 0",
               name, mixed_sample);

      // The attack must ramp.  A constant level here means the envelope is
      // still not reaching the audio path.
      prev = mixed_sample;
      peak = mixed_sample;
      for (i = 0; i < 8; i = i + 1) begin
        wait_sample(name);
        if (mixed_sample < prev)
          $fatal(1, "%0s: attack went down, %0d after %0d", name, mixed_sample, prev);
        prev = mixed_sample;
        if (mixed_sample > peak) peak = mixed_sample;
      end
      if (prev == 16'sd0)
        $fatal(1, "%0s: the first nine samples were all silent; the envelope is not scaling the audio", name);

      // 150 samples is well past 16 attack steps plus the 64 decay steps that
      // reach SUSTAIN_LEVEL.
      for (j = 0; j < 150; j = j + 1) begin
        wait_sample(name);
        if (mixed_sample > peak) peak = mixed_sample;
      end
      sustain = mixed_sample;
    end
  endtask

  initial begin : run_tb
    ce_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");

    // 1. Velocity 255: silent first sample, ramped attack, exact sustain.
    play_and_settle(8'd255, "note on 69 vel 255", p255);
    want = expect_sustain(8'd255);
    if (p255 !== want)
      $fatal(1, "vel 255 sustain %0d, expected %0d ((2046 * 48960) >> 16)",
             p255, want);
    if (peak >= 16'sd32767)
      $fatal(1, "attack head reached %0d; the VCA is passing full scale", peak);
    send_event(make_event(4'd2, 8'd69, 8'd255), "note off after vel 255");
    wait_silence(400000);

    // 2. Velocity 0 must be exactly silent for the whole note, not "quiet":
    //    env * 0 is 0, so the VCA output has to be 0.
    send_event(make_event(4'd1, 8'd69, 8'd0), "note on vel 0");
    if (active_voice_count != 6'd1)
      $fatal(1, "vel 0: expected one active voice, got %0d", active_voice_count);
    for (i = 0; i < 150; i = i + 1) begin
      wait_sample("note on vel 0");
      if (mixed_sample !== 16'sd0)
        $fatal(1, "vel 0 produced %0d at sample %0d; gain 0 must be silent",
               mixed_sample, i);
    end
    send_event(make_event(4'd2, 8'd69, 8'd0), "note off after vel 0");
    wait_silence(400000);

    // 3. Velocity 128: the envelope really is reset on re-activation, and the
    //    level follows the formula in the mid velocity bucket.
    play_and_settle(8'd128, "note on 69 vel 128", p128);
    want = expect_sustain(8'd128);
    if (p128 !== want)
      $fatal(1, "vel 128 sustain %0d, expected %0d ((1022 * 24576) >> 16)",
             p128, want);
    send_event(make_event(4'd2, 8'd69, 8'd128), "note off after vel 128");
    wait_silence(400000);

    // 4. Velocity 192 and 255 share the same legacy attenuation bucket, so the
    //    only difference left is the VCA gain: the levels must be 192:255.
    play_and_settle(8'd192, "note on 69 vel 192", p192);
    want = expect_sustain(8'd192);
    if (p192 !== want)
      $fatal(1, "vel 192 sustain %0d, expected %0d ((2046 * 36864) >> 16)",
             p192, want);
    // Integer truncation in the two right shifts, hence one LSB of slack.  The
    // products are 32-bit because both sides are widened before the multiply.
    if (p192 * 32'sd255 - p255 * 32'sd192 > 32'sd255 ||
        p192 * 32'sd255 - p255 * 32'sd192 < -32'sd255)
      $fatal(1, "vel 192/255 = %0d/%0d is not the 192:255 gain ratio",
             p192, p255);
    send_event(make_event(4'd2, 8'd69, 8'd192), "note off after vel 192");
    wait_silence(400000);

    // 5. Nothing was stolen, and the numbers are the ones a reader can check
    //    by hand from the bank layout.
    if (voice_steal_count !== 16'd0)
      $fatal(1, "four single notes stole %0d voices", voice_steal_count);
    if (voice_overflow !== 1'b0) $fatal(1, "voice_overflow set for single notes");

    $display("PASS vca: vel 255 -> %0d, vel 192 -> %0d, vel 128 -> %0d, vel 0 -> silent, first sample of every note is 0", p255, p192, p128);
    $finish;
  end
endmodule
