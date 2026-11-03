// N-tone demo sequencer: walks the DDS block through 1 -> 8 -> 32 tones.
//
// The demo bitstream has no UART, so the tone count has to change by itself: a
// judge who sees 32 spectral peaks must also be able to see that the count is
// not frozen.  This module is the only thing that ever writes TEST_SELECT.
//
// Rules it encodes (design section 4.1):
//   * the N word is (N << 8) | 1; N lives in [13:8], the selector in [7:0];
//   * 32'h0000_0000 is never written -- selector != 1 lights the block's sticky
//     fault and does not stop it either;
//   * the write happens on the gap -> segment edge, so the block restarts its
//     phases exactly when the mute gate opens (no step, no click);
//   * the gap itself is silence produced by the mute output, not by the block.
module v2_demo_sequencer #(
    // Frames (48 kHz samples) per 1-tone and 8-tone segment: 4 s.
    parameter integer TONE_FRAMES   = 192_000,
    // The 32-tone segment is the measurement window: 20 s.
    parameter integer HOLD32_FRAMES = 960_000,
    // True silence between segments: 0.5 s.
    parameter integer GAP_FRAMES    = 24_000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    output logic        csr_valid,
    output logic        csr_write,
    output logic [7:0]  csr_addr,
    output logic [31:0] csr_wdata,
    output logic [5:0]  demo_tone_count,
    output logic        demo_muted,
    output logic [1:0]  demo_segment
);
    import v2_contract_pkg::*;

    // Segment values are the indices, the counts are the audio truth.
    localparam logic [5:0] COUNT_A = 6'd1;
    localparam logic [5:0] COUNT_B = 6'd8;
    localparam logic [5:0] COUNT_C = 6'd32;

    logic [1:0]  seg_q;
    logic        gap_q;
    logic [31:0] frame_q;

    logic [1:0]  next_seg;
    logic [5:0]  next_count;
    always_comb begin
        case (seg_q)
            2'd0:    begin next_seg = 2'd1; next_count = COUNT_B; end
            2'd1:    begin next_seg = 2'd2; next_count = COUNT_C; end
            default: begin next_seg = 2'd0; next_count = COUNT_A; end
        endcase
    end

    // How long the phase that is running now lasts.
    wire [31:0] span = gap_q ? 32'(GAP_FRAMES)
                             : 32'((seg_q == 2'd2) ? HOLD32_FRAMES : TONE_FRAMES);

    assign csr_write = 1'b1;
    assign csr_addr  = V2_CSR_TEST_SELECT;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_q           <= 2'd2;        // "just finished 32": the first gap brings 1
            gap_q           <= 1'b1;
            frame_q         <= 32'd0;
            csr_valid       <= 1'b0;
            csr_wdata       <= 32'd0;
            demo_tone_count <= 6'd0;
            demo_muted      <= 1'b1;
            demo_segment    <= 2'd2;
        end else begin
            csr_valid <= 1'b0;
            if (sample_ce) begin
                if (frame_q + 32'd1 >= span) begin
                    frame_q <= 32'd0;
                    gap_q   <= ~gap_q;
                    if (gap_q) begin
                        // Gap -> segment: the block restarts from phase 0 with
                        // the new count at the same moment the gate opens.
                        seg_q           <= next_seg;
                        demo_segment    <= next_seg;
                        demo_tone_count <= next_count;
                        demo_muted      <= 1'b0;
                        csr_valid       <= 1'b1;
                        csr_wdata       <= {18'd0, next_count, 8'h01};
                    end else begin
                        // Segment -> gap: mute only; the count changes on the
                        // next edge so the panel and the audio agree.
                        demo_muted <= 1'b1;
                    end
                end else begin
                    frame_q <= frame_q + 32'd1;
                end
            end
        end
    end
endmodule
