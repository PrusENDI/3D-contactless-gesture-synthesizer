`timescale 1ns/1ps
// Ported from mgc3130_uart/sim/tb_mgc3130_v2_top_potts.sv (assertions unchanged;
// only the PASS line moved to the front).
//
// Top-level Potts integration: a real recorder write must reach the contour
// holding bank, COMMIT must launch the DP and ask the store for a bank swap,
// UART must stay responsive while the DP runs, and the swap must wait for a
// loop boundary.
module tb_mgc3130_v2_top_potts;
  logic clk_50m = 1'b0, uart_rx = 1'b1;
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;
  logic [7:0] inject_value;
  logic [95:0] forced_event_value;
  integer i, busy_cycles, done_seen, sample_before;

  always #5 clk_50m = ~clk_50m;
  GSR GSR(.GSRI(1'b1));
  mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(1), .UART_BAUD(1_000_000)) dut (
    .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
    .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck), .pcm5102a_din(pcm5102a_din)
  );

  function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
    reg [15:0] c;
    integer b;
    begin
      c = crc_in ^ {value, 8'h00};
      for (b = 0; b < 8; b = b + 1)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc_byte = c;
    end
  endfunction

  task automatic inject_byte(input [7:0] value);
    begin
      inject_value = value;
      force dut.uart_byte = inject_value;
      force dut.uart_byte_valid = 1'b1;
      @(posedge clk_50m);
      #1;
      force dut.uart_byte_valid = 1'b0;
      @(posedge clk_50m);
      #1;
      release dut.uart_byte_valid;
      release dut.uart_byte;
    end
  endtask

  task automatic inject_control(input [7:0] op, input [7:0] address,
                                input [7:0] seq, input [31:0] data);
    reg [7:0] b [0:10];
    reg [15:0] c;
    integer k;
    begin
      b[0] = 8'ha5;
      b[1] = 8'h02;
      b[2] = op;
      b[3] = address;
      b[4] = seq;
      b[5] = data[31:24];
      b[6] = data[23:16];
      b[7] = data[15:8];
      b[8] = data[7:0];
      c = 16'hffff;
      for (k = 0; k < 9; k = k + 1) c = crc_byte(c, b[k]);
      b[9] = c[15:8];
      b[10] = c[7:0];
      for (k = 0; k < 11; k = k + 1) inject_byte(b[k]);
      repeat (4) @(posedge clk_50m);
      for (integer wait_i = 0; wait_i < 500000; wait_i = wait_i + 1) begin
        if (!dut.v2_tx_valid && !dut.uart_tx_busy) wait_i = 500000;
        else @(posedge clk_50m);
      end
      if (dut.v2_tx_valid || dut.uart_tx_busy)
        $fatal(1, "V2 UART response did not drain");
    end
  endtask

  task automatic inject_record_event(input [7:0] tick, input [7:0] note_value);
    begin
      forced_event_value = 96'd0;
      forced_event_value[94:91] = 4'd1;
      forced_event_value[87:80] = tick;
      forced_event_value[79:72] = 8'd4;
      forced_event_value[71:64] = note_value;
      forced_event_value[63:56] = 8'd100;
      force dut.live_event_data = forced_event_value;
      force dut.live_event_valid = 1'b1;
      repeat (2) @(posedge clk_50m);
      release dut.live_event_valid;
      release dut.live_event_data;
      repeat (3) @(posedge clk_50m);
    end
  endtask

  initial begin : run
    repeat (25) @(posedge clk_50m);
    if (!dut.rst_sys_n || !dut.pll_locked) $fatal(1, "V2 reset/PLL did not release");

    inject_control(8'h02, 8'h04, 8'h31, 32'd2); // RECORD
    inject_control(8'h02, 8'h0c, 8'h32, 32'd0); // track 0
    inject_control(8'h02, 8'h18, 8'h33, 32'd1); // PREPARE_RECORD
    repeat (160) @(posedge clk_50m);
    if (!dut.recording || dut.loop_busy) $fatal(1, "record plane did not become ready");

    // A real top-level recorder write updates the contour holding bank.
    for (i = 0; i < 8; i = i + 1)
      inject_record_event(i * 8, 8'd60 + i[7:0]);
    if (dut.record_track_count[0] < 8)
      $fatal(1, "recorder did not deliver contour events count=%0d", dut.record_track_count[0]);
    if (dut.potts_contour[0] == 0 || dut.potts_contour[56] == 0)
      $fatal(1, "top contour was not captured from recorder writes");

    // COMMIT launches Potts and requests a bank swap. The store must keep the
    // request pending until a loop boundary is observed.
    inject_control(8'h02, 8'h28, 8'h34, 32'd1);
    if (!dut.potts_busy) begin
      repeat (4) @(posedge clk_50m);
      if (!dut.potts_busy) $fatal(1, "Potts did not start from COMMIT");
    end
    if (!dut.loop_commit_pending) $fatal(1, "store commit was not held pending");
    // A background commit must not stall read-only UART status traffic.
    inject_control(8'h01, 8'h00, 8'h35, 32'd0);
    if (dut.rsp_sequence !== 8'h35)
      $fatal(1, "UART READ was blocked while Potts/commit was pending");
    // Potts is a background task in the same 100 MHz domain; sample time must
    // continue advancing while its DP is busy.
    sample_before = dut.sample_index;
    busy_cycles = 0;
    done_seen = 0;
    for (i = 0; i < 2_500_000 && (!done_seen || dut.potts_busy); i = i + 1) begin
      @(posedge clk_50m);
      if (dut.potts_busy) busy_cycles = busy_cycles + 1;
      if (dut.potts_done) done_seen = 1;
    end
    if (!done_seen || dut.potts_busy)
      $fatal(1, "Potts timeout busy_cycles=%0d progress=%0d", busy_cycles, dut.g_potts.u_potts.progress);
    if (!dut.potts_backtrace_valid || dut.potts_overflow || dut.potts_event_count < 1)
      $fatal(1, "Potts result invalid bt=%b overflow=%b count=%0d",
             dut.potts_backtrace_valid, dut.potts_overflow, dut.potts_event_count);
    if (dut.sample_index <= sample_before)
      $fatal(1, "sample scheduler stopped during Potts busy before=%0d after=%0d",
             sample_before, dut.sample_index);

    // Bank publication is boundary-gated even after Potts has completed.
    force dut.loop_boundary = 1'b1;
    @(posedge clk_50m);
    #1;
    release dut.loop_boundary;
    repeat (4) @(posedge clk_50m);
    if (dut.loop_commit_pending || !dut.loop_active_valid)
      $fatal(1, "bank swap did not complete at boundary");
    $display("PASS tb_mgc3130_v2_top_potts busy_cycles=%0d events=%0d",
             busy_cycles, dut.potts_event_count);
    $finish;
  end

  initial begin : timeout
    #60_000_000;
    $fatal(1, "top Potts integration timeout");
  end
endmodule
