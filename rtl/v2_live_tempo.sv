// LIVE X-axis tempo: cursor_x 0..65535 -> 30..59 BPM.
//
// The divider tempo must update on cursor frames, not on UART commands.  The
// write strobe is delayed two cycles so the divider samples the already-updated
// value; a frame whose target equals the current tempo does not pulse it.
module v2_live_tempo (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        frame_done,
    input  logic [15:0] x,
    output logic [15:0] bpm,
    output logic        bpm_we
);
    logic [15:0] bpm_q;
    logic        changed_q, we_q;
    wire  [23:0] scaled = ({8'd0, x} << 5) - ({8'd0, x} << 1);   // x * 30
    wire  [15:0] target = 16'd30 + {1'b0, scaled[20:16]};        // 30..59

    assign bpm = bpm_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bpm_q    <= 16'd120;
            changed_q <= 1'b0;
            we_q      <= 1'b0;
            bpm_we    <= 1'b0;
        end else begin
            changed_q <= frame_done && (target != bpm_q);
            we_q      <= changed_q;
            bpm_we    <= we_q;
            if (changed_q) bpm_q <= target;
        end
    end
endmodule
