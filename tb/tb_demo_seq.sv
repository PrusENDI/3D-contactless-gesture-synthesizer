`timescale 1ns/1ps
// The demo sequencer must walk 1 -> 8 -> 32 and never write the word that
// lights the test block's sticky fault (32'h0000_0000).
module tb_demo_seq;
  localparam integer TONE = 8;
  localparam integer HOLD = 8;
  localparam integer GAP  = 4;

  logic clk = 1'b0, rst_n = 1'b0;
  logic sample_ce = 1'b0;
  logic csr_valid, csr_write;
  logic [7:0] csr_addr;
  logic [31:0] csr_wdata;
  logic [5:0] tone_count;
  logic muted;
  logic [1:0] segment;

  always #6.25 clk = ~clk;   // 80 MHz, the domain the scheduler runs in

  v2_demo_sequencer #(
      .TONE_FRAMES(TONE), .HOLD32_FRAMES(HOLD), .GAP_FRAMES(GAP)
  ) dut (
      .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
      .csr_valid(csr_valid), .csr_write(csr_write),
      .csr_addr(csr_addr), .csr_wdata(csr_wdata),
      .demo_tone_count(tone_count), .demo_muted(muted), .demo_segment(segment)
  );

  logic [31:0] want[0:2];
  integer writes = 0;
  integer errors = 0;
  integer cyc = 0;
  integer widx = 0;

  initial begin
    want[0] = 32'h0000_0101;   // N=1
    want[1] = 32'h0000_0801;   // N=8
    want[2] = 32'h0000_2001;   // N=32
  end

  // One sample_ce every eight clocks: the phase spans are counted in frames.
  always @(posedge clk) begin
    cyc      <= cyc + 1;
    sample_ce <= ((cyc % 8) == 7);
  end

  // A write is one cycle wide, to 0xA0, with the word the RTL expects.
  always @(posedge clk) begin
    if (rst_n && csr_valid) begin
      writes = writes + 1;
      if (csr_addr !== 8'hA0) begin
        errors = errors + 1;
        $display("FAIL csr_addr %02h at write %0d", csr_addr, writes);
      end
      if (csr_wdata !== want[widx % 3]) begin
        errors = errors + 1;
        $display("FAIL word %08h at write %0d, want %08h",
                 csr_wdata, writes, want[widx % 3]);
      end
      if (csr_wdata === 32'h0000_0000) begin
        errors = errors + 1;
        $display("FAIL wrote 0x0: that is a sticky fault, not a mute");
      end
      widx = widx + 1;
    end
  end

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;

    // Nine segments (three rounds of 1-8-32).  Each segment is TONE frames plus
    // GAP muted frames; the loop stops just before the tenth would begin.
    repeat (9 * (TONE + GAP) * 8 + 4) @(posedge clk);

    if (errors != 0) $fatal(1, "FAIL %0d error(s)", errors);
    if (writes !== 9) $fatal(1, "FAIL %0d writes, want 9", writes);
    if (tone_count === 6'd0) $fatal(1, "FAIL the count never left 0");
    $display("PASS %0d writes, %0d errors, last count %0d muted %0b",
             writes, errors, tone_count, muted);
    $finish;
  end
endmodule
