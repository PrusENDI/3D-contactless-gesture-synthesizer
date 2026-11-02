`timescale 1ns/1ps
// Testbench for the P2b voice parameter pack (spec 11.3).
//
// The engine takes one packed bus, voice_cfg, instead of four envelope
// localparams and three behaviour constants:
//
//   [15:0] attack_step   [31:16] decay_step  [47:32] sustain_level
//   [63:48] release_step [65:64] velocity_shift [67:66] detune_shift
//   [83:68] glide_rate   [95:84] reserved
//
// V2_VOICE_CFG_DEFAULT is the word the design has always been built with, so
// every number below is checked twice: once at the default (nothing may move
// bit for bit) and once with the field written to a contrasting value.
//
// The wavetable source is used (USE_WT_SOURCE=1) so the oscillator pair is a
// constant and the only variable left is the VCA and the increments.
//
// Measurements are taken from the design's own state: the slot-0 bank writeback
// (the word the bank stores for the next sample) and the bank word the
// activation mailbox writes.  No number is re-derived from a second model except
// the VCA transfer function, which is copied verbatim from the RTL.
module tb_voice_cfg;
  import v2_contract_pkg::*;
  localparam integer VOICES = 32;

  logic clk = 0, rst_n = 0, sample_ce = 0;
  logic event_valid = 0;
  logic event_ready;
  logic [95:0] event_data = 0;
  logic [95:0] voice_cfg = V2_VOICE_CFG_DEFAULT;
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

  integer ce_count = 0;
  // 80 clocks per sample: the scan plus the bank pipeline is about 36 clocks, so
  // the engine sees a full sample boundary with a factor of two to spare.  It is
  // deliberately short because one case has to watch 32000 samples.
  integer ce_period = 80;
  integer guard, i, j, act_before;
  integer n1, n2, steps1, steps2;
  logic reached;
  logic signed [15:0] first_level;

  // Slot-0 writeback of the bank word, captured in the cycle the write is
  // registered (the same view tb_voice_detune uses).
  logic [15:0] wb_env;
  logic [31:0] wb_step_a, wb_target_a;
  logic [255:0] act_word;
  integer act_count = 0;
  // Glide staging, set just before each REVOICE.
  logic [31:0] base_step, target_step;

  logic signed [15:0] lev_a, lev_b, lev_c, lev_d;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  always @(posedge clk) begin
    ce_count <= ce_count + 1;
    sample_ce <= (ce_count % ce_period) == 0;
  end

  v2_voice_engine_banked #(.VOICES(VOICES), .USE_GOWIN_RAM(1),
                           .USE_WT_SOURCE(1)) dut (
    .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
    .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
    .voice_cfg(voice_cfg),
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

  always @(posedge clk) begin
    if (dut.calc_valid && dut.calc_active && (dut.calc_slot == 5'd0)) begin
      wb_env      = dut.bank_wr_data[207:192];
      wb_step_a   = dut.bank_wr_data[95:64];
      wb_target_a = dut.bank_wr_data[159:128];
    end
    if (dut.pending_activate) begin
      act_word  = dut.bank_wr_data;
      act_count = act_count + 1;
    end
  end

  // Independent copy of the engine's pre-VCA attenuation (unchanged by P2b).
  function automatic logic signed [47:0] att(input logic signed [47:0] raw,
                                             input logic [1:0] stage,
                                             input logic [7:0] gain,
                                             input logic [7:0] mix);
    integer a;
    begin
      a = 0;
      if (stage == 2'd0) a = a + 2;        // ENV_ATTACK
      if (stage == 2'd1) a = a + 1;        // ENV_DECAY
      if (stage == 2'd3) a = a + 3;        // ENV_RELEASE
      if (gain < 8'd64) a = a + 3;
      else if (gain < 8'd128) a = a + 2;
      else if (gain < 8'd192) a = a + 1;
      if (mix < 8'd64) a = a + 3;
      else if (mix < 8'd128) a = a + 2;
      else if (mix < 8'd192) a = a + 1;
      att = raw >>> a;
    end
  endfunction

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

  // Steady-state level for a stored gain byte, in sustain, mix 128.
  function automatic logic signed [15:0] expect_sustain(input logic [7:0] gain);
    logic signed [47:0] sum;
    begin
      sum = att({32'd0, WT_VALUE}, 2'd2, gain, 8'd128)
          + att({32'd0, WT_VALUE}, 2'd2, gain, 8'd128);
      expect_sustain = vca(sum, 16'd49152, gain);
    end
  endfunction

  function automatic [95:0] make_event(input [3:0] etype, input [7:0] note,
                                       input [7:0] vel, input signed [15:0] pitch);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = etype;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = vel;
      e[55:40] = pitch;
      make_event = e;
    end
  endfunction

  // "release" is a SystemVerilog keyword, hence rel_step.
  task automatic set_cfg(input logic [15:0] att_step, input logic [15:0] dec_step,
                         input logic [15:0] sus_level, input logic [15:0] rel_step,
                         input logic [1:0] vshift, input logic [1:0] dshift,
                         input logic [15:0] glide);
    begin
      voice_cfg = {12'd0, glide, dshift, vshift, rel_step, sus_level, dec_step, att_step};
    end
  endtask

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

  task automatic wait_silence(input integer limit, input [127:0] name);
    begin
      guard = 0;
      while (active_voice_count != 6'd0 && guard < limit) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (active_voice_count != 6'd0)
        $fatal(1, "%0s: voice never released (%0d left after %0d cycles)",
               name, active_voice_count, guard);
    end
  endtask

  // Number of samples from the first sample after note-on to the sample whose
  // bank write reaches the attack top (0xFFFF), plus the level of that first
  // sample so the note-on click is still checked.  This is the "samples to the
  // attack peak" of the plan.
  task automatic samples_to_env_top(input integer limit, input [127:0] name,
                                    output integer n, output logic hit,
                                    output logic signed [15:0] first);
    begin
      n = 0;
      hit = 1'b0;
      first = 16'sd0;
      while ((n < limit) && !hit) begin
        wait_sample(name);
        n = n + 1;
        if (n == 1) first = mixed_sample;
        if (wb_env == 16'hFFFF) hit = 1'b1;
      end
    end
  endtask

  // Play one note, check the silent first sample, then let it settle and return
  // the sustained level.
  task automatic play_and_settle(input logic [7:0] note, input logic [7:0] vel,
                                 input [127:0] name, output logic signed [15:0] level);
    begin
      send_event(make_event(4'd1, note, vel, 16'sd0), name);
      if (active_voice_count != 6'd1)
        $fatal(1, "%0s: expected one active voice, got %0d", name, active_voice_count);
      wait_sample(name);
      if (mixed_sample !== 16'sd0)
        $fatal(1, "%0s: first sample after note on is %0d, expected exactly 0",
               name, mixed_sample);
      // 16 attack steps + 63 decay steps + margin.
      for (j = 0; j < 150; j = j + 1) wait_sample(name);
      level = mixed_sample;
    end
  endtask

  // Wait for the activation the mailbox writes for the note just sent and check
  // that exactly one appeared.
  task automatic wait_activation(input integer prior, input [127:0] name);
    begin
      guard = 0;
      while ((act_count == prior) && guard < 20000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (act_count != prior + 1)
        $fatal(1, "%0s: %0d activation writes instead of 1", name, act_count - prior);
    end
  endtask

  // Number of samples from the first step change to the sample that reaches the
  // glide target.  Counting from the first change, not from the REVOICE, keeps
  // the one-sample mailbox latency out of the ratio.
  task automatic glide_length(input [31:0] base, input [31:0] target,
                              input [127:0] name, output integer steps);
    integer n;
    begin
      steps = 0;
      n = 0;
      while ((n < 400) && (steps == 0)) begin
        wait_sample(name);
        n = n + 1;
        if (wb_step_a != base) steps = 1;
      end
      if (steps == 0) $fatal(1, "%0s: the step never left the base 0x%08h", name, base);
      while ((n < 800) && (wb_step_a != target)) begin
        wait_sample(name);
        n = n + 1;
        steps = steps + 1;
      end
      if (wb_step_a !== target)
        $fatal(1, "%0s: the step stopped at 0x%08h, expected 0x%08h",
               name, wb_step_a, target);
    end
  endtask

  initial begin : run_tb
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    if (event_ready !== 1'b1) $fatal(1, "idle engine is not ready");

    // ================= 1. The default must not move =====================
    // V2_VOICE_CFG_DEFAULT is the word the engine was compiled with before this
    // round: attack 4096 reaches the top in 16 samples and the sustain level is
    // the exact number tb_voice_vca asserts (1528 for velocity 255).
    voice_cfg = V2_VOICE_CFG_DEFAULT;
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "default note on 69 vel 255");
    if (active_voice_count != 6'd1)
      $fatal(1, "default: expected one active voice, got %0d", active_voice_count);
    samples_to_env_top(400, "default attack", n1, reached, first_level);
    if (!reached) $fatal(1, "default: the envelope never reached the attack top");
    if (first_level !== 16'sd0)
      $fatal(1, "default: first sample after note on is %0d, expected 0", first_level);
    if (n1 != 16)
      $fatal(1, "default: %0d samples to the attack top, expected 16 (4096 * 16 > 65535)", n1);
    for (j = 0; j < 150; j = j + 1) wait_sample("default sustain");
    if (mixed_sample !== expect_sustain(8'd255) || mixed_sample !== 16'sd1528)
      $fatal(1, "default: sustain %0d, expected 1528", mixed_sample);
    $display("PASS default: 16 samples to the attack top, sustain 1528 for velocity 255");
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "default note off");
    wait_silence(400000, "default note off");

    // ================= 2. Attack is a step size ========================
    // attack_step is the increment per sample, so the largest value reaches the
    // top in one sample and the smallest needs 65535 of them: two orders of
    // magnitude apart, which is the whole point of the register.
    set_cfg(16'd65535, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "attack 65535 note on");
    samples_to_env_top(400, "attack 65535", n1, reached, first_level);
    if (!reached) $fatal(1, "attack 65535: the envelope never reached the attack top");
    if (n1 > 2)
      $fatal(1, "attack 65535: %0d samples to the attack top, expected at most 2", n1);
    wait_sample("attack 65535 audio");
    if (mixed_sample <= 16'sd0)
      $fatal(1, "attack 65535: the attack never reached the audio (%0d)", mixed_sample);
    $display("PASS attack 65535: %0d sample to the attack top, level %0d on the next one",
             n1, mixed_sample);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "attack 65535 note off");
    wait_silence(400000, "attack 65535 note off");

    set_cfg(16'd1, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "attack 1 note on");
    for (j = 0; j < 32000; j = j + 1) wait_sample("attack 1");
    if (wb_env == 16'hFFFF)
      $fatal(1, "attack 1: the envelope reached the top within 32001 samples");
    if (wb_env < 16'd31990 || wb_env > 16'd32010)
      $fatal(1, "attack 1: the envelope is %0d after 32000 samples, expected 32000", wb_env);
    if (mixed_sample <= 16'sd0 || mixed_sample >= 16'sd1528)
      $fatal(1, "attack 1: the level is %0d, expected a partly open attack", mixed_sample);
    $display("PASS attack 1: still below the attack top after 32000 samples (env %0d, level %0d)",
             wb_env, mixed_sample);
    // Clean up quickly: the release step is what makes the note end.
    set_cfg(16'd1, 16'd256, 16'd49152, 16'd65535, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "attack 1 note off");
    wait_silence(400000, "attack 1 note off");

    // ================= 3. Release is a step size too ===================
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd65535, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "release 65535 note on");
    for (j = 0; j < 150; j = j + 1) wait_sample("release 65535 sustain");
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "release 65535 note off");
    j = 0;
    while (active_voice_count != 6'd0 && j < 4000) begin
      @(posedge clk);
      j = j + 1;
    end
    if (active_voice_count != 6'd0)
      $fatal(1, "release 65535: the voice is still active after %0d cycles", j);
    if (j > 2 * ce_period)
      $fatal(1, "release 65535: %0d cycles to release, expected within two samples", j);
    $display("PASS release 65535: the voice clears within one sample (%0d cycles)", j);

    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "release 1 note on");
    for (j = 0; j < 150; j = j + 1) wait_sample("release 1 sustain");
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "release 1 note off");
    for (j = 0; j < 200; j = j + 1) wait_sample("release 1");
    if (active_voice_count != 6'd1)
      $fatal(1, "release 1: %0d voices active after 200 samples, the release must be slow",
             active_voice_count);
    $display("PASS release 1: still releasing after 200 samples");
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd65535, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "release 1 note off");
    wait_silence(400000, "release 1 note off");

    // ================= 4. Velocity depth is a shift =====================
    // velocity_shift 0 keeps the stored gain equal to the velocity, so the two
    // tb_voice_vca numbers must still appear: 1528 and 383.
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd0, 16'd512);
    play_and_settle(8'd69, 8'd255, "velocity depth 0 vel 255", lev_a);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "velocity depth 0 vel 255 off");
    wait_silence(400000, "velocity depth 0 vel 255 off");
    play_and_settle(8'd69, 8'd128, "velocity depth 0 vel 128", lev_b);
    send_event(make_event(4'd2, 8'd69, 8'd128, 16'sd0), "velocity depth 0 vel 128 off");
    wait_silence(400000, "velocity depth 0 vel 128 off");
    if (lev_a !== 16'sd1528 || lev_b !== 16'sd383)
      $fatal(1, "velocity depth 0: vel 255/128 give %0d/%0d, expected 1528/383",
             lev_a, lev_b);
    $display("PASS velocity depth 0: vel 255 -> 1528, vel 128 -> 383 (tb_voice_vca numbers)");

    // velocity_shift 3 compresses the difference to 1/8: the stored gain for
    // velocity 128 becomes 255 - ((255-128)>>3) = 240, so the level moves up
    // towards the velocity-255 one instead of sitting at a quarter of it.
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1024, 2'd3, 2'd0, 16'd512);
    play_and_settle(8'd69, 8'd255, "velocity depth 3 vel 255", lev_c);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "velocity depth 3 vel 255 off");
    wait_silence(400000, "velocity depth 3 vel 255 off");
    play_and_settle(8'd69, 8'd128, "velocity depth 3 vel 128", lev_d);
    send_event(make_event(4'd2, 8'd69, 8'd128, 16'sd0), "velocity depth 3 vel 128 off");
    wait_silence(400000, "velocity depth 3 vel 128 off");
    if (lev_c !== 16'sd1528)
      $fatal(1, "velocity depth 3: velocity 255 gives %0d, expected the full 1528", lev_c);
    if (lev_d !== expect_sustain(8'd240))
      $fatal(1, "velocity depth 3: velocity 128 gives %0d, expected %0d (gain 240)",
             lev_d, expect_sustain(8'd240));
    if (lev_d == 16'sd0 || lev_c == 16'sd0)
      $fatal(1, "velocity depth 3: one of the levels is silent (%0d/%0d)", lev_c, lev_d);
    if ((lev_c - lev_d) * 8 > lev_c || (lev_d - lev_c) * 8 > lev_c)
      $fatal(1, "velocity depth 3: %0d vs %0d is wider than 1/8 of the loud level",
             lev_c, lev_d);
    $display("PASS velocity depth 3: vel 255 -> %0d, vel 128 -> %0d (gain 240, gap within 1/8)",
             lev_c, lev_d);

    // ================= 5. Detune width is an added shift ================
    // detune_shift 0 must reproduce the P1 number: the two oscillators differ by
    // base >> 8 for velocity 255, which is 153791 for note 69.
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd0, 16'd512);
    act_before = act_count;
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "detune 0 note on");
    wait_activation(act_before, "detune 0 note on");
    n1 = act_word[95:64] - act_word[127:96];
    if (act_word[127:96] !== (act_word[95:64] - (act_word[95:64] >> 8)))
      $fatal(1, "detune 0: step_b 0x%08h is not base - (base >> 8)", act_word[127:96]);
    if (n1 != 153791)
      $fatal(1, "detune 0: step_a - step_b is %0d, expected 153791 (P1 baseline)", n1);
    $display("PASS detune 0: step_a - step_b = %0d (base >> 8, the P1 baseline)", n1);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "detune 0 note off");
    wait_silence(400000, "detune 0 note off");

    // detune_shift 2 halves the width twice: a quarter of the P1 detune.
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd2, 16'd512);
    act_before = act_count;
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "detune 2 note on");
    wait_activation(act_before, "detune 2 note on");
    n2 = act_word[95:64] - act_word[127:96];
    if (act_word[127:96] !== (act_word[95:64] - (act_word[95:64] >> 10)))
      $fatal(1, "detune 2: step_b 0x%08h is not base - (base >> 10)", act_word[127:96]);
    if (n2 != 38447)
      $fatal(1, "detune 2: step_a - step_b is %0d, expected 38447 (base >> 10)", n2);
    if ((n1 - 4 * n2) > 4 || (n1 - 4 * n2) < -4)
      $fatal(1, "detune 2: %0d is not a quarter of %0d (within one LSB)", n2, n1);
    $display("PASS detune 2: step_a - step_b = %0d, a quarter of %0d", n2, n1);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "detune 2 note off");
    wait_silence(400000, "detune 2 note off");

    // ================= 6. Glide rate sets the walk speed ================
    // A REVOICE of +8190 on top of the base increment takes 8190/glide_rate
    // samples: 16 at the default 512 and 2 at 4095, a ratio of 8.
    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd0, 16'd512);
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "glide 512 note on");
    for (j = 0; j < 150; j = j + 1) wait_sample("glide 512 sustain");
    base_step = wb_step_a;
    target_step = base_step + 32'd8190;
    send_event(make_event(4'd3, 8'd69, 8'd255, 16'sd8190), "glide 512 revoice");
    glide_length(base_step, target_step, "glide 512", steps1);
    $display("PASS glide 512: %0d samples to walk 8190 step units", steps1);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "glide 512 note off");
    wait_silence(400000, "glide 512 note off");

    set_cfg(16'd4096, 16'd256, 16'd49152, 16'd1024, 2'd0, 2'd0, 16'd4095);
    send_event(make_event(4'd1, 8'd69, 8'd255, 16'sd0), "glide 4095 note on");
    for (j = 0; j < 150; j = j + 1) wait_sample("glide 4095 sustain");
    if (wb_step_a !== base_step)
      $fatal(1, "glide 4095: the new note starts at 0x%08h, expected the base 0x%08h",
             wb_step_a, base_step);
    send_event(make_event(4'd3, 8'd69, 8'd255, 16'sd8190), "glide 4095 revoice");
    glide_length(base_step, target_step, "glide 4095", steps2);
    $display("PASS glide 4095: %0d samples to walk 8190 step units", steps2);
    send_event(make_event(4'd2, 8'd69, 8'd255, 16'sd0), "glide 4095 note off");
    wait_silence(400000, "glide 4095 note off");

    if (steps1 !== 8 * steps2)
      $fatal(1, "glide rate: %0d samples at 512 vs %0d at 4095, expected an 8:1 ratio",
             steps1, steps2);
    $display("PASS glide rate: 512 needs %0d samples, 4095 needs %0d, an 8:1 ratio",
             steps1, steps2);

    // Nothing was stolen and the pack never touched the steal path.
    if (voice_steal_count !== 16'd0) $fatal(1, "%0d voices were stolen", voice_steal_count);
    if (voice_overflow !== 1'b0) $fatal(1, "voice_overflow set for single notes");

    $display("PASS voice_cfg: default 16/1528, attack 1..65535, release 1..65535, velocity depth, detune width and glide rate all follow the pack");
    $finish;
  end

  initial begin : timeout
    #300_000_000;
    $fatal(1, "tb_voice_cfg timeout (active=%0d steals=%0d)", active_voice_count,
           voice_steal_count);
  end
endmodule
