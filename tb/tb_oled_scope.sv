`timescale 1ns/1ps
// Scope picture: the plotter must map audio to the right pixel, the framebuffer
// must keep it there without disturbing any other byte, and the refresh stream
// must fade it away.
//
// The second half of the mapping test is the important one: a plotter that
// reads its byte one cycle late ORs a foreign byte into the target pixel, which
// on real hardware looks like vertical stripes.
module tb_oled_scope;
  logic clk = 1'b0, rst_n = 1'b0;
  logic sample_valid = 1'b0;
  logic signed [15:0] sample = 16'sd0;
  logic muted = 1'b0;

  logic [9:0] a_addr, b_addr;
  logic [7:0] a_wdata, a_rdata, b_wdata, b_rdata;
  logic a_we, b_we;
  logic [6:0] dbg_x;
  logic [5:0] dbg_y;

  logic sck, mosi, dc, cs_n, res_n, blk, frame;

  always #6.25 clk = ~clk;   // 80 MHz

  v2_oled_scope_fb u_fb (
      .clk(clk),
      .a_addr(a_addr), .a_wdata(a_wdata), .a_we(a_we), .a_rdata(a_rdata),
      .b_addr(b_addr), .b_wdata(b_wdata), .b_we(b_we), .b_rdata(b_rdata)
  );

  v2_oled_scope_plot u_plot (
      .clk(clk), .rst_n(rst_n), .sample_valid(sample_valid), .sample(sample),
      .muted(muted),
      .fb_addr(a_addr), .fb_wdata(a_wdata), .fb_we(a_we), .fb_rdata(a_rdata),
      .dbg_x(dbg_x), .dbg_y(dbg_y)
  );

  v2_oled_scope_wr #(
      .SPI_DIV(4), .RESET_CYCLES(20), .WAKE_CYCLES(200), .FRAME_GAP(1000),
      .DECAY_FRAMES(1)
  ) u_wr (
      .clk(clk), .rst_n(rst_n), .start(1'b1),
      .fb_rdata(b_rdata), .fb_addr(b_addr), .fb_wdata(b_wdata), .fb_we(b_we),
      .sck(sck), .mosi(mosi), .dc(dc), .cs_n(cs_n), .res_n(res_n), .blk(blk),
      .frame(frame)
  );

  integer frames = 0;
  integer i, stray;
  // sample 0           -> x=64, row=31 -> {3,64}   mask 0x80
  // sample 16000       -> x=64, row=16 -> {2,64}   mask 0x01
  localparam integer ADDR_A = 3 * 128 + 64;
  localparam integer ADDR_B = 2 * 128 + 64;

  always @(posedge clk) if (frame) frames = frames + 1;

  // On silicon the block RAM powers up zero; simulation leaves it X, and an X
  // ORed into a pixel would hide exactly the bug this bench is looking for.
  initial for (i = 0; i < 1024; i = i + 1) u_fb.mem[i] = 8'h00;

  task automatic plot_one(input logic signed [15:0] value);
    begin
      sample       <= value;
      sample_valid <= 1'b1;
      @(posedge clk);
      sample_valid <= 1'b0;
      repeat (12) @(posedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (8) @(posedge clk);

    // ---- two different points, before the first refresh frame --------------
    plot_one(16'sd0);
    plot_one(16'sd16000);
    if (u_fb.mem[ADDR_A] !== 8'h80)
      $fatal(1, "FAIL A = %02h, want 80", u_fb.mem[ADDR_A]);
    if (u_fb.mem[ADDR_B] !== 8'h01)
      $fatal(1, "FAIL B = %02h, want 01 (a late read would OR A's byte here)",
             u_fb.mem[ADDR_B]);

    stray = 0;
    for (i = 0; i < 1024; i = i + 1)
      if (i != ADDR_A && i != ADDR_B && u_fb.mem[i] !== 8'h00) stray = stray + 1;
    if (stray != 0) $fatal(1, "FAIL %0d bytes were written outside the two points", stray);

    // ---- stop plotting: the refresh stream fades both bytes to zero -------
    while (frames < 12) @(posedge clk);
    if (u_fb.mem[ADDR_A] !== 8'h00 || u_fb.mem[ADDR_B] !== 8'h00)
      $fatal(1, "FAIL bytes %02h/%02h did not decay",
             u_fb.mem[ADDR_A], u_fb.mem[ADDR_B]);

    $display("PASS x=%0d row=%0d, two isolated pixels, %0d frames, then decay",
             dbg_x, dbg_y, frames);
    $finish;
  end
endmodule
