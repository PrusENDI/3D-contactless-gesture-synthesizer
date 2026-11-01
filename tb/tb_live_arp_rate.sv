// Arpeggiator event rate: one tick must pack exactly one OFF (when a note is on)
// and one ON.  The pipeline registers the candidate, so the FSM must advance on
// the combinational candidate; advancing on the registered copy packs it twice.
module tb_live_arp_rate;
  logic clk = 0, rst_n = 0;
  logic frame_in_valid = 0, frame_valid = 1, frame_degraded = 0, frame_gap = 0, rebased = 0;
  logic left_edge = 0;
  logic [15:0] x = 16'd32768, y = 16'd40000, z = 16'd30000;
  logic touch = 0, bow = 1;
  logic [31:0] tick = 0;
  logic arp_mode = 1, tick_pulse = 0;
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

  int ons = 0, offs = 0, others = 0;
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

  always @(posedge clk) begin
    if (rst_n && event_valid && event_ready) begin
      case (event_data[94:91])
        4'd1: ons  = ons + 1;
        4'd2: offs = offs + 1;
        default: others = others + 1;
      endcase
    end
  end

  task automatic pulse_frame();
    begin
      @(negedge clk); frame_in_valid = 1;
      @(negedge clk); frame_in_valid = 0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic do_tick();
    begin
      @(negedge clk); tick_pulse = 1;
      @(negedge clk); tick_pulse = 0;
      repeat (18) @(negedge clk);
    end
  endtask

  // Backpressure: the voice engine is busy for ~32 cycles every sample, so a
  // tick can hit a stalled event_ready.  The FSM must not re-pack the held step.
  task automatic do_tick_stalled();
    begin
      @(negedge clk); tick_pulse = 1;
      @(negedge clk); tick_pulse = 0;
      repeat (3) @(negedge clk);
      event_ready = 0;
      repeat (40) @(negedge clk);
      event_ready = 1;
      repeat (40) @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);
    pulse_frame();                 // load y into the pipeline so map_note is valid
    pulse_frame();

    for (i = 0; i < 9; i = i + 1) begin
      if (i == 3) do_tick_stalled();
      else        do_tick();
    end

    // First tick only starts a note (no OFF); the other eight ticks are OFF+ON.
    if (ons != 9 || offs != 8 || others != 0)
      $fatal(1, "FAIL arp rate: on=%0d off=%0d other=%0d (want 9/8/0)", ons, offs, others);
    $display("PASS arp 9 ticks -> on=%0d off=%0d (2 events per tick after the first)", ons, offs);
    $finish;
  end

  initial begin
    #500_000;
    $fatal(1, "TIMEOUT");
  end
endmodule
