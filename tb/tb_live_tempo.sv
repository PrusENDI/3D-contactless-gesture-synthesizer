// LIVE X-to-tempo mapping: a cursor frame must update the divider tempo, and a
// frame that does not change the target must not pulse the divider write.
module tb_live_tempo;
  logic clk = 0, rst_n = 0, frame = 0;
  logic [15:0] x = 16'd0;
  logic [15:0] bpm;
  logic bpm_we;
  int pulses = 0;

  v2_live_tempo dut(.clk, .rst_n, .frame_done(frame), .x(x), .bpm(bpm), .bpm_we(bpm_we));
  always #5 clk = ~clk;
  always @(posedge clk) if (rst_n && bpm_we) pulses = pulses + 1;

  task automatic kick(input [15:0] xv);
    begin
      @(negedge clk); x = xv; frame = 1;
      @(negedge clk); frame = 0;
      repeat (5) @(negedge clk);
    end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    if (bpm !== 16'd120) $fatal(1, "FAIL reset bpm=%0d", bpm);

    kick(16'd0);
    if (bpm !== 16'd30) $fatal(1, "FAIL x=0 bpm=%0d want 30", bpm);
    if (pulses !== 1) $fatal(1, "FAIL x=0 write pulses=%0d", pulses);

    kick(16'd0);                       // same target: no divider write
    if (pulses !== 1) $fatal(1, "FAIL same target pulsed %0d", pulses);

    kick(16'hFFFF);
    if (bpm !== 16'd59) $fatal(1, "FAIL x=max bpm=%0d want 59", bpm);
    if (pulses !== 2) $fatal(1, "FAIL x=max write pulses=%0d", pulses);

    $display("PASS live tempo 120 -> 30 -> 59 with one write per change");
    $finish;
  end
endmodule
