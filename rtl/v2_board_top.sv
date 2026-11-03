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
    // Idle levels until the writer is instantiated: clock low, data low,
    // command mode, chip selected-off, reset released, backlight on.
    assign oled_sck   = 1'b0;
    assign oled_mosi  = 1'b0;
    assign oled_dc    = 1'b0;
    assign oled_cs_n  = 1'b1;
    assign oled_res_n = 1'b1;
    assign oled_blk   = 1'b1;

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
