// Unit test for the wavetable playback engine: the table must advance at the
// rate an external increment asks for, not at a fixed 46.875 Hz.
module tb_wt_playback;
  logic clk = 0, rst_n = 0, sample_ce = 0, enable = 1;
  logic [9:0] index;
  logic signed [15:0] sample = 16'sd1000, out;
  logic valid;
  logic [31:0] increment = 32'd0;
  logic [9:0] prev_index = 10'd0;
  int wraps, i;

  v2_wt_playback dut(.clk, .rst_n, .sample_ce, .enable, .index, .sample, .out, .valid, .increment);

  always #5 clk = ~clk;

  // One pass of n_samples sample_ce pulses. A wrap is the index going backwards,
  // which is robust whether the increment is 1 point (46.875 Hz) or 9.39 points
  // (440 Hz) per sample.
  task automatic run(input logic [31:0] inc, input int n_samples);
    rst_n = 0; repeat (2) @(negedge clk); rst_n = 1;
    increment = inc; wraps = 0; prev_index = 10'd0;
    for (i = 0; i < n_samples; i++) begin
      @(negedge clk); sample_ce = 1;
      @(negedge clk); sample_ce = 0;
      if (index < prev_index) wraps++;
      prev_index = index;
    end
  endtask

  initial begin
    run(32'd39370534, 48000);                       // A4 = 440 Hz
    if (wraps < 439 || wraps > 441) $fatal(1, "FAIL a4_wraps: %0d (expect 440)", wraps);
    $display("PASS a4_wraps = %0d", wraps);

    run(32'd4194304, 48000);                        // legacy 46.875 Hz = one point per sample
    if (wraps < 46 || wraps > 47) $fatal(1, "FAIL legacy_wraps: %0d (expect 46..47)", wraps);
    $display("PASS legacy_wraps = %0d", wraps);

    run(32'd0, 4096);                               // increment 0 = silence
    if (wraps != 0) $fatal(1, "FAIL zero_increment_wraps: %0d", wraps);
    if (index != 10'd0) $fatal(1, "FAIL zero_increment_index: %0d", index);
    $display("PASS zero_increment");

    $finish;
  end
endmodule
