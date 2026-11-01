`timescale 1ns/1ps
// A sweep must run once per musical tick.
//
// The scheduler matches an event when the stored tick equals the current tick.
// With a free-running scan the same slot is re-read many times inside one tick
// and the note is re-attacked over and over; the boundary can also be emitted
// more than once per loop.  This bench holds each tick for many scan periods
// and counts emissions.
module tb_loop_scheduler_tick;
  localparam integer TRACKS = 1;
  localparam integer DEPTH = 4;
  localparam integer LOOP_TICKS = 32;

  logic clk = 0, rst_n = 0, run = 1, stop = 0, flush = 0, tick_start = 0;
  logic [2:0] selected_track = 0;
  logic [6:0] loop_tick = 0;
  logic read_enable, read_valid = 0, read_slot_valid = 0;
  logic [2:0] read_track;
  logic [1:0] read_index;
  logic [95:0] read_data = 0;
  logic event_valid, event_ready = 1;
  logic [95:0] event_data;
  logic fault_valid, loop_boundary;

  integer t, tick0_count = 0, tick16_count = 0, boundary_count = 0, other_events = 0, off_count = 0;

  always #5 clk = ~clk;

  function automatic [95:0] note_on(input [7:0] tick, input [7:0] note);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = 4'd1;
      e[87:80] = tick;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = 8'd100;
      note_on = e;
    end
  endfunction

  // Stub store: two events, synchronous read like v2_loop_event_store_dpb.
  always_ff @(posedge clk) begin
    read_valid <= read_enable;
    read_slot_valid <= read_enable && (read_track == 3'd0) && (read_index < 2'd2);
    read_data <= (read_index == 2'd0) ? note_on(8'd0, 8'd60) : note_on(8'd16, 8'd67);
  end

  v2_loop_scheduler #(.TRACKS(TRACKS), .DEPTH(DEPTH), .LOOP_TICKS(LOOP_TICKS)) dut (
    .clk(clk), .rst_n(rst_n), .run(run), .stop(stop), .flush(flush), .tick_start(tick_start),
    .selected_track(selected_track), .loop_tick(loop_tick),
    .read_valid(read_valid), .read_slot_valid(read_slot_valid), .read_data(read_data),
    .read_enable(read_enable), .read_track(read_track), .read_index(read_index),
    .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
    .fault_valid(fault_valid), .loop_boundary(loop_boundary));

  always @(posedge clk) begin
    if (event_valid && event_ready) begin
      if (event_data[94:91] == 4'd1 && event_data[87:80] == 8'd0) tick0_count = tick0_count + 1;
      else if (event_data[94:91] == 4'd1 && event_data[87:80] == 8'd16) tick16_count = tick16_count + 1;
      else if (event_data[94:91] == 4'd1) other_events = other_events + 1;
      else if (event_data[94:91] == 4'd2) off_count = off_count + 1;
    end
    if (loop_boundary) boundary_count = boundary_count + 1;
  end

  task automatic advance_tick(input integer tick_no);
    begin
      @(negedge clk);
      loop_tick = tick_no[6:0];
      tick_start = 1'b1;
      @(negedge clk);
      tick_start = 1'b0;
      // Far longer than one sweep, so a free-running scan would re-emit here.
      repeat (200) @(posedge clk);
    end
  endtask

  initial begin : run_tb
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (t = 0; t < 2 * LOOP_TICKS; t = t + 1)
      advance_tick(t % LOOP_TICKS);

    if (tick0_count != 2)
      $fatal(1, "tick-0 event emitted %0d times over 2 loops, expected 2", tick0_count);
    if (tick16_count != 2)
      $fatal(1, "tick-16 event emitted %0d times over 2 loops, expected 2", tick16_count);
    if (other_events != 0)
      $fatal(1, "%0d unexpected note-on events", other_events);
    // Each note produces its ON and the OFF the scheduler derives from the
    // event's duration: 2 notes per loop.
    if (off_count != 4)
      $fatal(1, "%0d note-off events over 2 loops, expected 4", off_count);
    if (boundary_count != 2)
      $fatal(1, "%0d boundaries over 2 loops, expected 2", boundary_count);

    $display("PASS tb_loop_scheduler_tick tick0=%0d tick16=%0d offs=%0d boundaries=%0d",
             tick0_count, tick16_count, off_count, boundary_count);
    $finish;
  end

  initial begin : timeout
    #2_000_000;
    $fatal(1, "tb_loop_scheduler_tick timeout");
  end
endmodule
