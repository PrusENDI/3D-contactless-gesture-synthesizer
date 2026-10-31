// Unit test for the 8-bit-frac wavetable crossfade.
module tb_wt_mix;
  logic signed [15:0] a, b, out;
  logic [7:0] frac;

  v2_wt_mix dut(.a(a), .b(b), .frac(frac), .out(out));

  task automatic check(input logic signed [15:0] ta, input logic signed [15:0] tb_,
                       input logic [7:0] tf, input logic signed [15:0] want,
                       input string what);
    begin
      a = ta; b = tb_; frac = tf; #1;
      if (out !== want) $fatal(1, "FAIL %s: a=%0d b=%0d f=%0d got %0d want %0d",
                               what, ta, tb_, tf, out, want);
      $display("PASS %s = %0d", what, out);
    end
  endtask

  initial begin
    check(16'sd0, 16'sd32767, 8'd0,   16'sd0,     "frac 0 returns a");
    check(16'sd0, 16'sd32767, 8'd128, 16'sd16383, "frac 128 midpoint");
    check(16'sd0, 16'sd32767, 8'd255, 16'sd32639, "frac 255 near b");
    check(16'sd1234, 16'sd1234, 8'd200, 16'sd1234, "a == b");
    check(-16'sd32768, 16'sd32767, 8'd128, -16'sd1, "sign crossing");
    $display("TB_WT_MIX PASS");
    $finish;
  end
endmodule
