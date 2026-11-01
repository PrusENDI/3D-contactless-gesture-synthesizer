`timescale 1ns/1ps
// The commit writer turns the Potts event stream into the store's write port.
//
// It must not request the bank swap before every event has been accepted, and
// it must hold an event while the store's write port is busy (the host may
// still be recording on another track).
module tb_loop_commit_writer;
  logic clk = 0, rst_n = 0, kick = 0;
  logic potts_start = 0;
  logic potts_busy = 0, potts_done = 0;
  logic potts_event_valid = 0;
  logic potts_event_ready;
  logic [95:0] potts_event_data = 0;
  logic store_write_ready = 0;
  logic store_write_valid;
  logic [4:0] store_write_slot;
  logic commit_request, run, done;
  logic [5:0] count;

  integer i, accepted = 0, commit_pulses = 0, start_pulses = 0, stall_cycles = 0;
  logic [4:0] seen_slot [0:7];

  always #5 clk = ~clk;

  v2_loop_commit_writer dut (
    .clk(clk), .rst_n(rst_n), .kick(kick),
    .potts_start(potts_start),
    .potts_busy(potts_busy), .potts_done(potts_done),
    .potts_event_valid(potts_event_valid), .potts_event_ready(potts_event_ready),
    .potts_event_data(potts_event_data),
    .store_write_ready(store_write_ready),
    .store_write_valid(store_write_valid), .store_write_slot(store_write_slot),
    .commit_request(commit_request), .run(run), .done(done), .count(count));

  always @(posedge clk) begin
    if (potts_start) start_pulses = start_pulses + 1;
    if (commit_request) commit_pulses = commit_pulses + 1;
    if (store_write_valid && store_write_ready && accepted < 8) begin
      seen_slot[accepted] = store_write_slot;
      accepted = accepted + 1;
    end
  end

  task automatic pulse_kick;
    begin
      @(negedge clk);
      kick = 1'b1;
      @(negedge clk);
      kick = 1'b0;
    end
  endtask

  task automatic send_event(input [95:0] data);
    integer guard;
    begin
      @(negedge clk);
      potts_event_data = data;
      potts_event_valid = 1'b1;
      guard = 0;
      while (!(potts_event_ready && potts_event_valid) && guard < 20) begin
        @(posedge clk);
        #1;
        guard = guard + 1;
      end
      if (guard >= 20) $fatal(1, "event was never accepted");
      @(posedge clk);
      @(negedge clk);
      potts_event_valid = 1'b0;
    end
  endtask

  initial begin : run_tb
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    pulse_kick();
    for (i = 0; i < 8 && !run; i = i + 1) @(posedge clk);
    if (!run) $fatal(1, "kick did not start the writer");
    for (i = 0; i < 8; i = i + 1) begin
      @(posedge clk);
      #1;
      if (start_pulses == 1) i = 8;
    end
    if (start_pulses != 1) $fatal(1, "potts_start pulses=%0d expected 1", start_pulses);
    if (commit_pulses != 0) $fatal(1, "commit was requested before the DP ran");

    potts_busy = 1'b1;
    store_write_ready = 1'b1;
    for (i = 0; i < 3; i = i + 1) send_event(96'd0 + i);

    if (accepted != 3) $fatal(1, "store accepted %0d events, expected 3", accepted);
    for (i = 0; i < 3; i = i + 1)
      if (seen_slot[i] !== i[4:0])
        $fatal(1, "event %0d used slot %0d", i, seen_slot[i]);
    if (count != 6'd3) $fatal(1, "count=%0d expected 3", count);
    if (commit_pulses != 0) $fatal(1, "commit was requested before done");

    potts_busy = 1'b0;
    @(negedge clk);
    potts_done = 1'b1;
    @(negedge clk);
    potts_done = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    if (commit_pulses != 1) $fatal(1, "commit_request pulses=%0d expected 1", commit_pulses);
    if (!done) $fatal(1, "done did not assert");
    if (run) $fatal(1, "run stayed high after the commit");

    // A stalled write port must hold the event and the slot.
    accepted = 0;
    commit_pulses = 0;
    pulse_kick();
    potts_busy = 1'b1;
    store_write_ready = 1'b0;
    @(negedge clk);
    potts_event_valid = 1'b1;
    potts_event_data = 96'd1;
    stall_cycles = 0;
    while (stall_cycles < 5) begin
      @(posedge clk);
      #1;
      if (potts_event_ready) $fatal(1, "event_ready asserted while the store was busy");
      if (accepted != 0) $fatal(1, "writer accepted an event the store refused");
      stall_cycles = stall_cycles + 1;
    end
    store_write_ready = 1'b1;
    @(posedge clk);
    #1;
    if (accepted != 1) $fatal(1, "stalled event was not accepted after the port opened");
    if (seen_slot[0] !== 5'd0) $fatal(1, "stalled event used slot %0d", seen_slot[0]);

    $display("PASS tb_loop_commit_writer accepted=%0d commit=%0d", accepted, commit_pulses);
    $finish;
  end

  initial begin : timeout
    #100_000;
    $fatal(1, "tb_loop_commit_writer timeout");
  end
endmodule
