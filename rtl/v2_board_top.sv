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
    output wire pcm5102a_din
);
    mgc3130_v2_top #(
        .USE_MGC_READER(1),
        .USE_GOWIN_RAM(1),
        .USE_POTTS(1),
        .PRESERVE_LOOP_PLANE(1),
        .PRESERVE_POTTS_PLANE(1),
        .POTTS_HORIZON(32),
        .FX_ENABLE(1),
        .FX_LEVEL(1)
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
