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
//
// offset_ci is a REGISTER clocked on sample_ce (13 flops), not a combinational
// function of the phase.  The LFO needs one new value per 48 kHz sample, so the
// register is free, and it keeps the multiply chain out of the cutoff sum that
// the filter's coefficient address is built from.  The sine cubic is itself a
// three-multiply chain that cannot close in one 80 MHz clock, so it is pipelined
// one multiplier per sample_ce stage (u -> u^2 -> A - C u^2 -> sine); that costs
// three more samples on the sine waveform only, and its pipeline is primed with
// the phase-0 operands so a reset never publishes a transient.  The phase time
// base and the other four waveforms are unchanged, apart from the single sample
// of output register latency.  Because the retrigger strobe is not aligned to
// sample_ce, the output register also loads on a retrigger edge, from phase 0,
// so the trough appears immediately and no strobe is lost.
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
    logic [31:0] phase_val;
    logic [31:0] inc;
    logic [32:0] phase_sum;
    logic        period_end;
    logic [31:0] lfsr;
    logic [30:0] tri_val;
    logic signed [31:0] bipolar;

    // Sine, computed from the triangle so the waveform mux stays loop free.
    // The cubic is a three-multiply chain, far too slow for one 80 MHz clock, so
    // it is pipelined one multiplier per sample_ce stage.  Since the LFO needs
    // one result per 48 kHz sample, the pipeline costs no throughput; it costs
    // three samples of extra latency on the sine waveform only.  The pipeline is
    // primed at reset with the phase-0 operands, so it starts from sine(0) and
    // does not publish a transient after a reset.
    logic               sine_neg;
    logic [30:0]        sine_mag;
    logic [15:0]        u_q15;
    logic [15:0]        u_a, u_b, u_c;        // u delayed by 0, 1, 2 samples
    logic               neg_a, neg_b, neg_c;  // sign of the same samples
    logic [31:0]        sq_b;                 // u^2 in Q30, one sample old
    logic [15:0]        poly_c;               // A - C u^2 in Q15, two samples old
    logic signed [31:0] sine_d;               // sine in Q30, three samples old

    logic signed [31:0] wave_direct;          // triangle/saw/square/S&H
    logic signed [31:0] wave_sine;
    logic signed [31:0] wave_b;
    logic signed [19:0] b_q;
    logic signed [27:0] depth_prod;
    logic signed [27:0] offset_bi;
    logic signed [27:0] offset_abs;
    logic signed [27:0] offset_out;

    // Every multiply below is kept at its natural 16-bit operand width.  A
    // {16'd0, x} zero extension makes the operand 32 bits, which the
    // synthesizer turns into a 32x32 LUT multiplier; the 16x16 form fits one
    // MULTALU27X18 slice, and because the true product is < 2^32 the low 32
    // bits (all this code slices) are bit-identical.
    assign inc        = (rate_mhz * RATE_Q9) >> 9;
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

    // The waveform is derived from phase_val: phase, except on a retrigger edge,
    // where it is the cleared phase so the output register loads the trough.
    assign phase_val = (retrig && trigger) ? 32'd0 : phase;
    assign tri_val = phase_val[31] ? ~phase_val[30:0] : phase_val[30:0];
    assign bipolar = $signed({1'b0, tri_val}) - 32'sd1073741824;

    assign sine_neg  = bipolar[31];
    assign sine_mag  = sine_neg ? (~bipolar[30:0] + 31'd1) : bipolar[30:0];
    assign u_q15     = sine_mag[30:15];

    always_comb begin
        case (waveform)
            3'd2:    wave_direct = $signed(phase_val) >>> 1;
            3'd3:    wave_direct = phase_val[31] ? -ONE_Q30 : ONE_Q30;
            3'd4:    wave_direct = $signed(lfsr) >>> 1;
            default: wave_direct = bipolar;     // triangle (sine is unused here)
        endcase
    end

    // sine(pi/2 * 1) in the same Q30 form the pipeline produces at phase 0, so a
    // retrigger with the sine selected publishes the trough of the waveform at
    // once instead of waiting for the three pipeline stages.
    localparam logic signed [31:0] SINE_ZERO_B = -32'sd1068859392;

    assign wave_sine = (retrig && trigger) ? SINE_ZERO_B : sine_d;
    assign wave_b    = (waveform == 3'd1) ? wave_sine : wave_direct;

    // One multiplier per sample_ce stage.  The operands are carried alongside
    // their sample so stage 3 multiplies u by the polynomial of THAT sample.
    logic [31:0] u_sq_full;
    logic [15:0] u_sq_q15;
    logic [31:0] sine_prod;
    logic [31:0] sine_prod2;
    logic [15:0] sine_q15;
    logic [31:0] sine_abs;

    assign u_sq_full  = u_a * u_a;
    assign u_sq_q15   = sq_b[30:15];
    assign sine_prod  = SINE_C_Q15 * u_sq_q15;
    assign sine_prod2 = u_c * poly_c;
    assign sine_q15   = sine_prod2[30:15];
    assign sine_abs   = {16'd0, sine_q15} << 15;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_a    <= 16'd32768;               // u at phase 0
            u_b    <= 16'd32768;
            u_c    <= 16'd32768;
            neg_a  <= 1'b1;
            neg_b  <= 1'b1;
            neg_c  <= 1'b1;
            sq_b   <= 32'd1073741824;          // u^2 at phase 0
            poly_c <= 16'd32619;               // A - C at phase 0
            sine_d <= SINE_ZERO_B;
        end else if (sample_ce) begin
            u_a    <= u_q15;
            neg_a  <= sine_neg;
            u_b    <= u_a;
            neg_b  <= neg_a;
            u_c    <= u_b;
            neg_c  <= neg_b;
            sq_b   <= u_sq_full;
            poly_c <= SINE_A_Q15 - sine_prod[30:15];
            sine_d <= neg_c ? -$signed(sine_abs) : $signed(sine_abs);
        end
    end

    // (b_wave * depth) >>> 30, with b_wave shortened to 20 bits first: the
    // truncation costs less than one LSB of depth at the output.
    assign b_q        = wave_b >>> 12;
    assign depth_prod = b_q * $signed({1'b0, depth});
    assign offset_bi  = depth_prod >>> 18;
    assign offset_abs = offset_bi[27] ? -offset_bi : offset_bi;
    assign offset_out = unipolar ? offset_abs : offset_bi;

    // Registered on the 48 kHz sample beat; see the header.  A retrigger edge
    // loads the trough at once even though it is not sample_ce aligned.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) offset_ci <= 13'sd0;
        else if (sample_ce || (retrig && trigger))
            offset_ci <= enable ? $signed(offset_out[12:0]) : 13'sd0;
    end
endmodule
