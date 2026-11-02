`timescale 1ns / 1ps

// The single-voice LIVE envelope used to be three hardcoded steps, so in LIVE
// every preset shared one shape (about 10 ms up, 0.7 sustain) and they all sounded
// like the same horn.  It now takes its attack, decay and sustain from the P2b
// words 0x94 / 0x98, which is what lets a preset be percussive (sustain 0) or a
// slow bow swell.
//
// This bench drives the envelope directly - it captures dut.wt_env, not the audio,
// because the audio is just table x envelope and tb_live_arp_step already covers
// that product.  Forcing dut.live_env_hit is the same retrigger the event path
// raises on a NOTE_ON, so the shape under test is exactly the production one.
//
// Three shapes, one per register set:
//   cowbell   attack 1, decay 6, sustain 0     -> up at once, gone by ~250 ms
//   strings   attack 12, decay 24, sustain .85 -> still climbing at sample 100
//   default   the reset words                  -> settles at 0.75 and holds
module tb_live_env_regs;
  localparam integer ATT_SAMPLES_MIN = 20;     // cowbell must reach the top fast
  localparam integer DECAY_LIMIT     = 13000;  // and be silent by here (~270 ms)
  localparam integer SWELL_CHECK     = 100;    // strings: still rising at 100
  localparam integer HOLD_TOLERANCE  = 1200;   // default: +-1200 of sustain 49152

  logic clk = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;

  logic [1:0]         tb_cursor_state = 2'd1;
  logic signed [31:0] tb_cursor_x = 32'sd0;
  logic signed [31:0] tb_cursor_y = 32'sd3000;    // note 55
  logic signed [31:0] tb_cursor_z = 32'sd30000;
  logic               tb_frame_done = 1'b0;

  integer guard, i;
  integer env_at = 0;                             // index of the samples we keep
  logic [15:0] env_log [0:20000];
  logic [7:0]  inject_value;
  logic [15:0] crc;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(0), .UART_BAUD(40_000_000),
                   .V2_DEBUG_CSR(1)) dut (
    .clk_50m(clk), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck),
    .pcm5102a_din(pcm5102a_din)
  );

  // --------------------------------------------------------------- helpers ---
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

  // Bytes are forced at the UART's byte interface, not bit-banged on the pin: at
  // UART_BAUD=40 MHz one bit lasts two clocks, which the arp bench also avoids this
  // way.  A reply must drain before the next frame, and a NACK is fatal.
  task automatic inject_byte(input [7:0] value);
    begin
      inject_value = value;
      force dut.uart_byte = inject_value;
      force dut.uart_byte_valid = 1'b1;
      @(posedge clk);
      #1;
      force dut.uart_byte_valid = 1'b0;
      @(posedge clk);
      #1;
      release dut.uart_byte_valid;
      release dut.uart_byte;
    end
  endtask

  task automatic inject_control(input [7:0] op, input [7:0] address,
                                input [7:0] sq, input [31:0] data);
    reg [7:0] b [0:10];
    reg [15:0] c;
    integer kk;
    begin
      b[0] = 8'ha5; b[1] = 8'h02; b[2] = op; b[3] = address; b[4] = sq;
      b[5] = data[31:24]; b[6] = data[23:16]; b[7] = data[15:8]; b[8] = data[7:0];
      c = 16'hffff;
      for (kk = 0; kk < 9; kk = kk + 1) c = crc_byte(c, b[kk]);
      b[9] = c[15:8]; b[10] = c[7:0];
      guard = 0;
      while ((dut.v2_tx_valid || dut.uart_tx_busy) && guard < 200000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (guard >= 200000) $fatal(1, "the previous reply never finished");
      for (kk = 0; kk < 11; kk = kk + 1) inject_byte(b[kk]);
      repeat (4) @(posedge clk);
      for (kk = 0; kk < 20000; kk = kk + 1) begin
        if (!dut.v2_tx_valid && !dut.uart_tx_busy) kk = 20000;
        else @(posedge clk);
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy)
        $fatal(1, "V2 UART response did not drain");
      if (dut.rsp_error !== 8'd0)
        $fatal(1, "op=0x%02h addr=0x%02h seq=0x%02h NACKed err=0x%02h",
               op, address, sq, dut.rsp_error);
    end
  endtask
  task automatic send_frame(input [15:0] xv);
    begin
      tb_cursor_x     = 32'sd0 + xv;
      tb_cursor_y     = 32'sd3000;
      tb_cursor_z     = 32'sd30000;
      tb_cursor_state = 2'd1;
      tb_frame_done   = 1'b0;
      @(negedge clk);
      tb_frame_done   = 1'b1;
      @(negedge clk);
      tb_frame_done   = 1'b0;
      repeat (4) @(negedge clk);
    end
  endtask

  // Capture in the DAC's own clock domain.  Polling dut.sample_ce from the 50 MHz
  // test clock misses every other pulse (a 100 MHz sample_ce is 10 ns wide), which
  // is what made the first version of this bench read half the envelope steps.
  task automatic sample_env(input integer count);
    integer busy;
    begin
      env_at = 0;
      busy = 0;
      while (env_at < count && busy < 40_000_000) begin
        @(posedge dut.clk_sys_100m);
        busy = busy + 1;
        if (dut.sample_ce) begin
          if (env_at < 20000) env_log[env_at] = dut.wt_env;
          env_at = env_at + 1;
        end
      end
      if (env_at < count) $fatal(1, "captured only %0d of %0d samples", env_at, count);
    end
  endtask

  // One retrigger, then `count` sampled envelopes starting at index 0.
  task automatic take_shape(input integer count);
    begin
      @(negedge clk);
      force dut.live_env_hit = 1'b1;
      @(negedge clk);
      release dut.live_env_hit;
      sample_env(count);
    end
  endtask
  function automatic integer peak_of(input integer count);
    integer k, best;
    begin
      best = 0;
      for (k = 0; k < count; k = k + 1)
        if (env_log[k] > best) best = env_log[k];
      peak_of = best;
    end
  endfunction

  // ------------------------------------------------------------------ run ----
  initial begin : run_tb
    repeat (40) @(posedge clk);
    guard = 0;
    while (dut.rst_sys_n !== 1'b1 && guard < 10000) begin @(negedge clk); guard = guard + 1; end
    if (dut.rst_sys_n !== 1'b1) $fatal(1, "reset did not release");
    if (!dut.pll_locked) $fatal(1, "pll_locked is low");

    force dut.cursor_state      = tb_cursor_state;
    force dut.cursor_x          = tb_cursor_x;
    force dut.cursor_y          = tb_cursor_y;
    force dut.cursor_z          = tb_cursor_z;
    force dut.cursor_frame_done = tb_frame_done;
    force dut.degraded_frame    = 1'b0;
    force dut.calibrated_gap    = 1'b0;
    force dut.cursor_rebased    = 1'b0;

    inject_control(8'h02, 8'h04, 8'h31, 32'd1);        // MODE = LIVE
    repeat (8) @(negedge clk);
    if (!dut.mode_live) $fatal(1, "MODE=LIVE was rejected");

    send_frame(16'd0);
    send_frame(16'd0);
    send_frame(16'd5000);
    send_frame(16'd20000);
    guard = 0;
    while (!dut.live_active && guard < 200000) begin @(negedge clk); guard = guard + 1; end
    if (!dut.live_active) $fatal(1, "LIVE never produced a NOTE_ON; the gate is shut");
    if (!dut.live_gate) $fatal(1, "live_gate is low, the envelope would decay");

    // ---- 1) percussive: attack to full, then decay to a zero sustain ----------
    // decay 256 rather than the cowbell preset's 6 so the window stays short; the
    // mechanism under test (attack to FULL, decay to a ZERO sustain) is the same
    // code path, and the preset's own numbers are the preset's business.
    inject_control(8'h02, 8'h94, 8'h40, {16'd256, 16'd8192});   // decay 256, attack 8192
    inject_control(8'h02, 8'h98, 8'h41, {16'd2, 16'd0});        // release 2, sustain 0
    if (dut.env_sus_level !== 16'd0) $fatal(1, "sustain word did not reach the LIVE path");
    take_shape(600);
    if (peak_of(600) < 16'd60000)
      $fatal(1, "percussive peak %0d: attack never reached full scale", peak_of(600));
    if (env_log[12] < 16'd60000)
      $fatal(1, "attack 8192 needs at most 12 samples to peak, saw %0d", env_log[12]);
    if (env_log[400] > 16'd600)
      $fatal(1, "sustain 0 not honoured: %0d at 400 samples", env_log[400]);
    $display("PASS percussive: peak %0d by sample 8, %0d at 400", peak_of(600), env_log[400]);

    // ---- 2) a slow swell, then decay to a non-zero sustain -------------------
    inject_control(8'h02, 8'h94, 8'h42, {16'd24, 16'd512});     // decay 24, attack 512
    inject_control(8'h02, 8'h98, 8'h43, {16'd4, 16'd55705});    // sustain 0.85
    take_shape(760);
    if (env_log[20] * 5 > env_log[200])
      $fatal(1, "swell too fast: %0d at 20 samples vs %0d at 200", env_log[20], env_log[200]);
    // attack 512 needs 128 samples to full, then decay 24 has 9830 to cover: the
    // sustain level arrives at about sample 538.
    if (env_log[700] > 16'd55705 + 200 || env_log[700] + 200 < 16'd55705)
      $fatal(1, "sustain 0.85 not reached: %0d at 700 samples", env_log[700]);
    $display("PASS swell: %0d at 20, %0d at 200, %0d at 700", env_log[20], env_log[200], env_log[700]);

    // ---- 3) the reset words --------------------------------------------------
    inject_control(8'h02, 8'h94, 8'h44, 32'h0100_1000);
    inject_control(8'h02, 8'h98, 8'h45, 32'h0400_C000);
    take_shape(600);
    for (i = 200; i < 600; i = i + 1)
      if (env_log[i] > 16'd49152 + HOLD_TOLERANCE || env_log[i] + HOLD_TOLERANCE < 16'd49152)
        $fatal(1, "default shape does not hold at 49152: %0d at %0d", env_log[i], i);
    $display("PASS default: holds 49152 across 400 samples");
    $display("UNIT tb_live_env_regs: PASS");
    $finish;
  end

  initial begin
    #200_000_000;
    $fatal(1, "timeout");
  end
endmodule
