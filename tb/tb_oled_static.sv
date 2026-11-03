// Decode the panel's SPI stream and check every byte of it.
//
// The DUT is a byte pusher: if the phase, the bit order or the page addressing
// is wrong, the screen is wrong in a way that looks like wiring.  So this bench
// taps sck/mosi/dc/cs_n, rebuilds the byte stream, and compares it with the
// initialisation table and with the framebuffer the design will carry.
//
// The framebuffer module is the real one (rtl/v2_oled_image.sv), so the address
// walk is proven end to end: byte n of the stream must equal mem[n].
`timescale 1ns / 1ps
module tb_oled_static;
    localparam integer SPI_DIV      = 4;      // fast: 80 ns per bit
    localparam integer RESET_CYCLES = 200;    // 4 us at 20 ns, over the 3 us floor
    localparam integer WAKE_CYCLES  = 50;
    localparam integer INIT_BYTES   = 25;
    localparam integer PAGE_CMDS    = 3;
    localparam integer FRAME_BYTES  = 1024;

    logic clk = 0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [7:0] img_data;
    logic [9:0] img_addr;
    logic sck, mosi, dc, cs_n, res_n, blk, busy, done;

    v2_oled_image u_img (
        .clk(clk), .addr(img_addr), .data(img_data)
    );

    v2_oled_static #(
        .SPI_DIV(SPI_DIV),
        .RESET_CYCLES(RESET_CYCLES),
        .WAKE_CYCLES(WAKE_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .img_data(img_data), .img_addr(img_addr),
        .sck(sck), .mosi(mosi), .dc(dc), .cs_n(cs_n), .res_n(res_n),
        .blk(blk), .busy(busy), .done(done)
    );

    always #10 clk = ~clk;                    // 50 MHz

    // --------------------------------------------------------- byte capture --
    logic [7:0] cmd_q[0:63];
    logic [7:0] data_q[0:FRAME_BYTES-1];
    integer n_cmd = 0;
    integer n_data = 0;
    integer bit_count = 0;
    logic [7:0] shifter = 8'd0;
    logic byte_dc = 1'b0;
    integer first_data_cmds = -1;             // n_cmd when the first data byte began
    integer blk_bad = 0;
    integer errors = 0;

    always @(negedge cs_n) byte_dc = dc;

    always @(posedge sck) begin
        if (!cs_n) begin
            shifter = {shifter[6:0], mosi};
            bit_count = bit_count + 1;
            if (bit_count == 8) begin
                bit_count = 0;
                if (byte_dc) begin
                    if (first_data_cmds < 0) first_data_cmds = n_cmd;
                    if (n_data < FRAME_BYTES) data_q[n_data] = shifter;
                    n_data = n_data + 1;
                end else begin
                    if (n_cmd < 64) cmd_q[n_cmd] = shifter;
                    n_cmd = n_cmd + 1;
                end
            end
        end
    end

    always @(posedge clk) if (blk !== 1'b1) blk_bad = blk_bad + 1;

    // ------------------------------------------------------ reset timing -----
    time res_low_at = 0;
    time res_low_width = 0;

    always @(negedge res_n) res_low_at = $time;
    always @(posedge res_n) res_low_width = $time - res_low_at;

    // ------------------------------------------------------- expected table --
    function automatic logic [7:0] init_ref(input integer index);
        case (index)
            0:  init_ref = 8'hAE;
            1:  init_ref = 8'hD5;
            2:  init_ref = 8'h80;
            3:  init_ref = 8'hA8;
            4:  init_ref = 8'h3F;
            5:  init_ref = 8'hD3;
            6:  init_ref = 8'h00;
            7:  init_ref = 8'h40;
            8:  init_ref = 8'h8D;
            9:  init_ref = 8'h14;
            10: init_ref = 8'h20;
            11: init_ref = 8'h02;
            12: init_ref = 8'hA1;
            13: init_ref = 8'hC8;
            14: init_ref = 8'hDA;
            15: init_ref = 8'h12;
            16: init_ref = 8'h81;
            17: init_ref = 8'h7F;
            18: init_ref = 8'hD9;
            19: init_ref = 8'hF1;
            20: init_ref = 8'hDB;
            21: init_ref = 8'h40;
            22: init_ref = 8'hA4;
            23: init_ref = 8'hA6;
            default: init_ref = 8'hAF;
        endcase
    endfunction

    task automatic check(input logic ok, input string what);
        if (!ok) begin
            errors = errors + 1;
            $display("FAIL: %s", what);
        end
    endtask

    integer index;
    integer page;
    integer base;

    initial begin
        $display("TB_OLED_STATIC: SPI_DIV=%0d reset=%0d wake=%0d",
                 SPI_DIV, RESET_CYCLES, WAKE_CYCLES);
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        start = 1'b1;

        wait (done === 1'b1);
        @(negedge clk);

        // ---- 4: the panel was held in reset long enough
        check(res_low_width >= 3000, "res_n low pulse is shorter than 3 us");

        // ---- 1: the initialisation sequence, byte for byte
        check(n_cmd == INIT_BYTES + 8 * PAGE_CMDS,
              "command byte count is not 25 + 8*3");
        for (index = 0; index < INIT_BYTES; index = index + 1) begin
            if (n_cmd > index && cmd_q[index] !== init_ref(index))
                $display("  init[%0d] = %02h, want %02h", index, cmd_q[index],
                         init_ref(index));
            check(n_cmd > index && cmd_q[index] === init_ref(index),
                  "initialisation byte differs");
        end

        // ---- 2: page address and the two column address bytes per page
        for (page = 0; page < 8; page = page + 1) begin
            base = INIT_BYTES + page * PAGE_CMDS;
            check(cmd_q[base + 0] === (8'hB0 | page[7:0]), "page address byte");
            check(cmd_q[base + 1] === 8'h00, "column low nibble byte");
            check(cmd_q[base + 2] === 8'h10, "column high nibble byte");
        end

        // ---- 3: every frame byte, in order, straight out of the BSRAM
        check(n_data == FRAME_BYTES, "frame byte count is not 1024");
        check(first_data_cmds == INIT_BYTES + PAGE_CMDS,
              "the first frame byte did not follow page 0's address bytes");
        for (index = 0; index < FRAME_BYTES; index = index + 1) begin
            if (index < n_data && data_q[index] !== u_img.mem[index])
                $display("  frame[%0d] = %02h, want %02h", index, data_q[index],
                         u_img.mem[index]);
            check(index < n_data && data_q[index] === u_img.mem[index],
                  "frame byte differs from the framebuffer");
        end

        // ---- 5: it stops, and stays stopped
        check(busy === 1'b0, "busy is still high after done");
        check(sck === 1'b0 && cs_n === 1'b1, "bus leaves the idle levels after done");
        check(blk_bad == 0, "blk was not held high");
        repeat (2000) @(negedge clk);
        check(sck === 1'b0 && cs_n === 1'b1, "sck moved after done");
        check(n_cmd == INIT_BYTES + 8 * PAGE_CMDS && n_data == FRAME_BYTES,
              "a byte was captured after done");

        if (errors != 0) $fatal(1, "TB_OLED_STATIC: %0d error(s)", errors);
        $display("PASS %0d commands, %0d data bytes, res_n low %0d ns",
                 n_cmd, n_data, res_low_width);
        $display("TB_OLED_STATIC RESULT: PASS");
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "tb_oled_static timeout (state=%0d cmd=%0d data=%0d)",
               dut.state_q, n_cmd, n_data);
    end
endmodule
