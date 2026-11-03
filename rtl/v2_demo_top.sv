// Demo bitstream top: the N-tone DDS test generator on its own.
//
// This is a SECOND synthesis top, not the instrument.  It exists for one claim:
// the audio on the DAC is computed per sample by hardware (phase accumulators,
// a single-cycle sine table, an adder) and never played back from memory.  See
// docs/superpowers/specs/2026-11-03-demo-dds-bitstream-design.md.
//
// The port list is copied verbatim from `v2_board_top`, so the same pin
// constraints and the same programming script apply; the modules this top does
// not use are tied off here.
//
// Body starts empty on purpose: the gate needs a second root before anything
// can be built for it (scripts/gate.py refuses a second uninstantiated module).
module v2_demo_top (
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
    output wire oled_sck,
    output wire oled_mosi,
    output wire oled_dc,
    output wire oled_cs_n,
    output wire oled_res_n,
    output wire oled_blk
);
    // No sensor, no host: the MGC3130 bus is left floating and the UART idles
    // high.  Nothing in this bitstream can receive audio from outside.
    assign mgc_sda = 1'bz;
    assign mgc_scl = 1'bz;
    assign mgc_ts  = 1'bz;
    assign mgc_mclr = 1'bz;
    assign uart_tx = 1'b1;

    // Silence until the tone engine is wired in.
    assign pcm5102a_bck  = 1'b0;
    assign pcm5102a_lrck = 1'b0;
    assign pcm5102a_din  = 1'b0;

    // Panel held in reset, backlight off.
    assign oled_sck   = 1'b0;
    assign oled_mosi  = 1'b0;
    assign oled_dc    = 1'b0;
    assign oled_cs_n  = 1'b1;
    assign oled_res_n = 1'b0;
    assign oled_blk   = 1'b0;
endmodule
