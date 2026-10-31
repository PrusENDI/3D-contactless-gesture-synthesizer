// Unit test for the Q2.24 wavetable position LFO.
//
// The LFO walks position 0..2.0 and back at `step` per sample.  Frame index and
// frac are pure slices of position, so the mapping is checked by poking `pos`
// directly instead of waiting for a sweep.
module tb_wt_position;
  localparam logic [25:0] ONE = 26'h1000000, TWO = 26'h2000000;
  logic clk = 0, rst_n = 0, sample_ce = 0, morph_en = 0;
  logic [22:0] step = 23'd65536;
  logic [25:0] pos; logic [1:0] frame_a, frame_b; logic [7:0] frac;
  int i;

  v2_wt_position dut(.clk, .rst_n, .sample_ce, .morph_en, .step,
                     .pos, .frame_a, .frame_b, .frac);
  always #5 clk = ~clk;

  task automatic tick(input int n);
    for (i = 0; i < n; i++) begin
      @(negedge clk); sample_ce = 1;
      @(negedge clk); sample_ce = 0;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1; morph_en = 1; repeat (2) @(negedge clk);
    if (pos !== 26'd0) $fatal(1, "FAIL reset pos=%0h", pos);

    tick(512);                                  // 2^25 / 2^16 = 512
    if (pos !== TWO) $fatal(1, "FAIL up end pos=%0h", pos);
    if (!(frame_a == 2'd2 && frame_b == 2'd2 && frac == 8'd0))
      $fatal(1, "FAIL end frame a=%0d b=%0d frac=%0d", frame_a, frame_b, frac);
    tick(512);
    if (pos !== 26'd0) $fatal(1, "FAIL down end pos=%0h", pos);
    $display("PASS period 512 up and down");

    step = 23'd0;                                // 停住
    tick(100);
    if (pos !== 26'd0) $fatal(1, "FAIL step0 moved pos=%0h", pos);
    $display("PASS step 0 holds");

    dut.pos = 26'h0C00000; #1;                    // 0.75
    if (!(frame_a == 2'd0 && frame_b == 2'd1 && frac == 8'hC0))
      $fatal(1, "FAIL 0.75 mapping a=%0d b=%0d f=%0h", frame_a, frame_b, frac);
    dut.pos = 26'h1800000; #1;                    // 1.5
    if (!(frame_a == 2'd1 && frame_b == 2'd2 && frac == 8'h80))
      $fatal(1, "FAIL 1.5 mapping a=%0d b=%0d f=%0h", frame_a, frame_b, frac);
    dut.pos = 26'h2000000; #1;                    // 2.0
    if (!(frame_a == 2'd2 && frame_b == 2'd2 && frac == 8'd0))
      $fatal(1, "FAIL 2.0 mapping a=%0d b=%0d f=%0h", frame_a, frame_b, frac);
    $display("PASS frame mapping");

    dut.pos = 26'h1234000;                       // 非零，验证 enable 沿复位
    morph_en = 0; tick(2); morph_en = 1; tick(1);
    if (pos > 26'h100000) $fatal(1, "FAIL morph_en rising did not reset pos=%0h", pos);
    $display("PASS enable reset");
    $display("TB_WT_POSITION PASS");
    $finish;
  end
endmodule
