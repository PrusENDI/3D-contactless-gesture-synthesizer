// Wavetable playback: walks the active table once per audio sample and presents
// the sample read out of the uploader.
//
// The uploader's read port is registered (the DPB output follows the address by
// one clock), so the sample belonging to `index` appears on `sample` one cycle
// after `index` changes; the output register below captures exactly that beat and
// marks it valid for the same cycle the I2S block consumes it.
//
// One table entry per sample is deliberate: at 48 kHz over 1024 points the tone is
// 46.875 Hz, which makes the I2S output trivially predictable for a capture.
module v2_wt_playback (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               enable,
    output logic [9:0]         index,
    input  logic signed [15:0] sample,
    output logic signed [15:0] out,
    output logic               valid
);
    // 26-bit phase with the table index in the upper ten bits: one step per
    // sample means phase += 2^16.
    logic [25:0] phase;
    logic        valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 26'd0;
        end else if (sample_ce) begin
            phase <= phase + 26'd65536;
        end
    end

    assign index = phase[25:16];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out     <= 16'sd0;
            valid_q <= 1'b0;
        end else begin
            out     <= sample;
            valid_q <= enable && sample_ce;
        end
    end

    assign valid = valid_q;
endmodule
