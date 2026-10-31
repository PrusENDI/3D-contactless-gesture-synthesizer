// Frame-crossfade continuity test.
//
// Mirrors the top's wiring: the table samples arrive one cycle after the frame
// select (loader registered select), so the crossfade fraction must be delayed
// by the same cycle.  With an undelayed frac the output reverts to the old frame
// for one sample at every pair crossing (pos = 1.0 and 2.0), which is a click.
module tb_wt_morph;
  logic clk = 0, rst_n = 0, sample_ce = 0, morph_en = 0;
  logic [22:0] step = 23'h100000;          // 1.0 per 16 samples
  logic [25:0] pos;
  logic [1:0] fa, fb;
  logic [7:0] frac;
  logic signed [15:0] a_q, b_q;
  logic signed [15:0] mix;
  logic [1:0] fa_d, fb_d;
  logic [7:0] frac_d;
  logic [7:0] frac_q;
  int i, bad;

  v2_wt_position u_pos(.clk, .rst_n, .sample_ce, .morph_en, .step,
                       .pos, .frame_a(fa), .frame_b(fb), .frac(frac));

  function automatic logic signed [15:0] tbl(input logic [1:0] f);
    case (f)
      2'd0: tbl = 16'sd1000;
      2'd1: tbl = 16'sd2000;
      default: tbl = 16'sd3000;
    endcase
  endfunction

  // Loader model: the word lags the select by one cycle.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_q <= 16'sd0; b_q <= 16'sd0;
      fa_d <= 2'd0; fb_d <= 2'd0; frac_d <= 8'd0;
      frac_q <= 8'd0;
    end else begin
      a_q <= tbl(fa);
      b_q <= tbl(fb);
      fa_d <= fa;
      fb_d <= fb;
      frac_d <= frac;
      frac_q <= frac;
    end
  end

  v2_wt_mix u_mix(.a(a_q), .b(b_q), .frac(frac_q), .out(mix));

  function automatic logic signed [15:0] ideal(input logic [1:0] fa_i,
                                               input logic [1:0] fb_i,
                                               input logic [7:0] fr);
    logic signed [16:0] d;
    logic signed [24:0] p;
    begin
      d = $signed({tbl(fb_i)[15], tbl(fb_i)}) - $signed({tbl(fa_i)[15], tbl(fa_i)});
      p = d * $signed({1'b0, fr});
      ideal = tbl(fa_i) + (p >>> 8);
    end
  endfunction

  always #5 clk = ~clk;

  task automatic tick(input int n);
    begin
      for (i = 0; i < n; i++) begin
        @(negedge clk); sample_ce = 1;
        @(negedge clk); sample_ce = 0;
        if (mix !== ideal(fa_d, fb_d, frac_d)) begin
          if (bad < 6)
            $display("MISMATCH pos=%0h a=%0d b=%0d f=%0h mix=%0d ideal=%0d",
                     pos, fa_d, fb_d, frac_d, mix, ideal(fa_d, fb_d, frac_d));
          bad = bad + 1;
        end
      end
    end
  endtask

  initial begin
    bad = 0;
    repeat (4) @(negedge clk); rst_n = 1; morph_en = 1;
    tick(200);
    if (bad != 0) $fatal(1, "FAIL %0d crossfade samples disagree with the ideal blend", bad);
    $display("PASS TB_WT_MORPH (200 samples, 6 legs)");
    $finish;
  end
endmodule
