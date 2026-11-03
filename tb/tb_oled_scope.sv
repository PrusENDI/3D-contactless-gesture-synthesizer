`timescale 1ns/1ps
// Scope picture: the plotter must map audio to the right pixel, the framebuffer
// must keep it, and the refresh stream must fade it away.
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
      .SPI_DIV(4), .RESET_CYCLES(20), .WAKE_CYCLES(200), .FRAME_GAP(1000)
  ) u_wr (
      .clk(clk), .rst_n(rst_n), .start(1'b1),
      .fb_rdata(b_rdata), .fb_addr(b_addr), .fb_wdata(b_wdata), .fb_we(b_we),
      .sck(sck), .mosi(mosi), .dc(dc), .cs_n(cs_n), .res_n(res_n), .blk(blk),
      .frame(frame)
  );

  integer frames = 0;
  integer i;
  // {row[5:3], x[6:0]} for x=64, row=31 (sample 0 sits in the middle).
  localparam integer ADDR = 3 * 128 + 64;

  always @(posedge clk) if (frame) frames = frames + 1;

  task automatic feed(input integer count);
    begin
      for (i = 0; i < count; i = i + 1) begin
        sample_valid <= 1'b1;
        @(posedge clk);
        sample_valid <= 1'b0;
        repeat (3) @(posedge clk);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (8) @(posedge clk);

    // ---- a DC sample of 0 plots the middle-left pixel: x=64, row=31 -------
    feed(40);
    if (dbg_x !== 7'd64) $fatal(1, "FAIL x = %0d, want 64", dbg_x);
    if (dbg_y !== 6'd31) $fatal(1, "FAIL row = %0d, want 31", dbg_y);
    repeat (4) @(posedge clk);
    if (u_fb.mem[ADDR][7] !== 1'b1)
      $fatal(1, "FAIL pixel not set, byte %02h", u_fb.mem[ADDR]);

    // ---- stop plotting: the refresh stream fades the byte to zero ---------
    while (frames < 12) @(posedge clk);
    if (u_fb.mem[ADDR] !== 8'h00)
      $fatal(1, "FAIL byte %02h did not decay", u_fb.mem[ADDR]);
    if (frames < 2) $fatal(1, "FAIL only %0d frames", frames);

    $display("PASS x=%0d row=%0d, pixel set then faded, %0d frames", dbg_x, dbg_y, frames);
    $finish;
  end
endmodule
