// Board top: the single synthesis top of this project.
//
// Renamed from `sim/v2_top_fullpath_probe.sv` of the legacy tree; the body
// (parameter set and port map) is unchanged.  The preserve switches make the
// real reader/Loop/Potts planes reachable for attribution, which is what the
// board build has always targeted.
module v2_board_top (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    input  wire uart_rx,
    output wire uart_tx,
    output wire pcm5102a_bck,
    output wire pcm5102a_lrck,
    output wire pcm5102a_din,
    // 0.96" 128x64 SSD1306 on the J3 header, 7-pin SPI (see the OLED spec).
    // D0/D1 are silkscreened SCL/SDA but DC and CS make it SPI, not I2C.
    output wire oled_sck,
    output wire oled_mosi,
    output wire oled_dc,
    output wire oled_cs_n,
    output wire oled_res_n,
    output wire oled_blk
);
    // The panel writer has no reset button on the board and needs none: the
    // FPGA comes out of configuration with every register at 0, so a counter
    // that stops after 256 clocks is a power-on reset.  It runs on the 50 MHz
    // oscillator, not on the audio PLL, so it cannot touch the audio cone.
    logic [7:0] oled_por_q = 8'd0;
    wire        oled_rst_n = &oled_por_q;
    always_ff @(posedge clk_50m) begin
        if (!(&oled_por_q)) oled_por_q <= oled_por_q + 8'd1;
    end

    logic [9:0] oled_addr;
    logic [7:0] oled_data;
    logic       oled_busy;
    logic       oled_done;

    // 1024 bytes of frame in one BSRAM; see host/oled_image.py.
    v2_oled_image u_oled_image (
        .clk(clk_50m),
        .addr(oled_addr),
        .data(oled_data)
    );

    // 50 MHz / 50 = 1 MHz SPI.  start is a level: the writer sequences its own
    // reset pulse, the panel wake-up delay and the init table.
    v2_oled_static #(
        .SPI_DIV(50),
        .RESET_CYCLES(5000),        // 100 us with res_n low
        .WAKE_CYCLES(5_000_000)     // 100 ms before the first command
    ) u_oled (
        .clk(clk_50m),
        .rst_n(oled_rst_n),
        .start(1'b1),
        .img_data(oled_data),
        .img_addr(oled_addr),
        .sck(oled_sck),
        .mosi(oled_mosi),
        .dc(oled_dc),
        .cs_n(oled_cs_n),
        .res_n(oled_res_n),
        .blk(oled_blk),
        .busy(oled_busy),
        .done(oled_done)
    );

    mgc3130_v2_top #(
        .USE_MGC_READER(1),
        .USE_GOWIN_RAM(1),
        .USE_POTTS(1),
        .PRESERVE_LOOP_PLANE(0),
        .PRESERVE_POTTS_PLANE(0),
        .POTTS_HORIZON(32),
        .FX_ENABLE(1),
        .FX_LEVEL(1),
        // The 1/8/32-note test tones are compiled out of the production build;
        // a dedicated test bitstream flips this to 1 (TEST_SELECT, 0xA0).
        .USE_TEST_MODE(0)
    ) u_v2 (
        .clk_50m,
        .mgc_sda,
        .mgc_scl,
        .mgc_ts,
        .mgc_mclr,
        .uart_rx,
        .uart_tx,
        .pcm5102a_bck,
        .pcm5102a_lrck,
        .pcm5102a_din
    );
endmodule
