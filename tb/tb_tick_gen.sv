// Unit test for the musical tick generator.
//
// A BPM write must produce samples_per_tick = round(720000 / BPM), and the tick
// pulse must fire exactly once per that many sample_ce cycles.
module tb_tick_gen;
  logic clk = 0, rst_n = 0, sample_ce = 0;
  logic [15:0] bpm = 16'd120;
  logic bpm_we = 0;
  logic tick_pulse;
  logic [6:0] tick;
  logic [23:0] samples_per_tick;
  int i, pulses;

  v2_tick_gen dut(.clk, .rst_n, .sample_ce, .bpm, .bpm_we, .tick_pulse, .tick, .samples_per_tick);

  always #5 clk = ~clk;

  task automatic set_bpm(input logic [15:0] value, input logic [23:0] expect_spt);
    bpm = value; bpm_we = 1;
    @(negedge clk); bpm_we = 0;
    repeat (40) @(negedge clk);            // 20-step divider plus margin
    if (samples_per_tick !== expect_spt)
      $fatal(1, "FAIL spt(bpm=%0d): got %0d want %0d", value, samples_per_tick, expect_spt);
    $display("PASS spt(bpm=%0d) = %0d", value, samples_per_tick);
    if (tick !== 7'd0) $fatal(1, "FAIL tick not cleared on bpm write: %0d", tick);
  endtask

  task automatic run_ticks(input int n_samples, input int expect_pulses);
    pulses = 0;
    for (i = 0; i < n_samples; i++) begin
      @(negedge clk); sample_ce = 1;
      @(negedge clk); sample_ce = 0;
      if (tick_pulse) pulses++;
    end
    if (pulses != expect_pulses)
      $fatal(1, "FAIL pulses over %0d samples: got %0d want %0d", n_samples, pulses, expect_pulses);
    $display("PASS %0d pulses over %0d samples", pulses, n_samples);
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1;
    repeat (2) @(negedge clk);

    set_bpm(16'd120, 24'd6000);            // 48000*60/(120*4)
    run_ticks(6000, 1);
    run_ticks(6000, 1);
    if (tick !== 7'd2) $fatal(1, "FAIL tick count: %0d want 2", tick);
    $display("PASS tick counter = %0d", tick);

    set_bpm(16'd100, 24'd7200);
    run_ticks(7200, 1);

    set_bpm(16'd240, 24'd3000);
    run_ticks(3000, 1);
    $finish;
  end
endmodule
