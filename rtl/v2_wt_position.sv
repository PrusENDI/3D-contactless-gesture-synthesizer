// Q2.24 wavetable position LFO.
//
// position 1.0 = 26'h1000000, 2.0 = 26'h2000000.  The LFO walks 0 -> 2.0 and
// back at `step` per sample, so a host that wants a 20 s one-way sweep writes
// step = round(2^25 / (20 * 48000)) = 35.  Frame index and frac are pure slices
// of position, which keeps the frame mapping testable without a sweep.
module v2_wt_position #(
    parameter logic [25:0] POS_ONE = 26'h1000000,
    parameter logic [25:0] POS_TWO = 26'h2000000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic        morph_en,
    input  logic [22:0] step,
    output logic [25:0] pos,
    output logic [1:0]  frame_a,
    output logic [1:0]  frame_b,
    output logic [7:0]  frac
);
    logic        dir_up;
    logic        morph_en_q;
    logic [25:0] step_ext;

    assign step_ext = {3'd0, step};
    assign frame_a  = pos[25:24];
    assign frame_b  = (pos[25:24] == 2'd2) ? 2'd2 : pos[25:24] + 2'd1;
    assign frac     = pos[23:16];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos       <= 26'd0;
            dir_up    <= 1'b1;
            morph_en_q <= 1'b0;
        end else begin
            morph_en_q <= morph_en;
            if (morph_en && !morph_en_q) begin
                pos    <= 26'd0;
                dir_up <= 1'b1;
            end else if (sample_ce && morph_en) begin
                if (dir_up) begin
                    if (pos >= (POS_TWO - step_ext)) begin
                        pos    <= POS_TWO;
                        dir_up <= 1'b0;
                    end else begin
                        pos <= pos + step_ext;
                    end
                end else begin
                    if (pos <= step_ext) begin
                        pos    <= 26'd0;
                        dir_up <= 1'b1;
                    end else begin
                        pos <= pos - step_ext;
                    end
                end
            end
        end
    end
endmodule
