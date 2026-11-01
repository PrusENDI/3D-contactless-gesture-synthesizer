// Track mode must keep working on degraded frames: `degraded` means reduced
// precision, not unusable Y.  Only a real frame gap should block the note path.
module tb_live_track_pitch;
  logic clk = 0, rst_n = 0;
  logic frame_in_valid = 0, frame_valid = 1, frame_degraded = 1, frame_gap = 0, rebased = 0;
  logic left_edge = 0;
  logic [15:0] x = 0, y = 0, z = 16'd30000;
  logic touch = 0, bow = 1;
  logic [31:0] tick = 0;
  logic arp_mode = 0, tick_pulse = 0;
  logic [6:0] mtick = 0;
  logic [7:0] velocity_in = 8'd100;
  logic [15:0] brightness_in = 0, gain_in = 16'd200;
  logic event_valid, event_ready = 1;
  logic [95:0] event_data;
  logic [3:0] event_type;
  logic [7:0] event_note, event_velocity;
  logic [15:0] event_count;
  logic [7:0] fault_code;
  logic left_edge_armed, gate_state, active;
  logic [7:0] active_note;
  int i;

  v2_live_rule_engine #(.PIPELINE_NOTE(1), .TRACK(0)) dut (
    .clk, .rst_n,
    .frame_in_valid, .frame_valid, .frame_degraded, .frame_gap, .rebased, .left_edge,
    .x, .y, .z, .touch, .bow, .tick,
    .arp_mode, .tick_pulse, .mtick,
    .velocity_in, .brightness_in, .gain_in,
    .event_valid, .event_ready, .event_data,
    .event_type, .event_note, .event_velocity, .event_count, .fault_code,
    .left_edge_armed, .gate_state, .active, .active_note
  );

  always #5 clk = ~clk;

  // The rule engine's tick input is sample_index in the top; candidate_due
  // compares it, so a frozen tick would suppress every event after the first.
  always @(posedge clk) tick <= tick + 32'd1;

  task automatic send_frame(input [15:0] xv, input [15:0] yv);
    begin
      @(negedge clk); x = xv; y = yv; frame_in_valid = 1;
      @(negedge clk); frame_in_valid = 0;
      repeat (3) @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk); rst_n = 1; repeat (4) @(negedge clk);

    // Arm: enter at the left edge, then move right.
    send_frame(16'd0, 16'd20000);
    send_frame(16'd0, 16'd20000);
    send_frame(16'd5000, 16'd20000);
    send_frame(16'd20000, 16'd20000);
    repeat (4) @(negedge clk);

    if (dut.active !== 1'b1) $fatal(1, "FAIL no note on a degraded frame stream (active=0)");
    if (active_note !== 8'd60) $fatal(1, "FAIL note=%0d want 60 for y=20000", active_note);
    $display("PASS note started on degraded frames: note=%0d", active_note);

    // Move up to G4 (y=45000) and let a few frames carry the change.
    for (i = 0; i < 6; i = i + 1) send_frame(16'd20000, 16'd45000);
    repeat (4) @(negedge clk);
    if (active_note !== 8'd67)
      $fatal(1, "FAIL pitch did not follow Y on degraded frames: note=%0d want 67", active_note);
    $display("PASS pitch follows Y on degraded frames: note=%0d", active_note);
    $finish;
  end

  initial begin
    #200_000;
    $fatal(1, "TIMEOUT");
  end
endmodule
