// Unit test for the 32-voice wavetable buffers.
//
// The scan side writes phases and reads samples; the table engine reads phases
// and writes samples. Both sides address one slot per cycle, so the test checks
// that a write on one side is visible to the other on the next cycle and that
// neighbouring slots are untouched.
//
// The scan side has a read address (the voice the pipeline is calculating) and a
// phase-write address (the voice the bank is writing one stage later); the last
// case checks that the two can differ in the same cycle.
module tb_wt_voice_bufs;
  logic clk = 0, rst_n = 0;
  logic        scan_en = 0;
  logic [4:0]  scan_slot = 5'd0;
  logic [4:0]  scan_wr_slot = 5'd0;
  logic        scan_phase_we = 0;
  logic [31:0] scan_phase_a = 32'd0, scan_phase_b = 32'd0;
  logic signed [15:0] scan_sample_a, scan_sample_b;

  logic        eng_en = 0;
  logic [4:0]  eng_slot = 5'd0;
  logic [31:0] eng_phase_a, eng_phase_b;
  logic        eng_sample_we = 0;
  logic signed [15:0] eng_sample_a = 16'sd0, eng_sample_b = 16'sd0;

  v2_wt_voice_bufs dut (
    .clk, .rst_n,
    .scan_en, .scan_slot, .scan_wr_slot, .scan_phase_we, .scan_phase_a, .scan_phase_b,
    .scan_sample_a, .scan_sample_b,
    .eng_en, .eng_slot,
    .eng_phase_a, .eng_phase_b,
    .eng_sample_we, .eng_sample_a, .eng_sample_b
  );

  always #5 clk = ~clk;

  task automatic step; @(negedge clk); @(negedge clk); endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1;
    repeat (2) @(negedge clk);

    // 1. Reset leaves every slot empty.
    eng_en = 1; eng_slot = 5'd7; scan_en = 1; scan_slot = 5'd7; scan_wr_slot = 5'd7;
    #1;
    if (eng_phase_a !== 32'd0 || eng_phase_b !== 32'd0)
      $fatal(1, "FAIL reset phases slot7: %h %h", eng_phase_a, eng_phase_b);
    if (scan_sample_a !== 16'sd0 || scan_sample_b !== 16'sd0)
      $fatal(1, "FAIL reset samples slot7: %0d %0d", scan_sample_a, scan_sample_b);
    $display("PASS reset clears slot 7");

    // 2. Scan side writes phases; engine side must see them.
    scan_slot = 5'd7; scan_wr_slot = 5'd7; scan_phase_we = 1;
    scan_phase_a = 32'h1234_5678; scan_phase_b = 32'h9ABC_DEF0;
    step;
    scan_phase_we = 0;
    eng_slot = 5'd7; #1;
    if (eng_phase_a !== 32'h1234_5678 || eng_phase_b !== 32'h9ABC_DEF0)
      $fatal(1, "FAIL phase readback slot7: %h %h", eng_phase_a, eng_phase_b);
    $display("PASS scan writes phases, engine reads them");

    // 3. Engine side writes samples; scan side must see them.
    eng_slot = 5'd7; eng_sample_we = 1;
    eng_sample_a = 16'sd1111; eng_sample_b = -16'sd2222;
    step;
    eng_sample_we = 0;
    scan_slot = 5'd7; #1;
    if (scan_sample_a !== 16'sd1111 || scan_sample_b !== -16'sd2222)
      $fatal(1, "FAIL sample readback slot7: %0d %0d", scan_sample_a, scan_sample_b);
    $display("PASS engine writes samples, scan reads them");

    // 4. Slot 8 is untouched by everything written to slot 7.
    eng_slot = 5'd8; scan_slot = 5'd8; #1;
    if (eng_phase_a !== 32'd0 || eng_phase_b !== 32'd0 ||
        scan_sample_a !== 16'sd0 || scan_sample_b !== 16'sd0)
      $fatal(1, "FAIL slot 8 crosstalk: %h %h %0d %0d",
             eng_phase_a, eng_phase_b, scan_sample_a, scan_sample_b);
    $display("PASS slot 8 untouched");

    // 5. Writing slot 31 works and does not disturb slot 7.
    scan_slot = 5'd31; scan_wr_slot = 5'd31; scan_phase_we = 1;
    scan_phase_a = 32'hFFFF_0000; scan_phase_b = 32'h0000_FFFF;
    eng_slot = 5'd31; eng_sample_we = 1; eng_sample_a = 16'sd30000; eng_sample_b = -16'sd30000;
    step;
    scan_phase_we = 0; eng_sample_we = 0;
    scan_slot = 5'd31; #1;
    if (scan_sample_a !== 16'sd30000 || scan_sample_b !== -16'sd30000)
      $fatal(1, "FAIL slot 31 samples: %0d %0d", scan_sample_a, scan_sample_b);
    eng_slot = 5'd31; #1;
    if (eng_phase_a !== 32'hFFFF_0000 || eng_phase_b !== 32'h0000_FFFF)
      $fatal(1, "FAIL slot 31 phases: %h %h", eng_phase_a, eng_phase_b);
    scan_slot = 5'd7; #1;
    if (scan_sample_a !== 16'sd1111)
      $fatal(1, "FAIL slot 7 disturbed by slot 31: %0d", scan_sample_a);
    $display("PASS slot 31 write, slot 7 intact");

    // 6. Read and phase-write addresses are independent in one cycle: the scan
    //    reads slot 8's sample while it writes slot 7's phase.
    scan_slot = 5'd8; scan_wr_slot = 5'd7; scan_phase_we = 1;
    scan_phase_a = 32'h0BAD_F00D; scan_phase_b = 32'hC0FF_EE00;
    step;
    scan_phase_we = 0;
    eng_slot = 5'd7; #1;
    if (eng_phase_a !== 32'h0BAD_F00D || eng_phase_b !== 32'hC0FF_EE00)
      $fatal(1, "FAIL split-address phase write: %h %h", eng_phase_a, eng_phase_b);
    scan_slot = 5'd8; eng_slot = 5'd8; #1;
    if (eng_phase_a !== 32'd0)
      $fatal(1, "FAIL the phase write went to the read address: %h", eng_phase_a);
    $display("PASS split read and phase-write addresses");

    $finish;
  end
endmodule
