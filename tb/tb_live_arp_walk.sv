`timescale 1ns/1ps
// G natural minor + the four-pattern LIVE step arpeggiator.
//
// 1. The step interval is measured on the real 125 ms divider: the counter is
//    nudged two clocks before its terminal value, then the bench measures the
//    time between two natural step pulses (12 500 000 clocks = 125 ms).
// 2. The walk patterns are exercised by forcing the divider's output, so twelve
//    steps cost twelve clocks instead of 1.5 s of simulated time.
// 3. The note ROM is checked for all eight scale degrees: a non-zero increment
//    whose frequency is within 1 Hz of equal temperament (A4 = 440).
//
// Pattern numbers match THRESHOLDS[26:25]: 0 follow Y, 1 walk up, 2 up-down,
// 3 pseudo-random.
module tb_live_arp_walk;
  localparam integer STEP_NS      = 125_000_000;      // 12 500 000 clocks at 100 MHz
  localparam integer SAMPLE_NS    = 20_834;           // one 48 kHz sample, rounded up
  localparam integer MAX_STEPS    = 12;

  logic clk = 1'b0, rst_n = 1'b0;
  logic frame_in_valid = 1'b0, frame_valid = 1'b1, frame_degraded = 1'b0;
  logic frame_gap = 1'b0, rebased = 1'b0, left_edge = 1'b0;
  logic [15:0] x = 16'd32768, y = 16'd20000, z = 16'd30000;
  logic touch = 1'b0, bow = 1'b1;
  logic [31:0] tick = 32'd0;
  logic arp_mode = 1'b0, tick_pulse = 1'b0;
  logic [6:0] mtick = 7'd0;
  logic [1:0] arp_pattern = 2'd0;
  logic [7:0] velocity_in = 8'd100;
  logic [15:0] brightness_in = 16'd0, gain_in = 16'd65535;
  logic event_valid, event_ready = 1'b1;
  logic [95:0] event_data;
  logic [3:0] event_type;
  logic [7:0] event_note, event_velocity;
  logic [15:0] event_count;
  logic [7:0] fault_code;
  logic left_edge_armed, gate_state, active;
  logic [7:0] active_note;

  logic tb_step = 1'b0;
  integer i, guard;
  time t1, t2, interval;

  // Note-ROM probe for the audibility assertion.
  logic [7:0]  rom_note;
  logic [31:0] rom_inc;
  integer scale_note [0:7];
  real    scale_hz   [0:7];
  real    f;

  v2_live_rule_engine #(.PIPELINE_NOTE(1), .TRACK(0)) dut (
    .clk, .rst_n,
    .frame_in_valid, .frame_valid, .frame_degraded, .frame_gap, .rebased, .left_edge,
    .x, .y, .z, .touch, .bow, .tick,
    .arp_mode, .tick_pulse, .mtick, .arp_pattern,
    .velocity_in, .brightness_in, .gain_in,
    .event_valid, .event_ready, .event_data,
    .event_type, .event_note, .event_velocity, .event_count, .fault_code,
    .left_edge_armed, .gate_state, .active, .active_note
  );

  v2_note_increment_rom u_rom(.note(rom_note), .increment(rom_inc));

  always #5 clk = ~clk;
  always @(posedge clk) tick <= tick + 32'd1;

  task automatic pulse_frame;
    begin
      @(negedge clk); frame_in_valid = 1'b1;
      @(negedge clk); frame_in_valid = 1'b0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic set_y(input [15:0] yv);
    begin
      y = yv;
      pulse_frame();
      pulse_frame();
    end
  endtask

  task automatic wait_rising;
    begin
      guard = 0;
      while (dut.arp_step_pulse !== 1'b1 && guard < 20_000_000) begin
        @(posedge clk); #1; guard = guard + 1;
      end
      if (dut.arp_step_pulse !== 1'b1) $fatal(1, "no arp step pulse from the divider");
    end
  endtask

  task automatic wait_next_rising;
    begin
      // Let the pulse that started this measurement fall first.
      guard = 0;
      while (dut.arp_step_pulse !== 1'b0 && guard < 100) begin
        @(posedge clk); #1; guard = guard + 1;
      end
      wait_rising;
    end
  endtask

  // Force the divider output for one cycle and return the NOTE_ON note.
  task automatic forced_step(output integer got_note);
    begin
      @(negedge clk); tb_step = 1'b1;
      @(negedge clk); tb_step = 1'b0;
      got_note = -1;
      guard = 0;
      while (got_note < 0 && guard < 500) begin
        @(negedge clk);
        if (dut.event_valid && dut.event_ready && (dut.event_data[94:91] == 4'd1))
          got_note = dut.event_data[71:64];
        guard = guard + 1;
      end
      if (got_note < 0) $fatal(1, "no NOTE_ON after a forced arp step");
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic reset_dut(input [1:0] pattern);
    begin
      rst_n = 1'b0; tb_step = 1'b0; arp_mode = 1'b0; bow = 1'b0;
      repeat (4) @(negedge clk);
      rst_n = 1'b1;
      repeat (4) @(negedge clk);
      arp_pattern = pattern;
      arp_mode = 1'b1;
      bow = 1'b1;
      touch = 1'b0;
      x = 16'd32768;
      set_y(16'd20000);
    end
  endtask

  task automatic expect_note(input integer index, input integer got, input integer want);
    begin
      if (got !== want)
        $fatal(1, "step %0d: note %0d, want %0d", index, got, want);
    end
  endtask

  integer got;
  integer distinct;
  integer seen [0:7];
  integer expected_up [0:11];
  integer expected_ud [0:11];
  integer follow_y [0:11];
  integer follow_note [0:11];

  initial begin : run_tb
    // ---------------------------------------------------------- note ROM ----
    scale_note[0] = 55; scale_note[1] = 57; scale_note[2] = 58; scale_note[3] = 60;
    scale_note[4] = 62; scale_note[5] = 63; scale_note[6] = 65; scale_note[7] = 67;
    scale_hz[0] = 195.9977; scale_hz[1] = 220.0000; scale_hz[2] = 233.0819;
    scale_hz[3] = 261.6256; scale_hz[4] = 293.6648; scale_hz[5] = 311.1270;
    scale_hz[6] = 349.2282; scale_hz[7] = 391.9954;
    for (i = 0; i < 8; i = i + 1) begin
      rom_note = scale_note[i][7:0];
      #1;
      if (rom_inc == 32'd0)
        $fatal(1, "note %0d has increment 0 (it would be silent)", scale_note[i]);
      f = $itor(rom_inc) * 48000.0 / 4294967296.0;
      if ((f < scale_hz[i] - 1.0) || (f > scale_hz[i] + 1.0))
        $fatal(1, "note %0d f=%f Hz, want %f +-1 Hz", scale_note[i], f, scale_hz[i]);
      $display("NOTE %0d increment %0d -> %.4f Hz (want %.4f)", scale_note[i], rom_inc, f,
               scale_hz[i]);
    end

    repeat (4) @(negedge clk); rst_n = 1'b1; repeat (4) @(negedge clk);

    // ------------------------------------------------ real 125 ms divider ----
    arp_pattern = 2'd1;
    arp_mode = 1'b1;
    bow = 1'b1;
    set_y(16'd20000);
    // Two clocks before the terminal count, so the first measured pulse comes
    // quickly; the gap to the second pulse is the full ARP_STEP_CYCLES.
    @(posedge clk); #1; dut.arp_div_q = 24'd12_499_998;
    wait_rising;
    t1 = $time;
    wait_next_rising;
    t2 = $time;
    interval = t2 - t1;
    $display("RESULT arp interval %0d ns (%0d clocks), want %0d ns +- %0d ns",
             interval, interval / 10, STEP_NS, SAMPLE_NS);
    if ((interval < STEP_NS - SAMPLE_NS) || (interval > STEP_NS + SAMPLE_NS))
      $fatal(1, "arp step interval %0d ns, want 125 ms +-1 sample", interval);

    // ------------------------------------------------------- patterns -------
    // Forced steps from here on.  The force survives reset; tb_step stays 0.
    force dut.arp_step_pulse = tb_step;

    expected_up[0]  = 55; expected_up[1]  = 57; expected_up[2]  = 58; expected_up[3]  = 60;
    expected_up[4]  = 62; expected_up[5]  = 63; expected_up[6]  = 65; expected_up[7]  = 67;
    expected_up[8]  = 55; expected_up[9]  = 57; expected_up[10] = 58; expected_up[11] = 60;
    expected_ud[0]  = 55; expected_ud[1]  = 57; expected_ud[2]  = 58; expected_ud[3]  = 60;
    expected_ud[4]  = 62; expected_ud[5]  = 63; expected_ud[6]  = 65; expected_ud[7]  = 67;
    expected_ud[8]  = 65; expected_ud[9]  = 63; expected_ud[10] = 62; expected_ud[11] = 60;
    follow_y[0] = 3000;  follow_y[1] = 8000;  follow_y[2] = 20000; follow_y[3] = 25000;
    follow_y[4] = 35000; follow_y[5] = 45000; follow_y[6] = 55000; follow_y[7] = 62000;
    follow_y[8] = 3000;  follow_y[9] = 45000; follow_y[10] = 8000; follow_y[11] = 62000;
    follow_note[0] = 55; follow_note[1] = 57; follow_note[2] = 58; follow_note[3] = 60;
    follow_note[4] = 62; follow_note[5] = 63; follow_note[6] = 65; follow_note[7] = 67;
    follow_note[8] = 55; follow_note[9] = 63; follow_note[10] = 57; follow_note[11] = 67;

    // Up.
    reset_dut(2'd1);
    for (i = 0; i < MAX_STEPS; i = i + 1) begin
      forced_step(got);
      expect_note(i, got, expected_up[i]);
    end
    $display("PASS pattern up   : %0d notes, top step 8 = %0d", MAX_STEPS, expected_up[7]);

    // Up-down.
    reset_dut(2'd2);
    for (i = 0; i < MAX_STEPS; i = i + 1) begin
      forced_step(got);
      expect_note(i, got, expected_ud[i]);
    end
    $display("PASS pattern up-down: %0d notes", MAX_STEPS);

    // Follow the hand: every step re-reads Y.
    reset_dut(2'd0);
    for (i = 0; i < MAX_STEPS; i = i + 1) begin
      set_y(follow_y[i][15:0]);
      forced_step(got);
      expect_note(i, got, follow_note[i]);
    end
    $display("PASS pattern follow : %0d notes track Y", MAX_STEPS);

    // Random: every step is one of the eight, and not always the same one.
    reset_dut(2'd3);
    for (i = 0; i < 8; i = i + 1) seen[i] = 0;
    for (i = 0; i < MAX_STEPS; i = i + 1) begin
      forced_step(got);
      distinct = 0;
      if (got == 55 || got == 57 || got == 58 || got == 60 ||
          got == 62 || got == 63 || got == 65 || got == 67) distinct = 1;
      if (!distinct) $fatal(1, "random step %0d emitted note %0d, not in the scale", i, got);
      case (got)
        55: seen[0] = 1; 57: seen[1] = 1; 58: seen[2] = 1; 60: seen[3] = 1;
        62: seen[4] = 1; 63: seen[5] = 1; 65: seen[6] = 1; 67: seen[7] = 1;
      endcase
      $display("RANDOM step %0d note %0d", i, got);
    end
    distinct = seen[0] + seen[1] + seen[2] + seen[3] + seen[4] + seen[5] + seen[6] + seen[7];
    if (distinct < 3) $fatal(1, "random pattern only produced %0d distinct notes", distinct);
    $display("PASS pattern random : %0d distinct notes in %0d steps", distinct, MAX_STEPS);

    $display("TB_LIVE_ARP_WALK RESULT: PASS");
    $finish;
  end

  initial begin : timeout
    #400_000_000;
    $fatal(1, "tb_live_arp_walk timeout (mode=%0d gate=%0d n=%0d)",
           arp_mode, gate_state, event_count);
  end
endmodule
