// Multi-waveform LFO that modulates the ladder cutoff index in the log domain.
//
// This is the filter LFO of specs 2026-11-01-filter-lfo-design.md 5.5, 5.8 and
// 11.1 -- NOT the wavetable morph LFO.  v2_wt_position walks a Q2.24 frame
// position from WT_SELECT[8]; this one turns 0x44 into a bipolar +-depth ci
// offset.  They keep separate phase accumulators on purpose (spec 5.8): sharing
// one would lock the two sweeps together.
//
//   inc    = (rate_mhz * 45813) >> 9     Q9 form of 2^32/48000/1000 = 89.478
//   tri    = phase[31] ? ~phase[30:0] : phase[30:0]
//   b      = tri - 2^30                  bipolar, -2^30 .. +2^30-1 = +-1.0
//   offset = (b_wave * depth) >>> 30     depth 0..255 -> +-255 ci units
//
// One ci unit is 1/48 octave, so depth 255 is +-5.3 octaves of cutoff motion.
// depth 0 leaves the cutoff alone.  The offset is truncated, not rounded, so the
// peaks land one LSB inside +depth (the trough hits -depth exactly); spec 5.5
// asks for that formula and 1/48 of an octave is far below hearing.
//
// Waveforms (0x44[29:27]):
//   0 triangle, 1 sine, 2 saw, 3 square, 4 sample and hold.
// Sine is the minimax odd cubic b*(1.54806 - 0.55254*(b/2^30)^2): measured worst
// case error 0.46% of full scale, so it needs no table and no BSRAM.  Sample and
// hold advances a 32-bit LFSR (x^32+x^22+x^2+x+1) once per LFO period, not once
// per sample, so its staircase steps at the period rate.
//
// Time base and bypass: the phase advances on every sample_ce whether or not
// enable is set, because the modulation must keep its 48 kHz time base while the
// filter is bypassed (spec 5.6, review focus 3).  enable only zeroes the output.
// trigger is a one-clock strobe and is NOT gated by sample_ce: the note-on edge
// that drives it has no reason to land on the 48 kHz grid, and a missed strobe
// would silently skip the retrigger.  retrig=0 ignores trigger entirely.
module v2_lfo_triangle (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic [15:0]        rate_mhz,
    input  logic [7:0]         depth,
    input  logic               enable,
    input  logic               retrig,
    input  logic               trigger,
    input  logic               unipolar,
    input  logic [2:0]         waveform,
    output logic signed [12:0] offset_ci
);
    // 2^32 / 48000 / 1000 in Q9: 45813/512 = 89.478...
    localparam logic [15:0] RATE_Q9    = 16'd45813;
    localparam logic [31:0] LFSR_SEED  = 32'hA5C3_1E27;
    // Minimax odd cubic for sin(pi*u/2), u in [0,1]: u*(A - C*u^2).
    localparam logic [15:0] SINE_A_Q15 = 16'd50727;   // 1.54806
    localparam logic [15:0] SINE_C_Q15 = 16'd18108;   // 0.55254
    localparam logic signed [31:0] ONE_Q30 = 32'sd1073741824;

    logic [31:0] phase;
    logic [31:0] inc;
    logic [32:0] phase_sum;
    logic        period_end;
    logic [31:0] lfsr;
    logic [30:0] tri_val;
    logic signed [31:0] bipolar;

    // Sine, computed from the triangle so the waveform mux stays loop free.
    logic               sine_neg;
    logic [30:0]        sine_mag;
    logic [15:0]        u_q15;
    logic [31:0]        u_sq_full;
    logic [15:0]        u_sq_q15;
    logic [31:0]        sine_prod;
    logic [31:0]        sine_term;
    logic [15:0]        sine_poly;
    logic [31:0]        sine_prod2;
    logic [15:0]        sine_q15;
    logic [31:0]        sine_abs;
    logic signed [31:0] sine_b;

    logic signed [31:0] wave_b;
    logic signed [19:0] b_q;
    logic signed [27:0] depth_prod;
    logic signed [27:0] offset_bi;
    logic signed [27:0] offset_abs;
    logic signed [27:0] offset_out;

    assign inc        = ({16'd0, rate_mhz} * {16'd0, RATE_Q9}) >> 9;
    assign phase_sum  = {1'b0, phase} + {1'b0, inc};
    assign period_end = sample_ce && phase_sum[32];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 32'd0;
            lfsr  <= LFSR_SEED;
        end else if (retrig && trigger) begin
            phase <= 32'd0;
        end else if (sample_ce) begin
            phase <= phase_sum[31:0];
            if (period_end) begin
                lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            end
        end
    end

    assign tri_val = phase[31] ? ~phase[30:0] : phase[30:0];
    assign bipolar = $signed({1'b0, tri_val}) - 32'sd1073741824;

    assign sine_neg  = bipolar[31];
    assign sine_mag  = sine_neg ? (~bipolar[30:0] + 31'd1) : bipolar[30:0];
    assign u_q15     = sine_mag[30:15];
    assign u_sq_full = {16'd0, u_q15} * {16'd0, u_q15};
    assign u_sq_q15  = u_sq_full[30:15];
    assign sine_prod = {16'd0, SINE_C_Q15} * {16'd0, u_sq_q15};
    assign sine_term = sine_prod >> 15;
    assign sine_poly = SINE_A_Q15 - sine_term[15:0];
    assign sine_prod2 = {16'd0, u_q15} * {16'd0, sine_poly};
    assign sine_q15  = sine_prod2[30:15];
    assign sine_abs  = {16'd0, sine_q15} << 15;
    assign sine_b    = sine_neg ? -$signed(sine_abs) : $signed(sine_abs);

    always_comb begin
        case (waveform)
            3'd1:    wave_b = sine_b;
            3'd2:    wave_b = $signed(phase) >>> 1;
            3'd3:    wave_b = phase[31] ? -ONE_Q30 : ONE_Q30;
            3'd4:    wave_b = $signed(lfsr) >>> 1;
            default: wave_b = bipolar;
        endcase
    end

    // (b_wave * depth) >>> 30, with b_wave shortened to 20 bits first: the
    // truncation costs less than one LSB of depth at the output.
    assign b_q        = wave_b >>> 12;
    assign depth_prod = b_q * $signed({1'b0, depth});
    assign offset_bi  = depth_prod >>> 18;
    assign offset_abs = offset_bi[27] ? -offset_bi : offset_bi;
    assign offset_out = unipolar ? offset_abs : offset_bi;
    assign offset_ci  = enable ? $signed(offset_out[12:0]) : 13'sd0;
endmodule
