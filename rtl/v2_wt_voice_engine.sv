// Wavetable engine: turns the per-voice phases into per-voice sample pairs.
//
// It runs after the voice scan has consumed the previous sample.  One sweep costs
// five cycles per slot: latch the phase indices, issue the reads for phase A,
// capture A while issuing phase B, capture B, then write the pair.  A single
// combinational mixer is enough because the two phases are captured a cycle apart.
//
//   idx    = phase[31:22]                                  (1024-point tables)
//   sample = mix(tableA[idx], tableB[idx], frac) >>> shift
//
// A sweep is started by one sample_ce and runs to completion; pulses that arrive
// while the sweep is busy are ignored.  If the loader reports no valid data, the
// slot is written as 0, so an empty table is silent rather than noisy.
module v2_wt_voice_engine #(
    parameter integer VOICES = 32
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                sample_ce,
    input  logic [1:0]          frame_a,
    input  logic [1:0]          frame_b,
    input  logic [7:0]          frac,
    input  logic [3:0]          shift,
    input  logic [31:0]         phase_a_in,
    input  logic [31:0]         phase_b_in,
    output logic [4:0]          slot,
    output logic                rd_en0,
    output logic [1:0]          rd_table0,
    output logic [9:0]          rd_index0,
    output logic                rd_en1,
    output logic [1:0]          rd_table1,
    output logic [9:0]          rd_index1,
    input  logic signed [15:0]  rd_sample0,
    input  logic signed [15:0]  rd_sample1,
    input  logic                rd_valid0,
    input  logic                rd_valid1,
    output logic                sample_we,
    output logic signed [15:0]  sample_a,
    output logic signed [15:0]  sample_b
);

    typedef enum logic [2:0] {
        E_IDLE  = 3'd0,
        E_LATCH = 3'd1,
        E_ISS_A = 3'd2,
        E_CAP_A = 3'd3,
        E_CAP_B = 3'd4,
        E_WRITE = 3'd5
    } eng_state_t;

    eng_state_t state;
    logic [9:0] idx_a_q, idx_b_q;
    logic signed [15:0] mix_a_q, mix_b_q;
    logic signed [15:0] mix_out;
    logic mix_ok_q;

    wire [9:0] idx_a = phase_a_in[31:22];
    wire [9:0] idx_b = phase_b_in[31:22];
    wire       mix_ok = rd_valid0 && rd_valid1;

    v2_wt_mix u_mix (
        .a(rd_sample0), .b(rd_sample1), .frac(frac), .out(mix_out)
    );

    assign rd_table0 = frame_a;
    assign rd_table1 = frame_b;
    assign rd_index0 = (state == E_CAP_A) ? idx_b_q : idx_a_q;
    assign rd_index1 = rd_index0;
    assign rd_en0    = (state == E_ISS_A) || (state == E_CAP_A);
    assign rd_en1    = rd_en0;
    assign sample_we = (state == E_WRITE);
    assign sample_a  = mix_ok_q ? (mix_a_q >>> shift) : 16'sd0;
    assign sample_b  = mix_ok_q ? (mix_b_q >>> shift) : 16'sd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= E_IDLE;
            slot     <= 5'd0;
            idx_a_q  <= 10'd0;
            idx_b_q  <= 10'd0;
            mix_a_q  <= 16'sd0;
            mix_b_q  <= 16'sd0;
            mix_ok_q <= 1'b0;
        end else begin
            case (state)
                E_IDLE: begin
                    if (sample_ce) begin
                        slot  <= 5'd0;
                        state <= E_LATCH;
                    end
                end
                E_LATCH: begin
                    // `slot` has been stable for a cycle, so the phase inputs are valid.
                    idx_a_q <= idx_a;
                    idx_b_q <= idx_b;
                    state   <= E_ISS_A;
                end
                E_ISS_A: state <= E_CAP_A;
                E_CAP_A: begin
                    mix_a_q  <= mix_out;
                    mix_ok_q <= mix_ok;
                    state    <= E_CAP_B;
                end
                E_CAP_B: begin
                    mix_b_q <= mix_out;
                    state   <= E_WRITE;
                end
                E_WRITE: begin
                    if (slot == (VOICES - 1)) state <= E_IDLE;
                    else begin
                        slot  <= slot + 5'd1;
                        state <= E_LATCH;
                    end
                end
                default: state <= E_IDLE;
            endcase
        end
    end

endmodule
