`timescale 1ns/1ps
// The publish handshake must finish while a commit is pending.
//
// The store gates its read port on `!busy`, and `busy` includes commit_pending.
// COMMIT_REQUEST therefore froze the scheduler, which is the only producer of
// loop_boundary, so the swap could never happen and the old top test hid it by
// forcing loop_boundary.  This bench uses the real pair of modules.
//
// Sized down (one track, four slots) so a full scan fits inside one tick.
module tb_loop_publish;
  localparam integer TRACKS = 1;
  localparam integer DEPTH = 4;
  localparam integer SLOT_BITS = 2;
  localparam integer COUNT_BITS = 3;

  logic clk = 0, rst_n = 0;
  logic abort = 0;
  logic loop_boundary;
  logic ctrl_valid = 0, ctrl_ready, ctrl_done;
  logic [2:0] ctrl_op = 0, ctrl_track = 0;
  logic write_valid = 0, write_ready;
  logic [2:0] write_track = 0;
  logic [SLOT_BITS-1:0] write_slot = 0;
  logic [95:0] write_data = 0;
  logic read_enable, read_valid, read_slot_valid;
  logic [2:0] read_track;
  logic [SLOT_BITS-1:0] read_index;
  logic [95:0] read_data;
  logic active_bank, shadow_bank, commit_pending, commit_ack, busy;
  logic [TRACKS*COUNT_BITS-1:0] record_count;
  logic [TRACKS-1:0] overflow;
  logic active_valid, commit_timeout;
  logic [31:0] commit_wait_cycles;

  logic run = 0, stop = 0, flush = 0, tick_start = 0;
  logic [2:0] selected_track = 0;
  logic [6:0] loop_tick = 0;
  logic event_valid, event_ready = 1;
  logic [95:0] event_data;
  logic fault_valid;

  integer i, boundary_count = 0, tick0_events = 0, tick16_events = 0;
  integer settle;

  always #5 clk = ~clk;
  GSR GSR(.GSRI(1'b1));

  v2_loop_event_store_dpb #(
    .TRACKS(TRACKS), .DEPTH(DEPTH), .BOUNDARY_TIMEOUT_CYCLES(32'd20_000)
  ) u_store (
    .clk(clk), .rst_n(rst_n), .abort(abort), .loop_boundary(loop_boundary),
    .ctrl_valid(ctrl_valid), .ctrl_ready(ctrl_ready), .ctrl_op(ctrl_op),
    .ctrl_track(ctrl_track), .ctrl_done(ctrl_done),
    .write_valid(write_valid), .write_ready(write_ready), .write_track(write_track),
    .write_slot(write_slot), .write_data(write_data),
    .read_enable(read_enable), .read_track(read_track), .read_index(read_index),
    .read_valid(read_valid), .read_slot_valid(read_slot_valid), .read_data(read_data),
    .active_bank(active_bank), .shadow_bank(shadow_bank), .commit_pending(commit_pending),
    .commit_ack(commit_ack), .busy(busy), .record_count(record_count),
    .overflow(overflow), .active_valid(active_valid),
    .commit_timeout(commit_timeout), .commit_wait_cycles(commit_wait_cycles));

  v2_loop_scheduler #(.TRACKS(TRACKS), .DEPTH(DEPTH), .LOOP_TICKS(128)) u_sched (
    .clk(clk), .rst_n(rst_n), .run(run), .stop(stop), .flush(flush), .tick_start(tick_start),
    .selected_track(selected_track), .loop_tick(loop_tick),
    .read_valid(read_valid), .read_slot_valid(read_slot_valid), .read_data(read_data),
    .read_enable(read_enable), .read_track(read_track), .read_index(read_index),
    .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
    .fault_valid(fault_valid), .loop_boundary(loop_boundary));

  function automatic [95:0] note_on(input [7:0] tick, input [7:0] note);
    logic [95:0] e;
    begin
      e = 96'd0;
      e[94:91] = 4'd1;
      e[90:88] = 3'd0;
      e[87:80] = tick;
      e[79:72] = 8'd4;
      e[71:64] = note;
      e[63:56] = 8'd100;
      note_on = e;
    end
  endfunction

  task automatic control(input [2:0] op);
    begin
      @(negedge clk);
      ctrl_op = op;
      ctrl_valid = 1'b1;
      #1;
      settle = 0;
      while (!ctrl_ready && settle < 400) begin
        @(posedge clk);
        #1;
        settle = settle + 1;
      end
      if (!ctrl_ready) $fatal(1, "control op %0d was never ready", op);
      @(posedge clk);              // accept: ctrl_valid && ctrl_ready
      @(negedge clk);
      ctrl_valid = 1'b0;
      settle = 0;
      while (!ctrl_done && settle < 4000) begin
        @(posedge clk);
        #1;
        settle = settle + 1;
      end
      if (!ctrl_done) $fatal(1, "control op %0d never completed", op);
    end
  endtask

  task automatic write_event(input [SLOT_BITS-1:0] slot, input [7:0] tick, input [7:0] note);
    begin
      @(negedge clk);
      write_slot = slot;
      write_data = note_on(tick, note);
      write_valid = 1'b1;
      #1;
      if (!write_ready) $fatal(1, "store refused event slot %0d", slot);
      @(posedge clk);
      @(negedge clk);
      write_valid = 1'b0;
    end
  endtask

  always @(posedge clk) begin
    if (loop_boundary) boundary_count = boundary_count + 1;
    if (event_valid && event_ready) begin
      if (event_data[87:80] == 8'd0) tick0_events = tick0_events + 1;
      if (event_data[87:80] == 8'd16) tick16_events = tick16_events + 1;
    end
  end

  task automatic pulse_tick;
    begin
      @(negedge clk);
      tick_start = 1'b1;
      @(negedge clk);
      tick_start = 1'b0;
    end
  endtask

  initial begin : run_tb
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    control(3'd5);                       // PREPARE_RECORD, track 0
    write_event(2'd0, 8'd0, 8'd60);
    write_event(2'd1, 8'd16, 8'd67);
    if (record_count[COUNT_BITS-1:0] != 3'd2)
      $fatal(1, "shadow count=%0d expected 2", record_count[COUNT_BITS-1:0]);

    control(3'd3);                       // COMMIT_REQUEST
    if (!commit_pending) $fatal(1, "commit was not requested");
    if (active_valid) $fatal(1, "active bank must stay empty before the swap");

    // Only now does the scheduler start: every read from here on happens while
    // commit_pending is asserted, which is exactly the state under test.
    // Hold loop_tick at the last tick so the current sweep ends on 127 and the
    // boundary is produced deterministically.
    run = 1;
    loop_tick = 7'd127;
    settle = 0;
    while (boundary_count == 0 && settle < 400) begin
      pulse_tick();
      repeat (20) @(posedge clk);
      settle = settle + 1;
    end
    if (boundary_count == 0)
      $fatal(1, "loop_boundary never seen while commit_pending was set (read port blocked)");
    repeat (4) @(posedge clk);

    if (commit_pending) $fatal(1, "commit stayed pending after the boundary");
    if (!active_valid) $fatal(1, "the swap did not publish the shadow bank");

    // The events now live in the active bank; let the scheduler match them.
    loop_tick = 7'd0;
    settle = 0;
    while (tick0_events == 0 && settle < 400) begin
      pulse_tick();
      repeat (20) @(posedge clk);
      settle = settle + 1;
    end
    loop_tick = 7'd16;
    settle = 0;
    while (tick16_events == 0 && settle < 400) begin
      pulse_tick();
      repeat (20) @(posedge clk);
      settle = settle + 1;
    end
    run = 0;

    if (tick0_events < 1) $fatal(1, "the tick-0 event never reached the scheduler");
    if (tick16_events < 1) $fatal(1, "the tick-16 event never reached the scheduler");
    $display("PASS tb_loop_publish boundaries=%0d tick0=%0d tick16=%0d",
             boundary_count, tick0_events, tick16_events);

    // A commit that never reaches a loop boundary must be dropped and reported,
    // not held forever: prepare a fresh take, request the commit, and then stop
    // ticking so no boundary can arrive.
    run = 0;
    control(3'd5);
    write_event(2'd0, 8'd40, 8'd64);
    control(3'd3);
    if (!commit_pending) $fatal(1, "second commit was not requested");
    settle = 0;
    while (!commit_timeout && settle < 60000) begin
      @(posedge clk);
      settle = settle + 1;
    end
    if (!commit_timeout) $fatal(1, "the commit never timed out without a boundary");
    if (commit_pending) $fatal(1, "commit stayed pending after the timeout");
    if (record_count[COUNT_BITS-1:0] != 3'd0)
      $fatal(1, "the dropped take left %0d events in the shadow", record_count[COUNT_BITS-1:0]);
    $display("PASS tb_loop_publish timeout honoured after %0d cycles", settle);
    $finish;
  end

  initial begin : timeout
    #5_000_000;
    $fatal(1, "tb_loop_publish timeout (boundaries=%0d pending=%b busy=%b)",
           boundary_count, commit_pending, busy);
  end
endmodule
