// Dual-read channel test for the wavetable loader.
//
// Uploads two distinct 1024-point patterns through the real write/CRC/APPLY path
// (the active bank only flips on APPLY), then checks that both read channels see
// the table their registered select points at.
module tb_wt_dual_read;
  localparam int N = 1024;

  logic clk = 0, rst_n = 0;
  logic wt_write_valid = 0, wt_write_ready;
  logic [1:0] wt_table = 0;
  logic [9:0] wt_index = 0;
  logic wt_index_load = 0;
  logic signed [15:0] wt_write_sample = 0;
  logic wt_crc_valid = 0;
  logic [15:0] wt_expected_crc = 0;
  logic wt_apply_valid = 0, wt_apply_ready;
  logic [1:0] wt_apply_table = 0;
  logic [15:0] wt_apply_version = 0, wt_version_reg = 0;
  logic loop_boundary = 0, idle = 1;
  logic [1:0] wt_read_table = 0;
  logic [9:0] wt_read_index = 0;
  logic signed [15:0] wt_read_sample;
  logic [1:0] wt_rd_table0 = 0, wt_rd_table1 = 0;
  logic [9:0] wt_rd_index0 = 0, wt_rd_index1 = 0;
  logic signed [15:0] wt_rd_sample0, wt_rd_sample1;
  logic wt_rd_valid0, wt_rd_valid1;
  logic wt_apply_done, wt_apply_ok;
  logic wt_active_valid, wt_shadow_valid, wt_apply_busy, wt_crc_error;
  logic [15:0] wt_active_version;

  logic [15:0] p0 [0:N-1];
  logic [15:0] p1 [0:N-1];
  logic [15:0] crc;
  int i;

  v2_wavetable_loader #(.TABLES(3), .SAMPLES(1024), .USE_GOWIN_RAM(0)) dut (
    .clk, .rst_n,
    .wt_write_valid, .wt_write_ready, .wt_table, .wt_index, .wt_index_load,
    .wt_write_sample, .wt_crc_valid, .wt_expected_crc,
    .wt_apply_valid, .wt_apply_ready, .wt_apply_table, .wt_apply_version,
    .wt_version_reg, .loop_boundary, .idle,
    .wt_read_table, .wt_read_index, .wt_read_sample,
    .wt_active_valid, .wt_shadow_valid, .wt_apply_busy, .wt_crc_error,
    .wt_active_version(wt_active_version), .wt_active_table(),
    .wt_apply_done, .wt_apply_ok, .wt_apply_reason(),
    .wt_rd_table0, .wt_rd_index0, .wt_rd_table1, .wt_rd_index1,
    .wt_rd_sample0, .wt_rd_sample1, .wt_rd_valid0, .wt_rd_valid1
  );

  always #5 clk = ~clk;

  function automatic [15:0] crc16_byte(input [15:0] c_in, input [7:0] b_in);
    reg [15:0] c; integer n;
    begin
      c = c_in ^ {b_in, 8'h00};
      for (n = 0; n < 8; n = n + 1) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_byte = c;
    end
  endfunction

  function automatic [15:0] crc16_sample(input [15:0] c_in, input [15:0] s);
    crc16_sample = crc16_byte(crc16_byte(c_in, s[15:8]), s[7:0]);
  endfunction

  task automatic upload(input [1:0] tbl, input [15:0] pat [0:N-1]);
    begin
      wt_table = tbl; wt_index = 0; wt_index_load = 1;
      @(negedge clk); wt_index_load = 0;
      for (i = 0; i < N; i = i + 1) begin
        @(negedge clk); wt_write_valid = 1; wt_write_sample = $signed(pat[i]);
        @(negedge clk); wt_write_valid = 0;
      end
      wt_index = 0;
      crc = 16'hffff;
      for (i = 0; i < N; i = i + 1) crc = crc16_sample(crc, pat[i]);
      @(negedge clk); wt_crc_valid = 1; wt_expected_crc = crc;
      @(negedge clk); wt_crc_valid = 0;
      wt_apply_table = tbl; wt_apply_version = 0; wt_version_reg = 0;
      @(negedge clk); wt_apply_valid = 1;
      @(negedge clk); wt_apply_valid = 0;
      wait (wt_apply_done);
      if (!wt_apply_ok) $fatal(1, "FAIL apply table %0d (crc %04h)", tbl, crc);
      @(negedge clk);
      $display("PASS upload+apply table %0d", tbl);
    end
  endtask

  task automatic read_both(input [1:0] t0, input [9:0] i0, input [1:0] t1, input [9:0] i1);
    begin
      wt_rd_table0 = t0; wt_rd_index0 = i0; wt_rd_table1 = t1; wt_rd_index1 = i1;
      repeat (4) @(negedge clk);
    end
  endtask

  initial begin
    for (i = 0; i < N; i = i + 1) begin
      p0[i] = (i * 3) & 16'h7FFF;
      p1[i] = (16'h7FFF - i * 5) & 16'h7FFF;
    end
    repeat (5) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

    upload(2'd0, p0);
    upload(2'd1, p1);

    read_both(2'd0, 10'd5, 2'd1, 10'd7);
    if (wt_rd_sample0 !== p0[5]) $fatal(1, "FAIL ch0 got %04h want %04h", wt_rd_sample0, p0[5]);
    if (wt_rd_sample1 !== p1[7]) $fatal(1, "FAIL ch1 got %04h want %04h", wt_rd_sample1, p1[7]);
    if (!(wt_rd_valid0 && wt_rd_valid1)) $fatal(1, "FAIL applied tables not valid");
    $display("PASS independent channels");

    read_both(2'd0, 10'd9, 2'd0, 10'd9);
    if (wt_rd_sample0 !== wt_rd_sample1)
      $fatal(1, "FAIL same-table mismatch %04h/%04h", wt_rd_sample0, wt_rd_sample1);
    if (wt_rd_sample0 !== p0[9]) $fatal(1, "FAIL same-table value %04h", wt_rd_sample0);
    $display("PASS same table both channels");

    read_both(2'd0, 10'd1, 2'd2, 10'd1);
    if (wt_rd_valid0 !== 1'b1) $fatal(1, "FAIL applied table lost valid");
    if (wt_rd_valid1 !== 1'b0) $fatal(1, "FAIL unapplied table reports valid");
    $display("PASS unapplied table valid=0");

    $display("TB_WT_DUAL_READ PASS");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_WT_DUAL_READ TIMEOUT");
  end
endmodule
