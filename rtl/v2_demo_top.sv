// Demo bitstream top: 32-tone DDS + an SSD1306 that shows which count is playing.
//
// This is a SECOND synthesis top, not the instrument.  It exists for one claim:
// the audio leaving the DAC is computed every sample by hardware (phase
// accumulators, a single-cycle sine table, an adder) and never played back from
// memory.  See docs/superpowers/specs/2026-11-03-demo-dds-bitstream-design.md.
//
// Two clock domains, no data between them:
//   * audio  80 MHz (PLL): scheduler, sequencer, DDS block, mute gate, I2S;
//   * panel  50 MHz (the board oscillator, as in v2_board_top): the panel writer
//     and the picture composer.  Only the 6-bit tone count crosses, through two
//     flops; it changes once every few seconds, so no handshake is needed.
//
// The port list is copied verbatim from `v2_board_top`, so the same pin
// constraints and the same programming script apply.
module v2_demo_top #(
    parameter integer TONE_FRAMES       = 192_000,   // 4 s at 48 kHz
    parameter integer HOLD32_FRAMES     = 960_000,   // 20 s
    parameter integer GAP_FRAMES        = 24_000,    // 0.5 s of true silence
    parameter integer SPI_DIV           = 50,        // 50 MHz / 50 = 1 MHz
    parameter integer OLED_RESET_CYCLES = 5000,      // 100 us
    parameter integer OLED_WAKE_CYCLES  = 5_000_000  // 100 ms
) (
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
    // ------------------------------------------------------------ audio clock --
    logic clk_sys, pll_locked, rst_sys_n;
    v2_clock_gen u_clock(.clk_in(clk_50m), .rst_n(1'b1),
                         .clk_sys_100m(clk_sys), .pll_locked(pll_locked));
    logic [3:0] por_count = 4'd0;
    wire por_n = &por_count;
    always_ff @(posedge clk_sys or negedge pll_locked) begin
        if (!pll_locked) por_count <= 4'd0;
        else if (!por_n) por_count <= por_count + 1'b1;
    end
    v2_reset_sync u_reset(.clk_sys_100m(clk_sys), .rst_n(por_n),
                          .pll_locked(pll_locked), .rst_sys_n(rst_sys_n));

    logic sample_ce;
    v2_sample_scheduler u_scheduler(.clk_sys(clk_sys), .rst_n(rst_sys_n),
                                    .sample_ce(sample_ce), .sample_index());

    // --------------------------------------------------------------- the DDS --
    logic [7:0]  seq_csr_addr;
    logic [31:0] seq_csr_wdata;
    logic        seq_csr_valid, seq_csr_write;
    logic [5:0]  seq_tone_count;
    logic        seq_muted;
    logic [1:0]  seq_segment;

    v2_demo_sequencer #(
        .TONE_FRAMES(TONE_FRAMES), .HOLD32_FRAMES(HOLD32_FRAMES), .GAP_FRAMES(GAP_FRAMES)
    ) u_seq (
        .clk(clk_sys), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .csr_valid(seq_csr_valid), .csr_write(seq_csr_write),
        .csr_addr(seq_csr_addr), .csr_wdata(seq_csr_wdata),
        .demo_tone_count(seq_tone_count), .demo_muted(seq_muted),
        .demo_segment(seq_segment)
    );

    logic               test_ready, test_rvalid;
    logic [31:0]        test_rdata;
    logic signed [15:0] test_sample;
    logic               test_sample_valid;

    v2_test_mode #(.MAX_TONES(32)) u_test (
        .clk(clk_sys), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .csr_valid(seq_csr_valid), .csr_write(seq_csr_write),
        .csr_addr(seq_csr_addr), .csr_wdata(seq_csr_wdata),
        .csr_ready(test_ready), .csr_rvalid(test_rvalid), .csr_rdata(test_rdata),
        .mixed_sample(test_sample), .sample_valid(test_sample_valid),
        .active_bitmap(), .sample_counter(), .test_active(), .fault()
    );

    // Make the gaps real silence.  On its own the DDS block clears mixed_sample
    // but stops asserting sample_valid, and the I2S transmitter then holds the
    // last sample -- a DC step, not silence.  During a gap this gate latches a
    // zero every 48 kHz frame instead.
    wire signed [15:0] i2s_in    = seq_muted ? 16'sd0 : test_sample;
    wire               i2s_valid = seq_muted ? sample_ce : test_sample_valid;

    i2s_pcm5102a_tx #(.CLK_HZ(80_000_000), .SAMPLE_HZ(48_000), .ACC_WIDTH(24)) u_i2s (
        .clk(clk_sys), .rst(!rst_sys_n), .sample_valid(i2s_valid),
        .sample_in(i2s_in),
        .i2s_bck(pcm5102a_bck), .i2s_lrck(pcm5102a_lrck), .i2s_din(pcm5102a_din)
    );

    // ------------------------------------------------------------- the panel --
    // Its own power-on reset on the 50 MHz oscillator: configuration leaves every
    // register at 0 and the counter stops, so no button is needed.
    logic [7:0] oled_por_q = 8'd0;
    wire        oled_por_n = &oled_por_q;
    always_ff @(posedge clk_50m) begin
        if (!oled_por_n) oled_por_q <= oled_por_q + 8'd1;
    end

    // The writer is one-shot by design (production never rewrites the panel), so
    // the demo restarts it through its reset.  Cost: the panel blanks for about
    // 100 ms + 8.6 ms, three times per 29.5 s cycle.
    logic [5:0]  tc_meta_q, tc_sync_q, tc_seen_q;
    logic [4:0]  hold_q;
    logic        writer_rst_n_q, dirty_q, done_q1;
    logic        oled_busy, oled_done;

    always_ff @(posedge clk_50m or negedge oled_por_n) begin
        if (!oled_por_n) begin
            tc_meta_q      <= 6'd0;
            tc_sync_q      <= 6'd0;
            tc_seen_q      <= 6'd0;
            hold_q         <= 5'd16;
            writer_rst_n_q <= 1'b0;
            dirty_q        <= 1'b0;
            done_q1        <= 1'b0;
        end else begin
            tc_meta_q <= seq_tone_count;
            tc_sync_q <= tc_meta_q;
            done_q1   <= oled_done;

            if (tc_sync_q != tc_seen_q) begin
                tc_seen_q <= tc_sync_q;
                dirty_q   <= 1'b1;
            end

            if (hold_q != 5'd0) begin
                hold_q         <= hold_q - 5'd1;
                writer_rst_n_q <= (hold_q == 5'd1);
            end else if (done_q1 && dirty_q) begin
                dirty_q        <= 1'b0;
                hold_q         <= 5'd16;
                writer_rst_n_q <= 1'b0;
            end
        end
    end

    logic [9:0] oled_addr;
    logic [7:0] oled_data;

    v2_oled_tones u_tones(
        .img_addr(oled_addr), .tone_count(tc_sync_q), .img_data(oled_data)
    );

    v2_oled_static #(
        .SPI_DIV(SPI_DIV), .RESET_CYCLES(OLED_RESET_CYCLES),
        .WAKE_CYCLES(OLED_WAKE_CYCLES)
    ) u_oled (
        .clk(clk_50m), .rst_n(oled_por_n & writer_rst_n_q), .start(1'b1),
        .img_data(oled_data), .img_addr(oled_addr),
        .sck(oled_sck), .mosi(oled_mosi), .dc(oled_dc), .cs_n(oled_cs_n),
        .res_n(oled_res_n), .blk(oled_blk), .busy(oled_busy), .done(oled_done)
    );

    // --------------------------------------------------------- unused pins --
    // No sensor, no host: nothing in this bitstream can receive audio.
    assign mgc_sda  = 1'bz;
    assign mgc_scl  = 1'bz;
    assign mgc_ts   = 1'bz;
    assign mgc_mclr = 1'bz;
    assign uart_tx  = 1'b1;
endmodule
