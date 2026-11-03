`timescale 1ns/1ps
// The demo top, end to end: silence between segments (a latched zero, not a held
// sample), tones inside a segment, a 48 kHz frame clock, and a panel that is
// rewritten when the tone count changes.
module tb_demo_top;
  localparam integer TONE = 8;
  localparam integer HOLD = 8;
  localparam integer GAP  = 4;

  logic clk_50m = 1'b0;
  tri   mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire  uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;
  wire  oled_sck, oled_mosi, oled_dc, oled_cs_n, oled_res_n, oled_blk;

  always #6.25 clk_50m = ~clk_50m;   // 80 MHz: V2_SIM makes this the system clock
  GSR GSR(.GSRI(1'b1));

  v2_demo_top #(
      .TONE_FRAMES(TONE), .HOLD32_FRAMES(HOLD), .GAP_FRAMES(GAP),
      .SPI_DIV(4), .OLED_RESET_CYCLES(20), .OLED_WAKE_CYCLES(200)
  ) dut (
      .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl),
      .mgc_ts(mgc_ts), .mgc_mclr(mgc_mclr), .uart_rx(1'b1), .uart_tx(uart_tx),
      .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck),
      .pcm5102a_din(pcm5102a_din),
      .oled_sck(oled_sck), .oled_mosi(oled_mosi), .oled_dc(oled_dc),
      .oled_cs_n(oled_cs_n), .oled_res_n(oled_res_n), .oled_blk(oled_blk)
  );

  integer lrck_edges = 0;
  integer muted_zero = 0;      // frames latched while muted that are 0
  integer muted_nonzero = 0;   // frames latched while muted that are not
  integer muted_run = 0;       // consecutive muted frames seen so far
  integer tone_nonzero = 0;    // frames latched while playing that are not
  integer tone_frames = 0;
  integer writer_starts = 0;
  logic   res_n_q = 1'b0;

  // Sample the transmitter's own latch on every LRCK rising edge: that is the
  // 16-bit word actually shifted out on the DAC pin.  The first muted frame of a
  // gap may still carry the last tone -- the latch follows the next 48 kHz tick
  // -- so the silence check starts one frame into the gap.
  always @(posedge pcm5102a_lrck) begin
    lrck_edges = lrck_edges + 1;
    if (dut.seq_muted) begin
      muted_run = muted_run + 1;
      if (muted_run >= 2) begin
        if (dut.u_i2s.sample_latched == 16'sd0) muted_zero = muted_zero + 1;
        else muted_nonzero = muted_nonzero + 1;
      end
    end else begin
      muted_run = 0;
      tone_frames = tone_frames + 1;
      if (dut.u_i2s.sample_latched != 16'sd0) tone_nonzero = tone_nonzero + 1;
    end
  end

  // The panel writer is restarted through its reset; count the starts.
  always @(posedge clk_50m) begin
    res_n_q <= oled_res_n;
    if (oled_res_n && !res_n_q) writer_starts = writer_starts + 1;
  end

  initial begin
    #2_000_000;   // 2 ms: two segments, two gaps, and at least one panel rewrite

    if (lrck_edges < 20) $fatal(1, "FAIL only %0d LRCK edges", lrck_edges);
    if (muted_zero < 4) $fatal(1, "FAIL %0d muted frames were zero", muted_zero);
    if (muted_nonzero != 0) $fatal(1, "FAIL %0d muted frames held a sample", muted_nonzero);
    if (tone_nonzero == 0) $fatal(1, "FAIL no sound inside a segment");
    if (writer_starts < 2) $fatal(1, "FAIL panel written %0d time(s), want 2", writer_starts);

    $display("PASS %0d frames, %0d muted zeros, %0d tone frames (%0d nonzero), %0d panel writes",
             lrck_edges, muted_zero, tone_frames, tone_nonzero, writer_starts);
    $finish;
  end
endmodule
