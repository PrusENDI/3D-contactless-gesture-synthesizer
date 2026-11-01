// Unit test for the wavetable engine that fills the per-voice sample buffer.
//
// The engine walks VOICES slots; for each slot it reads the phase pair, issues two
// table reads (frame A and frame B) at the same index, crossfades them with `frac`,
// scales by `shift`, and writes the sample pair into the buffer.
//
// The testbench plays the loader: it answers rd_en with data one cycle later and
// keeps rd_valid high, then compares every written sample with an independently
// computed expectation.
module tb_wt_voice_engine;
  localparam integer VOICES = 4;
  localparam integer DEPTH  = 1024;

  logic clk = 0, rst_n = 0, sample_ce = 0;
  logic [1:0] frame_a = 2'd0, frame_b = 2'd1;
  logic [7:0] frac = 8'h80;
  logic [3:0] shift = 4'd0;

  logic [31:0] phase_a [0:VOICES-1];
  logic [31:0] phase_b [0:VOICES-1];
  logic [4:0]  slot;
  logic signed [15:0] tab0 [0:DEPTH-1];
  logic signed [15:0] tab1 [0:DEPTH-1];

  logic rd_en0, rd_en1;
  logic [1:0] rd_table0, rd_table1;
  logic [9:0] rd_index0, rd_index1;
  logic signed [15:0] rd_sample0, rd_sample1;
  logic rd_valid0 = 1'b1, rd_valid1 = 1'b1;

  logic sample_we;
  logic signed [15:0] sample_a, sample_b;

  logic signed [15:0] wr_a [0:VOICES-1];
  logic signed [15:0] wr_b [0:VOICES-1];
  int writes, i, errors;
  integer k;

  v2_wt_voice_engine #(.VOICES(VOICES)) dut (
    .clk, .rst_n, .sample_ce,
    .frame_a, .frame_b, .frac, .shift,
    .phase_a_in(phase_a[slot]), .phase_b_in(phase_b[slot]),
    .slot,
    .rd_en0, .rd_table0, .rd_index0,
    .rd_en1, .rd_table1, .rd_index1,
    .rd_sample0, .rd_sample1, .rd_valid0, .rd_valid1,
    .sample_we, .sample_a, .sample_b
  );

  always #5 clk = ~clk;

  // Loader stand-in: registered read, one cycle of latency.
  always_ff @(posedge clk) begin
    if (rd_en0) rd_sample0 <= (rd_table0 == 2'd0) ? tab0[rd_index0] : tab1[rd_index0];
    if (rd_en1) rd_sample1 <= (rd_table1 == 2'd0) ? tab0[rd_index1] : tab1[rd_index1];
  end

  // Capture writes.  Reset lives here so wr_a/wr_b have a single driver.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < VOICES; k++) begin
        wr_a[k] <= 16'sd0;
        wr_b[k] <= 16'sd0;
      end
    end else if (sample_we) begin
      if (slot < VOICES) begin
        wr_a[slot] <= sample_a;
        wr_b[slot] <= sample_b;
      end
      writes <= writes + 1;
    end
  end

  function automatic signed [15:0] mix(input signed [15:0] a, input signed [15:0] b, input [7:0] f);
    logic signed [16:0] diff;
    logic signed [25:0] prod;
    diff = $signed({b[15], b}) - $signed({a[15], a});
    prod = diff * $signed({1'b0, f});
    mix  = a + (prod >>> 8);
  endfunction

  initial begin
    for (i = 0; i < DEPTH; i++) begin
      tab0[i] = (i * 8) - 4000;
      tab1[i] = 4000 - (i * 4);
    end
    for (i = 0; i < VOICES; i++) begin
      phase_a[i] = i << 22;            // idx_a = i
      phase_b[i] = (i + 512) << 22;    // idx_b = i + 512
    end

    repeat (3) @(negedge clk); rst_n = 1;

    // One sample enable starts one full sweep over all slots.
    @(negedge clk); sample_ce = 1;
    @(negedge clk); sample_ce = 0;
    repeat (5 * VOICES + 20) @(negedge clk);

    if (writes != VOICES)
      $fatal(1, "FAIL writes: got %0d want %0d", writes, VOICES);

    errors = 0;
    for (i = 0; i < VOICES; i++) begin
      automatic logic signed [15:0] ea = mix(tab0[i], tab1[i], frac) >> shift;
      automatic logic signed [15:0] eb = mix(tab0[i + 512], tab1[i + 512], frac) >> shift;
      if (wr_a[i] !== ea) begin
        $display("FAIL slot %0d a: got %0d want %0d", i, wr_a[i], ea); errors++;
      end
      if (wr_b[i] !== eb) begin
        $display("FAIL slot %0d b: got %0d want %0d", i, wr_b[i], eb); errors++;
      end
    end
    if (errors != 0) $fatal(1, "FAIL %0d sample mismatches", errors);
    $display("PASS %0d voices, two table reads each, frac crossfade, shift applied", VOICES);
    $finish;
  end
endmodule
