`timescale 1ns/1ps
// Top-level test for the PLAY wavetable bypass.
//
// Three things are pinned here:
//   1. with no table uploaded, PLAY is silent (the engine gets rd_valid=0 and
//      writes zeros into the sample buffers, so no saw leaks through);
//   2. with a constant table uploaded and applied, PLAY plays that table:
//      sample = (0x3000 >>> WT_SELECT[7:4]) attenuated by stage/velocity/mix and
//      then scaled by the voice's VCA (envelope * velocity);
//   3. the read port belongs to the table engine in PLAY: WT_DATA reads 0 there
//      and the normal readback returns after going back to IDLE.
//
// The loop scheduler is bypassed with a forced note-on (its own path is covered
// by tb_stage2_loop_e2e); everything between the table and the voice engine's
// mix accumulator is the real logic.
//
// The UART runs at 40 Mbaud here: the table upload is 1024 WT_DATA writes, and at
// the production 1 Mbaud the 22-byte replies alone would cost about 18M cycles.
// The wavetable path does not depend on the byte rate.
module tb_top_wt_voice;
  localparam integer TABLE = 0;
  localparam logic signed [15:0] TABLE_VALUE = 16'sh3000;
  localparam logic [3:0] SHIFT = 4'd4;
  localparam logic [7:0] VELOCITY = 8'd127;
  // Ramp slope: the table spans 1024 * 63, so one index step is 63.
  localparam logic signed [15:0] RAMP_STEP = 16'sd63;
  localparam logic [1:0] RAMP_TABLE = 2'd1;
  // The VCA's sustain level: the 16-bit envelope value the audio path settles at.
  localparam logic [15:0] SUSTAIN_LEVEL = 16'd49152;

  logic clk_50m = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  logic [7:0] inject_value;
  logic [95:0] tb_event = 96'd0;
  integer i, guard, first_val, last_val;
  logic [15:0] crc, crc_final;
  logic signed [15:0] want;

  always #5 clk_50m = ~clk_50m;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(1), .UART_BAUD(40_000_000),
                   .POTTS_HORIZON(32), .V2_DEBUG_CSR(1)) dut (
    .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck), .pcm5102a_din(pcm5102a_din)
  );

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

  function automatic [95:0] make_note_on(input [7:0] tick, input [7:0] note,
                                         input [7:0] vel);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = 4'd1;
      e[87:80] = tick;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = vel;
      make_note_on = e;
    end
  endfunction

  // Independent copy of the voice engine's attenuation.
  function automatic logic signed [47:0] att(input logic signed [47:0] raw,
                                             input logic [1:0] stage,
                                             input logic [7:0] velocity,
                                             input logic [7:0] mix);
    integer a;
    begin
      a = 0;
      if (stage == 2'd0) a = a + 2;
      if (stage == 2'd1) a = a + 1;
      if (stage == 2'd3) a = a + 3;
      if (velocity < 8'd64) a = a + 3;
      else if (velocity < 8'd128) a = a + 2;
      else if (velocity < 8'd192) a = a + 1;
      if (mix < 8'd64) a = a + 3;
      else if (mix < 8'd128) a = a + 2;
      else if (mix < 8'd192) a = a + 1;
      att = raw >>> a;
    end
  endfunction

  // Independent copy of the VCA the engine applies after the attenuation.
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
      // The link holds one outstanding transaction, and an APPLY replies only
      // after its CRC scan, long after the command was accepted.  Starting the
      // next frame while that reply is still going out drops it, which is how a
      // WT_SELECT write was silently lost here.
      guard = 0;
      while ((dut.v2_tx_valid || dut.uart_tx_busy) && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "the previous reply never finished");
      for (k = 0; k < 11; k = k + 1) inject_byte(b[k]);
      repeat (4) @(posedge clk_50m);
      for (k = 0; k < 20000; k = k + 1) begin
        if (!dut.v2_tx_valid && !dut.uart_tx_busy) k = 20000;
        else @(posedge clk_50m);
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy)
        $fatal(1, "V2 UART response did not drain");
      if (dut.rsp_error !== 8'd0)
        $fatal(1, "op=0x%02h addr=0x%02h seq=0x%02h NACKed err=0x%02h",
               op, address, seq, dut.rsp_error);
    end
  endtask

  task automatic wait_sample(input [127:0] what);
    begin
      guard = 0;
      while (1) begin
        @(negedge clk_50m);
        if (dut.voice_sample_valid && dut.active_voice_count != 6'd0) begin
          @(negedge clk_50m);
          break;
        end
        guard = guard + 1;
        if (guard > 200000) $fatal(1, "%0s: no voice sample with a sounding voice", what);
      end
    end
  endtask

  task automatic play_note(input [7:0] note, input [7:0] vel);
    begin
      // A force statement cannot name an automatic variable, so stage the event.
      tb_event = make_note_on(8'd0, note, vel);
      @(negedge clk_50m);
      force dut.loop_event_data = tb_event;
      force dut.loop_event_valid = 1'b1;
      guard = 0;
      while (!dut.loop_event_ready && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (!dut.loop_event_ready) $fatal(1, "the voice engine never became ready");
      @(posedge clk_50m);
      @(negedge clk_50m);
      release dut.loop_event_valid;
      release dut.loop_event_data;
      repeat (4) @(posedge clk_50m);
    end
  endtask

  task automatic wait_silence;
    begin
      guard = 0;
      while (dut.active_voice_count != 6'd0 && guard < 400000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (dut.active_voice_count != 6'd0)
        $fatal(1, "voices still sounding after leaving PLAY");
    end
  endtask

  task automatic upload_table;
    begin
      // length, index = 0 (this also reloads the upload pointer)
      inject_control(8'h02, 8'h6C, 8'h60, 32'd1024);
      inject_control(8'h02, 8'h64, 8'h61, 32'd0);
      for (i = 0; i < 1024; i = i + 1)
        inject_control(8'h02, 8'h68, i[7:0], {16'd0, TABLE_VALUE});
      crc = 16'hffff;
      for (i = 0; i < 1024; i = i + 1) begin
        crc = crc_byte(crc, TABLE_VALUE[15:8]);
        crc = crc_byte(crc, TABLE_VALUE[7:0]);
      end
      crc_final = crc;
      inject_control(8'h02, 8'h70, 8'h62, {16'd0, crc_final});
      inject_control(8'h02, 8'h74, 8'h63, 32'd0);                  // WT_VERSION
      inject_control(8'h02, 8'h78, 8'h64, 32'h8000_0000);          // APPLY + commit bit
      guard = 0;
      while (!dut.u_wavetable_loader.wt_active_valid && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (!dut.u_wavetable_loader.wt_active_valid)
        $fatal(1, "the table never became active (crc=0x%04h reason=%0d)", crc_final,
               dut.u_wavetable_loader.dbg_apply_reject_reason);
    end
  endtask

  // A ramp: its value depends on the table index, so a stuck phase and a running
  // oscillator give different outputs.  A constant table cannot tell them apart.
  function automatic logic signed [15:0] ramp_value(input integer idx);
    ramp_value = (idx - 512) * RAMP_STEP;
  endfunction

  task automatic upload_ramp(input [1:0] tbl);
    begin
      inject_control(8'h02, 8'h60, 8'h65, {28'd0, 4'd0, tbl});    // select, shift 0
      inject_control(8'h02, 8'h6C, 8'h66, 32'd1024);
      inject_control(8'h02, 8'h64, 8'h67, 32'd0);
      for (i = 0; i < 1024; i = i + 1)
        inject_control(8'h02, 8'h68, i[7:0], {16'd0, ramp_value(i)});
      crc = 16'hffff;
      for (i = 0; i < 1024; i = i + 1) begin
        crc = crc_byte(crc, ramp_value(i)[15:8]);
        crc = crc_byte(crc, ramp_value(i)[7:0]);
      end
      crc_final = crc;
      inject_control(8'h02, 8'h70, 8'h68, {16'd0, crc_final});
      inject_control(8'h02, 8'h74, 8'h69, 32'd0);
      inject_control(8'h02, 8'h78, 8'h6A, 32'h8000_0000);
      guard = 0;
      while (!dut.u_wavetable_loader.wt_active_valid && guard < 200000) begin
        @(posedge clk_50m);
        guard = guard + 1;
      end
      if (!dut.u_wavetable_loader.wt_active_valid)
        $fatal(1, "the ramp table never became active (crc=0x%04h reason=%0d)",
               crc_final, dut.u_wavetable_loader.dbg_apply_reject_reason);
    end
  endtask

  // Wait for the next finished scan, sampling on the system clock because the
  // pulse is one system-clock wide.
  task automatic next_sample;
    begin
      guard = 0;
      @(posedge dut.clk_sys_100m);
      while (!dut.voice_sample_valid && guard < 200000) begin
        @(posedge dut.clk_sys_100m);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "no voice sample");
    end
  endtask

  initial begin : run_tb
    repeat (40) @(posedge clk_50m);
    if (!dut.rst_sys_n || !dut.pll_locked) $fatal(1, "reset/PLL did not release");

    inject_control(8'h01, 8'hB0, 8'h30, 32'd0);
    if (dut.rsp_data !== 32'h5A5A_0003) $fatal(1, "0xB0=0x%08h", dut.rsp_data);
    // The default voice scaling lives in WT_SELECT[7:4] and must be 2: the gain
    // that keeps one note audible while two full-scale voices still fit.
    inject_control(8'h01, 8'h60, 8'h31, 32'd0);
    if (dut.rsp_data[7:4] !== 4'd2)
      $fatal(1, "WT_SELECT shift default is %0d, expected 2", dut.rsp_data[7:4]);

    // ---- 1. No table: PLAY must be silent, not a saw ---------------------
    inject_control(8'h02, 8'h04, 8'h32, 32'd4);            // MODE=PLAY
    if (!dut.mode_play) $fatal(1, "MODE=PLAY was rejected");
    play_note(8'd69, VELOCITY);
    wait_sample("silent first sample");
    if (dut.voice_sample !== 16'sd0)
      $fatal(1, "no table uploaded but PLAY produced %0d", dut.voice_sample);
    inject_control(8'h02, 8'h14, 8'h33, 32'd1);            // STOP
    wait_silence;

    // ---- 2. Upload one constant table and play it -------------------------
    upload_table;
    // WT_SELECT: table 0, morph off, shift 4.
    inject_control(8'h02, 8'h60, 8'h65, 32'h0000_0040);
    // The IDLE readback still works: index 0 of the active bank is the constant.
    inject_control(8'h02, 8'h64, 8'h66, 32'd0);
    inject_control(8'h01, 8'h68, 8'h67, 32'd0);
    if (dut.rsp_data[15:0] !== TABLE_VALUE)
      $fatal(1, "IDLE WT_DATA readback 0x%04h, expected 0x%04h",
             dut.rsp_data[15:0], TABLE_VALUE);

    inject_control(8'h02, 8'h04, 8'h68, 32'd4);            // MODE=PLAY
    if (!dut.mode_play) $fatal(1, "MODE=PLAY was rejected for the table take");
    // The first scan consumes the empty buffer and starts the table engine; the
    // engine then fills the buffer, so the second scan finds real samples.  The
    // pulse is one system-clock wide, so count it on the system clock.
    for (i = 0; i < 2; i = i + 1) begin
      guard = 0;
      @(posedge dut.clk_sys_100m);
      while (!dut.voice_sample_valid && guard < 200000) begin
        @(posedge dut.clk_sys_100m);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "the voice engine never produced a sample in PLAY");
    end
    if (dut.wt_voice_sample_a !== (TABLE_VALUE >>> SHIFT))
      $fatal(1, "sample buffer holds %0d, expected %0d",
             dut.wt_voice_sample_a, (TABLE_VALUE >>> SHIFT));

    play_note(8'd69, VELOCITY);
    wait_sample("first sample from the table");
    // The envelope starts at zero in the bank, so the note-on sample is silent.
    if (dut.voice_sample !== 16'sd0)
      $fatal(1, "the first PLAY sample is %0d, expected 0 (the envelope starts at 0)",
             dut.voice_sample);
    // Each voice runs two oscillators (phase a and b) and both now read the
    // table, so a constant table gives twice the single-oscillator value; the
    // VCA then scales it by (49152 * 127 >> 8) >> 16 = 0.372 in sustain.
    // 2 * ((0x3000 >>> 4) >>> 3) = 192 and 192 * 24384 >> 16 = 71, where the
    // >>> 3 is velocity 127 (+2) plus mix 128 (+1).
    for (i = 0; i < 150; i = i + 1) next_sample;
    want = vca(2 * att({{32{TABLE_VALUE[15]}}, TABLE_VALUE} >>> SHIFT, 2'd2, VELOCITY, 8'd128),
               SUSTAIN_LEVEL, VELOCITY);
    if (dut.voice_sample !== want)
      $fatal(1, "PLAY sustain sample %0d, expected %0d (2 x table 0x%04h >>> %0d through the VCA)",
             dut.voice_sample, want, TABLE_VALUE, SHIFT);

    // ---- 3. The read port belongs to the engine while PLAY runs -----------
    inject_control(8'h01, 8'h68, 8'h69, 32'd0);
    if (dut.rsp_data !== 32'd0)
      $fatal(1, "PLAY WT_DATA readback returned 0x%08h, expected 0", dut.rsp_data);
    inject_control(8'h02, 8'h14, 8'h6A, 32'd1);            // STOP
    wait_silence;
    inject_control(8'h02, 8'h64, 8'h6B, 32'd0);
    inject_control(8'h01, 8'h68, 8'h6C, 32'd0);
    if (dut.rsp_data[15:0] !== TABLE_VALUE)
      $fatal(1, "after leaving PLAY WT_DATA readback 0x%04h, expected 0x%04h",
             dut.rsp_data[15:0], TABLE_VALUE);

    if (dut.voice_steal_count !== 16'd0) $fatal(1, "single notes stole a voice");
    if (dut.voice_overflow !== 1'b0) $fatal(1, "voice_overflow set for a single note");

    // ---- 4. The oscillator must actually move ----------------------------
    // A constant table cannot tell a running oscillator from a frozen phase, so
    // this phase uses a ramp: with note 55 the phase advances 4.18 table points
    // per sample, i.e. 63 * 4.18 * 2 oscillators = 527 units, then >>> 4 (shift)
    // and >>> 3 (velocity 127 + mix 128) leaves about 33 units per 8 samples.
    // The VCA then scales the whole window by its sustain gain
    // (49152 * 127 >> 8) / 65536 = 0.372, so it shrinks from about 33 to about 12.
    upload_ramp(RAMP_TABLE);
    inject_control(8'h02, 8'h60, 8'h6D, {23'd0, 1'b0, SHIFT, 2'd0, RAMP_TABLE});  // select, shift
    inject_control(8'h01, 8'h60, 8'h70, 32'd0);
    if (dut.rsp_data[7:4] !== SHIFT || dut.rsp_data[1:0] !== RAMP_TABLE)
      $fatal(1, "WT_SELECT readback 0x%08h, expected shift %0d table %0d",
             dut.rsp_data, SHIFT, RAMP_TABLE);
    inject_control(8'h02, 8'h04, 8'h6E, 32'd4);                        // MODE=PLAY
    if (!dut.mode_play) $fatal(1, "MODE=PLAY was rejected for the ramp take");
    play_note(8'd55, VELOCITY);
    wait_sample("ramp sample");
    // Let the envelope reach sustain (attack 16 + decay 64 samples) so the
    // attenuation stops changing inside the measured window.
    for (i = 0; i < 120; i = i + 1) next_sample;
    next_sample;
    first_val = dut.voice_sample;
    for (i = 0; i < 8; i = i + 1) next_sample;
    last_val = dut.voice_sample;
    // The old window was 20..50 for a nominal 33; scaling it by 0.372 and
    // allowing one LSB of truncation at each end gives 6..20 for a nominal 12.
    if (last_val - first_val < 6 || last_val - first_val > 20)
      $fatal(1, "the ramp advanced %0d units over 8 samples, expected about 12; the phase is not running",
             last_val - first_val);
    inject_control(8'h02, 8'h14, 8'h6F, 32'd1);                        // STOP
    wait_silence;

    $display("PASS top wavetable voice: no table -> 0, table 0x%04h >>> %0d -> %0d, WT_DATA 0 in PLAY",
             TABLE_VALUE, SHIFT, want);
    $display("PASS top wavetable voice: ramp advanced %0d units over 8 samples (phase is running)",
             last_val - first_val);
    $finish;
  end

  initial begin : timeout
    #400_000_000;
    $fatal(1, "tb_top_wt_voice timeout (mode=%0d active=%0d)", dut.mode_reg,
           dut.active_voice_count);
  end
endmodule
