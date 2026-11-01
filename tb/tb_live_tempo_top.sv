// Integration check for the X tempo path: with the deterministic reader stub
// (USE_MGC_READER=0) cursor frames flow, so v2_live_tempo must leave its 120 BPM
// reset value and hand 30..59 BPM to the tick divider.
`timescale 1ns/1ps
module tb_live_tempo_top;
  logic clk = 0;
  wire uart_tx;
  wire mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire pcm_bck, pcm_lrck, pcm_din;
  int frames = 0;

  GSR GSR (.GSRI(1'b1));

  mgc3130_v2_top #(
    .USE_MGC_READER(0),
    .PRESERVE_INPUT_PLANE(1),
    .PRESERVE_INPUT_VALID(1)
  ) dut (
    .clk_50m(clk), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl),
    .mgc_ts(mgc_ts), .mgc_mclr(mgc_mclr),
    .uart_rx(1'b1), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm_bck), .pcm5102a_lrck(pcm_lrck), .pcm5102a_din(pcm_din)
  );

  always #6.25 clk = ~clk;
  always @(posedge clk) if (dut.cursor_frame_done) frames = frames + 1;

  initial begin
    repeat (400000) @(negedge clk);
    $display("frames=%0d bpm_auto_q=%0d spt=%0d", frames, dut.bpm_auto_q, dut.u_tick_gen.spt_q);
    if (frames == 0) $fatal(1, "FAIL no cursor frames from the stub reader");
    if (dut.bpm_auto_q < 30 || dut.bpm_auto_q > 59)
      $fatal(1, "FAIL bpm_auto_q=%0d did not track cursor_x", dut.bpm_auto_q);

    // The mapping ran while IDLE, where bpm_auto_we is masked away from the
    // divider.  Entering LIVE must reprogram it with the settled tempo.
    if (dut.u_tick_gen.spt_q != 24'd6000)
      $fatal(1, "FAIL divider changed outside LIVE: spt=%0d", dut.u_tick_gen.spt_q);
    force dut.mode_reg = 32'd1;
    repeat (200) @(negedge clk);
    $display("after LIVE: spt=%0d expected=%0d", dut.u_tick_gen.spt_q, 720000 / dut.bpm_auto_q);
    if (dut.u_tick_gen.spt_q > (720000 / dut.bpm_auto_q) + 1 ||
        dut.u_tick_gen.spt_q < (720000 / dut.bpm_auto_q) - 1)
      $fatal(1, "FAIL entering LIVE did not reprogram the divider: spt=%0d bpm=%0d",
             dut.u_tick_gen.spt_q, dut.bpm_auto_q);
    release dut.mode_reg;

    $display("PASS live tempo 120 -> %0d reaches the divider on mode entry", dut.bpm_auto_q);
    $finish;
  end
endmodule
