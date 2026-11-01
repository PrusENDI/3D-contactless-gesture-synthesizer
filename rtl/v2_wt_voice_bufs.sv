// Per-voice storage between the 32-voice scan and the wavetable engine.
//
// The scan owns the phases (it computes the next ones) and consumes the samples;
// the wavetable engine owns the samples (it produces them from the tables) and
// consumes the phases.  Each side addresses one slot per cycle, and the two sides
// never run at the same time, so plain register arrays with combinational reads
// are enough - no dual-clock RAM, no BSRAM needed at this size.
module v2_wt_voice_bufs #(
    parameter integer VOICES = 32
) (
    input  logic                clk,
    input  logic                rst_n,
    // Scan side: read the sample, write the phase for this slot.
    input  logic                scan_en,
    input  logic [4:0]          scan_slot,
    input  logic                scan_phase_we,
    input  logic [31:0]         scan_phase_a,
    input  logic [31:0]         scan_phase_b,
    output logic signed [15:0]  scan_sample_a,
    output logic signed [15:0]  scan_sample_b,
    // Wavetable-engine side: read the phase, write the sample for this slot.
    input  logic                eng_en,
    input  logic [4:0]          eng_slot,
    output logic [31:0]         eng_phase_a,
    output logic [31:0]         eng_phase_b,
    input  logic                eng_sample_we,
    input  logic signed [15:0]  eng_sample_a,
    input  logic signed [15:0]  eng_sample_b
);

    logic [31:0] phase_a  [0:VOICES-1];
    logic [31:0] phase_b  [0:VOICES-1];
    logic signed [15:0] sample_a [0:VOICES-1];
    logic signed [15:0] sample_b [0:VOICES-1];

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < VOICES; i = i + 1) begin
                phase_a[i]  <= 32'd0;
                phase_b[i]  <= 32'd0;
                sample_a[i] <= 16'sd0;
                sample_b[i] <= 16'sd0;
            end
        end else begin
            if (scan_en && scan_phase_we) begin
                phase_a[scan_slot] <= scan_phase_a;
                phase_b[scan_slot] <= scan_phase_b;
            end
            if (eng_en && eng_sample_we) begin
                sample_a[eng_slot] <= eng_sample_a;
                sample_b[eng_slot] <= eng_sample_b;
            end
        end
    end

    assign scan_sample_a = sample_a[scan_slot];
    assign scan_sample_b = sample_b[scan_slot];
    assign eng_phase_a   = phase_a[eng_slot];
    assign eng_phase_b   = phase_b[eng_slot];

endmodule
