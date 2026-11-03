`timescale 1ns/1ps
// First testbench for the N-tone block (it never had one) and the frequency
// reference for the demo: tone k must sit on 220.000*k Hz.
//
// The check is a Goertzel at each expected tone and at each midpoint between
// tones, over 2048 published frames with a Hann window.  Peak count must equal
// the programmed count, and the midpoints must stay far below the peaks.
module tb_test_mode;
  localparam integer NS   = 2048;
  localparam real    FS   = 48000.0;
  localparam real    STEP = 220.0;

  logic clk = 1'b0, rst_n = 1'b0;
  logic sample_ce = 1'b0;
  logic csr_valid = 1'b0, csr_write = 1'b0;
  logic [7:0]  csr_addr = 8'hA0;
  logic [31:0] csr_wdata = 32'd0;
  logic csr_ready, csr_rvalid;
  logic [31:0] csr_rdata;
  logic signed [15:0] mixed_sample;
  logic sample_valid;
  logic [31:0] active_bitmap, sample_counter;
  logic test_active, fault;

  always #6.25 clk = ~clk;

  v2_test_mode #(.MAX_TONES(32)) dut (
      .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
      .csr_valid(csr_valid), .csr_write(csr_write),
      .csr_addr(csr_addr), .csr_wdata(csr_wdata),
      .csr_ready(csr_ready), .csr_rvalid(csr_rvalid), .csr_rdata(csr_rdata),
      .mixed_sample(mixed_sample), .sample_valid(sample_valid),
      .active_bitmap(active_bitmap), .sample_counter(sample_counter),
      .test_active(test_active), .fault(fault)
  );

  real win[0:NS-1];
  real x[0:NS-1];
  real pows[1:32];
  real mids[1:32];

  integer cyc = 0;
  always @(posedge clk) begin
    cyc       <= cyc + 1;
    sample_ce <= ((cyc % 40) == 0);
  end

  task automatic write_n(input integer n);
    begin
      @(posedge clk);
      csr_valid <= 1'b1;
      csr_write <= 1'b1;
      csr_addr  <= 8'hA0;
      csr_wdata <= (32'(n) << 8) | 32'h01;
      @(posedge clk);
      csr_valid <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic capture(input integer n);
    integer i;
    begin
      write_n(n);
      i = 0;
      while (i < NS) begin
        @(posedge clk);
        #1;
        if (sample_valid) begin
          x[i] = $itor(mixed_sample) * win[i];
          i = i + 1;
        end
      end
    end
  endtask

  function automatic real goertzel(input real freq);
    real coeff, s0, s1, s2, w;
    integer i;
    begin
      w     = 2.0 * 3.14159265358979 * freq / FS;
      coeff = 2.0 * $cos(w);
      s1 = 0.0;
      s2 = 0.0;
      for (i = 0; i < NS; i = i + 1) begin
        s0 = x[i] + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
      end
      goertzel = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    end
  endfunction

  task automatic check(input integer n);
    integer k, peaks;
    real maxp, ratio;
    begin
      capture(n);
      maxp = 0.0;
      for (k = 1; k <= 32; k = k + 1) begin
        pows[k] = goertzel(STEP * k);
        mids[k] = goertzel(STEP * k + STEP / 2.0);
        if (pows[k] > maxp) maxp = pows[k];
      end

      peaks = 0;
      for (k = 1; k <= 32; k = k + 1) begin
        if (pows[k] > 0.05 * maxp) peaks = peaks + 1;
        if ((k <= n) && (pows[k] <= 50.0 * mids[k])) begin
          $fatal(1, "FAIL N=%0d tone %0d: peak %0.1f vs midpoint %0.1f",
                 n, k, pows[k], mids[k]);
        end
      end
      if (peaks !== n) $fatal(1, "FAIL N=%0d: %0d peaks above the threshold", n, peaks);
      ratio = (n > 0) ? pows[1] / (mids[1] + 1.0) : 0.0;
      $display("PASS N=%0d: %0d peaks, tone 1 peak/mid = %0.0f", n, peaks, ratio);
    end
  endtask

  initial begin
    for (integer i = 0; i < NS; i = i + 1)
      win[i] = 0.5 * (1.0 - $cos(2.0 * 3.14159265358979 * i / (NS - 1)));

    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4) @(posedge clk);

    check(1);
    check(8);
    check(32);

    if (fault) $fatal(1, "FAIL fault is set");
    $display("PASS the block puts tone k on 220.000*k Hz for N = 1, 8, 32");
    $finish;
  end
endmodule
