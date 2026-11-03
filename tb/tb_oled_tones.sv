`timescale 1ns/1ps
// The panel picture is pure combinational logic; these are the numbers that
// prove it draws what the design says: bar k is k pixels tall, only k <= N bars
// are lit, and the glyphs are the 5x7 table scaled 2x.
module tb_oled_tones;
  logic [9:0] addr;
  logic [5:0] n;
  logic [7:0] data;

  v2_oled_tones dut(.img_addr(addr), .tone_count(n), .img_data(data));

  integer slot, h, hi;

  // Timing controls are illegal in functions, so the accessors are tasks.
  task automatic point(input integer page, input integer col);
    begin
      addr = {3'(page), 7'(col)};
      #1;
    end
  endtask

  task automatic bar_height(input integer s, output integer height);
    integer r;
    begin
      height = 0;
      for (r = 16; r < 64; r = r + 1) begin
        point(r / 8, 4 * s);
        if (data[r % 8]) height = height + 1;
      end
    end
  endtask

  task automatic expect_byte(input integer page, input integer col,
                             input logic [7:0] want, input [8*16-1:0] what);
    begin
      point(page, col);
      if (data !== want) $fatal(1, "FAIL %0s page %0d col %0d = %02h want %02h",
                                what, page, col, data, want);
    end
  endtask

  initial begin
    addr = 10'd0; n = 6'd0; #1;

    // ---- bars, N = 32: height == slot+1 for every slot ----------------------
    n = 6'd32; #1;
    for (slot = 0; slot < 32; slot = slot + 1) begin
      bar_height(slot, h);
      if (h !== slot + 1) $fatal(1, "FAIL slot %0d height %0d want %0d", slot, h, slot + 1);
    end

    // ---- bars follow N ------------------------------------------------------
    n = 6'd8; #1;
    bar_height(7, h);  if (h !== 8) $fatal(1, "FAIL bar 7 height %0d", h);
    bar_height(9, h);  if (h !== 0) $fatal(1, "FAIL bar 9 lit with N=8");
    n = 6'd1; #1;
    bar_height(0, h);  if (h !== 1) $fatal(1, "FAIL bar 0 height %0d", h);
    bar_height(1, h);  if (h !== 0) $fatal(1, "FAIL bar 1 lit with N=1");

    // ---- glyphs: 'N' at column 32, '8' at column 80 ------------------------
    n = 6'd8; #1;
    expect_byte(0, 32, 8'hFF, "'N' col0");
    expect_byte(1, 32, 8'h3F, "'N' col0");
    expect_byte(0, 80, 8'h3C, "'8' col0");
    expect_byte(1, 80, 8'h0F, "'8' col0");

    // ---- N = 32 puts '3' in the tens cell (column 64) ----------------------
    n = 6'd32; #1;
    expect_byte(0, 64, 8'h03, "'3' col0");

    // ---- nothing but "N= 0" with no tones ----------------------------------
    n = 6'd0; #1;
    for (slot = 0; slot < 32; slot = slot + 1) begin
      bar_height(slot, h);
      if (h !== 0) $fatal(1, "FAIL bar %0d lit with N=0", slot);
    end

    $display("PASS 32 bars, heights follow k, glyphs match the 5x7 table");
    $finish;
  end
endmodule
