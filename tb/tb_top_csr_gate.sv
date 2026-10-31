`timescale 1ns/1ps
// Top-level CSR gate regression: drives mgc3130_v2_top through its real UART pins
// and the CSR decode path, never by poking the uploader directly.
//
// Build with +define+V2_SIM so v2_clock_gen bypasses the PLL, and with prim_sim
// compiled so the GSR primitive exists.
module tb_top_csr_gate #(parameter integer GOWIN_RAM = 0);
  localparam integer CLK_HZ = 80_000_000;
  localparam integer BAUD   = 1_000_000;
  localparam integer BIT_CYC = CLK_HZ / BAUD;          // 80 clocks per bit
  localparam [15:0]  HOST_CRC = 16'hEDDC;
  localparam [7:0]   ERR_NONE = 8'h00, ERR_BAD_DATA = 8'h07, ERR_WT_CRC = 8'h0A;

  reg clk = 0;
  always #6.25 clk = ~clk;                              // 80 MHz
  reg rst_n = 0;

  reg  uart_rx = 1;
  wire uart_tx;
  wire mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  wire pcm_bck, pcm_lrck, pcm_din;

  // prim_sim's storage primitives reference GSR.GSRO by hierarchical name.
  GSR GSR (.GSRI(1'b1));

  mgc3130_v2_top #(.USE_GOWIN_RAM(GOWIN_RAM)) dut (
    .clk_50m(clk), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl),
    .mgc_ts(mgc_ts), .mgc_mclr(mgc_mclr),
    .uart_rx(uart_rx), .uart_tx(uart_tx),
    .pcm5102a_bck(pcm_bck), .pcm5102a_lrck(pcm_lrck), .pcm5102a_din(pcm_din)
  );

  integer errors = 0;
  function automatic [15:0] crc16_byte(input [15:0] c_in, input [7:0] b_in);
    reg [15:0] c; integer n;
    begin
      c = c_in ^ {b_in, 8'h00};
      for (n = 0; n < 8; n = n + 1) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_byte = c;
    end
  endfunction

  task automatic send_byte(input [7:0] b);
    integer i;
    begin
      @(negedge clk); uart_rx = 0; repeat (BIT_CYC) @(negedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        uart_rx = b[i]; repeat (BIT_CYC) @(negedge clk);
      end
      uart_rx = 1; repeat (BIT_CYC * 2) @(negedge clk);
    end
  endtask

  reg [7:0] rxbuf [0:255];
  integer   rx_bytes = 0;
  integer   rc_cnt = 0;
  integer   rc_bit = 0;
  reg [7:0] rc_shift = 0;
  reg [1:0] rc_state = 0;
  always @(posedge clk) begin
    case (rc_state)
      2'd0: if (uart_tx == 1'b0) begin rc_state <= 2'd1; rc_cnt <= 0; end
      2'd1: begin
        rc_cnt <= rc_cnt + 1;
        if (rc_cnt == (BIT_CYC / 2)) begin rc_state <= 2'd2; rc_bit <= 0; rc_cnt <= 0; end
      end
      2'd2: begin
        rc_cnt <= rc_cnt + 1;
        if (rc_cnt == BIT_CYC - 1) begin
          rc_shift <= {uart_tx, rc_shift[7:1]};
          rc_cnt <= 0;
          if (rc_bit == 7) rc_state <= 2'd3;
          else rc_bit <= rc_bit + 1;
        end
      end
      2'd3: begin
        rc_cnt <= rc_cnt + 1;
        if (rc_cnt == BIT_CYC - 1) begin
          rxbuf[rx_bytes % 256] <= rc_shift;
          rx_bytes <= rx_bytes + 1;
          rc_state <= 2'd0;
          rc_cnt <= 0;
        end
      end
      default: rc_state <= 2'd0;
    endcase
  end

  integer seq_no = 0;
  task automatic host_cmd(input [7:0] op, input [7:0] addr, input [31:0] data,
                          output [7:0] rtype, output [7:0] rerr, output [31:0] rdata);
    reg [15:0] crc; reg [7:0] f [0:10]; reg [7:0] sq;
    integer base, guard, n;
    begin
      sq = seq_no[7:0]; seq_no = seq_no + 1;
      f[0] = 8'hA5; f[1] = 8'h02; f[2] = op; f[3] = addr; f[4] = sq;
      f[5] = data[31:24]; f[6] = data[23:16]; f[7] = data[15:8]; f[8] = data[7:0];
      crc = 16'hffff;
      for (n = 0; n < 9; n = n + 1) crc = crc16_byte(crc, f[n]);
      f[9] = crc[15:8]; f[10] = crc[7:0];
      base = rx_bytes;
      for (n = 0; n < 11; n = n + 1) send_byte(f[n]);
      guard = 0;
      while (rx_bytes < base + 22 && guard < 40000) begin @(negedge clk); guard = guard + 1; end
      if (rx_bytes < base + 22) begin
        $display("FAIL: no response for op=0x%02h addr=0x%02h", op, addr);
        errors = errors + 1;
        rtype = 8'h00; rerr = 8'hFF; rdata = 32'hFFFFFFFF;
      end else begin
        rtype = rxbuf[(base + 2) % 256]; rerr = rxbuf[(base + 19) % 256];
        rdata = {rxbuf[(base + 14) % 256], rxbuf[(base + 15) % 256], rxbuf[(base + 16) % 256], rxbuf[(base + 17) % 256]};
        // frame integrity: SOF, version, sequence echo, CRC over the first 20 bytes
        crc = 16'hffff;
        for (n = 0; n < 20; n = n + 1) crc = crc16_byte(crc, rxbuf[(base + n) % 256]);
        if (rxbuf[(base + 0) % 256] !== 8'h5A || rxbuf[(base + 1) % 256] !== 8'h02 ||
            rxbuf[(base + 4) % 256] !== sq ||
            rxbuf[(base + 20) % 256] !== crc[15:8] || rxbuf[(base + 21) % 256] !== crc[7:0]) begin
          $display("FAIL: malformed reply for addr=0x%02h sof=%02h ver=%02h seq=%02h/%02h crc=%02h%02h/%04h",
                   addr, rxbuf[base % 256], rxbuf[base+1], rxbuf[base+4], sq,
                   rxbuf[base+20], rxbuf[base+21], crc);
          errors = errors + 1;
        end
      end
    end
  endtask

  task automatic expect_eq(input [31:0] got, input [31:0] want, input [511:0] what);
    begin
      if (got !== want) begin
        $display("FAIL %s: got 0x%08h want 0x%08h", what, got, want);
        errors = errors + 1;
      end else begin
        $display("PASS %s = 0x%08h", what, got);
      end
    end
  endtask

  reg [15:0] pattern [0:1023];
  integer i, b, k;
  reg [7:0] rtype, rerr;
  reg [31:0] rdata;
  reg [31:0] version_now;

  initial begin
    for (k = 0; k < 1024; k = k + 1) pattern[k] = (k * 37 + 1234) & 16'hFFFF;
    $display("vector fingerprint: pattern[0]=0x%04h pattern[1023]=0x%04h host_crc=0x%04h",
             pattern[0], pattern[1023], HOST_CRC);

    repeat (8) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);

    // read-path self test first: if this fails every later FAIL is the bench's fault
    host_cmd(8'h01, 8'hB0, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'h5A5A0003, "constant CSR");
    expect_eq({24'd0, rerr}, 32'd0, "constant read error");

    // THRESHOLDS[7:0] selects the WT_PLAY test note, so the register must round-trip
    host_cmd(8'h02, 8'h30, 32'h0100_0045, rtype, rerr, rdata);
    host_cmd(8'h01, 8'h30, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'h0100_0045, "thresholds_roundtrip");

    // P1: a single WT_CRC write must be visible to the uploader
    host_cmd(8'h02, 8'h60, 32'h00000000, rtype, rerr, rdata);
    host_cmd(8'h02, 8'h70, {16'd0, HOST_CRC}, rtype, rerr, rdata);
    repeat (4) @(negedge clk);

    // P1: first WT_INDEX write must move the pointer
    host_cmd(8'h02, 8'h64, 32'd64, rtype, rerr, rdata);
    repeat (4) @(negedge clk);
    host_cmd(8'h01, 8'hC4, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'd64, "first WT_INDEX loads wr_ptr");

    // upload the full table
    host_cmd(8'h02, 8'h64, 32'd0, rtype, rerr, rdata);
    for (b = 0; b < 32; b = b + 1)
      for (k = 0; k < 32; k = k + 1)
        host_cmd(8'h02, 8'h68, {16'd0, pattern[b * 32 + k]}, rtype, rerr, rdata);
    host_cmd(8'h01, 8'hC0, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'd32, "coverage count complete");
    host_cmd(8'h01, 8'hBC, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'hFFFFFFFF, "coverage bitmap full");
    host_cmd(8'h01, 8'hA8, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, {16'd0, HOST_CRC}, "expected CRC reached the uploader");

    // four transactions: success, wrong payload, wrong WT_VERSION, correct retry
    host_cmd(8'h02, 8'h74, 32'd0, rtype, rerr, rdata);      // WT_VERSION = 0
    host_cmd(8'h02, 8'h78, 32'h80000000, rtype, rerr, rdata);
    repeat (2000) @(negedge clk);
    host_cmd(8'h01, 8'h7C, 32'd0, rtype, rerr, rdata);
    version_now = rdata & 32'hFFFF;
    expect_eq(version_now, 32'd1, "T1 apply committed");
    expect_eq({24'd0, rerr}, 32'd0, "T1 reply error");

    host_cmd(8'h02, 8'h78, 32'h80000007, rtype, rerr, rdata);   // wrong payload
    repeat (2000) @(negedge clk);
    host_cmd(8'h01, 8'h7C, 32'd0, rtype, rerr, rdata);
    version_now = rdata & 32'hFFFF;
    expect_eq(version_now, 32'd1, "T2 version unchanged");
    expect_eq({24'd0, rerr}, {24'd0, ERR_BAD_DATA}, "T2 reply error is BAD_DATA");

    host_cmd(8'h01, 8'h7C, 32'd0, rtype, rerr, rdata);
    version_now = rdata & 32'hFFFF;
    host_cmd(8'h02, 8'h74, version_now + 32'd3, rtype, rerr, rdata);  // wrong WT_VERSION
    host_cmd(8'h02, 8'h78, 32'h80000000 | version_now, rtype, rerr, rdata);
    repeat (2000) @(negedge clk);
    host_cmd(8'h01, 8'h7C, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata & 32'hFFFF, version_now, "T3 version unchanged");
    expect_eq({24'd0, rerr}, {24'd0, ERR_BAD_DATA}, "T3 reply error is BAD_DATA");

    host_cmd(8'h02, 8'h74, version_now, rtype, rerr, rdata);          // correct WT_VERSION
    host_cmd(8'h02, 8'h78, 32'h80000000 | version_now, rtype, rerr, rdata);
    repeat (2000) @(negedge clk);
    host_cmd(8'h01, 8'h7C, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata & 32'hFFFF, version_now + 1, "T4 retry committed");
    expect_eq({24'd0, rerr}, 32'd0, "T4 reply error");

    // WT_SELECT now carries {step[22:0], morph_en, 6'b0, table[1:0]}.
    host_cmd(8'h02, 8'h60, 32'h0024_6901, rtype, rerr, rdata);
    host_cmd(8'h01, 8'h60, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'h0024_6901, "wt_select_morph_roundtrip");
    host_cmd(8'h02, 8'h60, 32'h0000_0001, rtype, rerr, rdata);
    host_cmd(8'h01, 8'h60, 32'd0, rtype, rerr, rdata);
    expect_eq(rdata, 32'h0000_0001, "wt_select_no_morph_when_bit8_clear");

    if (errors == 0) $display("TB_TOP_CSR_GATE PASS (RAM=%0d)", GOWIN_RAM);
    else $fatal(1, "TB_TOP_CSR_GATE FAIL (%0d errors, RAM=%0d)", errors, GOWIN_RAM);
    $finish;
  end

  initial begin
    #600_000_000;                       // 600 ms: the 1024-command upload alone is ~99 ms
    $fatal(1, "TB_TOP_CSR_GATE TIMEOUT");
  end
endmodule
