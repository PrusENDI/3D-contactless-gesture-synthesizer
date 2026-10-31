// Wavetable playback: advances a 32-bit phase by an external increment and
// presents the sample read out of the uploader.
//
// The increment is f / 48000 * 2^32, which is exactly what v2_note_increment_rom
// already carries (A4 = 440 Hz -> 39,370,534).  index = phase[31:22] therefore
// selects one of 1024 points per cycle, and the phase wraps mod 2^32 on its own,
// so no explicit modulo is needed even at C5 (91.8 samples per cycle).
//
// The uploader's read port is registered (the DPB output follows the address by
// one clock), so the sample belonging to `index` appears on `sample` one cycle
// after `index` changes; the output register below captures exactly that beat and
// marks it valid for the same cycle the I2S block consumes it.
module v2_wt_playback (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               enable,
    input  logic [31:0]        increment,
    output logic [9:0]         index,
    input  logic signed [15:0] sample,
    output logic signed [15:0] out,
    output logic               valid
);
    logic [31:0] phase;
    logic        valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 32'd0;
        end else if (sample_ce) begin
            phase <= phase + increment;
        end
    end

    assign index = phase[31:22];

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
