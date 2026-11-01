// 24 dB/oct zero-delay-feedback ladder low-pass (P2a, plan task 5).
//
// Structure and numbers: docs/superpowers/specs/2026-11-01-filter-lfo-design.md
// 5.2, 5.3 and 5.6.  Four trapezoidal (TPT) one-poles are solved in one step, so
// the resonance sits at the same place for every cutoff and Kcrit stays at 4.0:
//
//   one pole:   v_i = G (u_i - s_i)     y_i = v_i + s_i     s_i <- y_i + v_i
//   four poles: y4  = G^4 u + S         S = (1-G) (G^3 s1 + G^2 s2 + G s3 + s4)
//   ZDF solve:  u   = (x - K S) / (1 + K G^4)         K = res * 960 / 65536
//
// 1/(1 + K G^4) is read from the reciprocal table in v2_filter_coeffs (addr
// 512..767, x = ridx*0.94/255) at ridx = min(255, (K G^4) * 271 / 65536), so
// there is no divider anywhere in the datapath.  G^4 is two multiplies of the
// same G table entry (spec 5.3).  res=255 gives K=3.735, just under the 4.0 that
// would self-oscillate (spec 5.2: no self-oscillation this round).
//
// S is evaluated in Horner form, (G (G s1 + s2) + s3) G + s4, which needs three
// multiplies instead of four.  K is never formed explicitly: it only appears as
// K*G^4 and K*S, and res*960*x/65536 is (res*x) * 960 >> 16, where *960 is
// (<<10) - (<<6).  That keeps both K terms off the DSPs and keeps every DSP
// operand inside the 27x18 shape of the Gowin MULTALU27X18 primitive.
//
// Time base (spec 5.6, review focus 2): the integrator states w1..w4 and the
// audio_out register are written ONLY on a sample_ce edge, so audio_out cannot
// change between two sample_ce pulses.  The arithmetic between two sample_ce
// pulses is a 14-deep pipeline, one multiplier per stage; it is finished long
// before the next sample_ce, and the next sample's input is consumed on that
// next edge.  The response to sample n therefore appears after the sample_ce of
// n+1: the one sample (20.8 us) of latency spec 5.6 accepts.  I2S valid is not
// delayed.
//
// Number format: 27-bit signed Q4.  With K=3.735 the loop gain is 0.9375, so the
// internal states swing to about 30x full scale for a full-scale sine at the
// resonant frequency; 27 bits holds that with a 4x margin while keeping 1/16
// LSB of resolution.  The state is deliberately NOT saturated: spec 5.2 says
// saturating the feedback term would move the resonant frequency.  Only the
// output is saturated, once.
//
// The four pole differences (u_r - w1, y1_r - w2, y2_r - w3, y3_r - w4) are the
// one deliberate exception.  The exact difference of two 27-bit Q4 values needs
// 28 bits, and a 28-bit operand pushes each 17x27 product into a two-slice
// MULT27X36.  Four of those consume eight of the 28 DSP slices; with none left,
// the 17x27 osm and 27x17 u_full products fell back to LUT multiplier arrays,
// the ~50 ns combinational chains that held Fmax at 20 MHz.  So each difference
// is formed in 28 bits and SATURATED to 27 bits (sat_diff) before the multiply,
// which fits one MULTALU27X18 slice and frees four slices for osm and u_full.
// The trade is honest: the clamp sits at +-2^26 Q4 = +-128x full scale, about
// 4x above the ~30x the states reach, so a normal resonant sine never touches
// it.  Only states driven past +-128x full scale clip, and there a saturating
// clamp is the least-bad answer -- a wrap would inject full-scale noise.  The
// states and the feedback update are still unsaturated, so the resonance does
// not move.
//
// ci is clamped to 423 here as well as upstream (spec 5.3: fc stops at 18 kHz),
// so a mis-written register cannot index past the end of the G table.  It is
// latched on sample_ce (ci_q) and the coefficient address is written from that
// register, so the table address never comes from the top's combinational
// ci_sum.  The latch costs one sample of cutoff latency, which at 48 kHz is
// below the LFO's own resolution; res is already latched (res_q) and never
// reaches the address path.

module v2_ladder_lp (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [15:0] audio_in,
    input  logic        [11:0] ci,
    input  logic        [7:0]  res,
    output logic signed [15:0] audio_out,
    output logic               out_valid
);

    localparam int          FRAC   = 4;        // fractional bits, Q4
    localparam int          WB     = 27;       // internal word, signed
    localparam logic [11:0] CI_MAX = 12'd423;  // fc <= 18 kHz
    localparam logic [9:0]  R_BASE = 10'd512;  // must equal v2_filter_coeffs.R_BASE

    // ---------------------------------------------------------- coefficient port
    logic [9:0]  coeff_addr;
    logic [15:0] coeff_dout;

    v2_filter_coeffs u_coeff (
        .clk  (clk),
        .addr (coeff_addr),
        .dout (coeff_dout)
    );

    // ------------------------------------------------- sample-domain state (Q4)
    // w1..w4 are the four integrator states.  They are written only on a
    // sample_ce edge, which is what keeps audio_out stable between samples.
    logic signed [WB-1:0] w1, w2, w3, w4;
    logic signed [WB-1:0] nx1, nx2, nx3, nx4;  // next states from the pipeline
    logic signed [WB-1:0] x_q;                 // input sample in Q4
    logic        [7:0]    res_q;               // resonance latched with the sample
    logic        [11:0]   ci_q;                // cutoff index latched on sample_ce
    logic signed [WB-1:0] sat_r;               // saturated result of the running sample
    logic        [13:0]   vap;                 // pipeline valid chain

    // ---------------------------------------------------- pipeline registers (Q16)
    logic [15:0] g_r, g2_r, g4_r;              // G, G^2, G^4
    logic [15:0] r_r;                          // 1/(1+K G^4)
    logic [16:0] x_r;                          // K G^4 in Q16
    logic signed [WB-1:0] h1_r, h2_r, h3_r;    // Horner steps down to S's bracket
    logic signed [WB-1:0] s_r, ks_r, u_r;      // S, K S, u
    logic signed [WB-1:0] y1_r, y2_r, y3_r;    // one-pole outputs 1..3

    // ------------------------------------------------------- combinational terms
    logic signed [WB-1:0] x_full;
    logic [31:0] g_sq, g2_sq;
    logic [15:0] g2_c, g4_c;
    logic [24:0] res_g4;
    logic [33:0] x_scaled;
    logic [16:0] x_c;
    logic [26:0] rid_mul;
    logic [7:0]  ridx_c;
    logic [16:0] one_minus_g;

    logic signed [43:0] gw1, gw2, gw3;         // G * (27-bit value)
    logic signed [44:0] osm;                   // (1-G) * h3
    logic signed [35:0] res_s;                 // res * S
    logic signed [45:0] ks_scaled;             // res * S * 960
    logic signed [43:0] u_full;
    logic signed [43:0] sv1, sv2, sv3, sv4;    // G * (stage input - state)
    logic signed [WB:0]   dp1, dp2, dp3, dp4;  // exact pole difference, 28 bits
    logic signed [WB-1:0] pd1, pd2, pd3, pd4;  // saturated to 27 bits for the DSP
    logic signed [WB-1:0] h1_c, h2_c, h3_c;
    logic signed [WB-1:0] s_c, ks_c, u_c;
    logic signed [WB-1:0] v1, v2, v3, v4;
    logic signed [WB-1:0] y1_c, y2_c, y3_c, y4_c;

    // Saturating clamp from 28 bits to the 27-bit multiplier operand (see the
    // header).  d[WB:WB-1] is 00/11 inside the clamp range, 01 above it and 10
    // below it, so this is two LUT bits of compare and no arithmetic carry
    // chain.
    function automatic logic signed [WB-1:0] sat_diff(input logic signed [WB:0] d);
        begin
            if (d[WB:WB-1] == 2'b01)      sat_diff = {1'b0, {(WB-1){1'b1}}};
            else if (d[WB:WB-1] == 2'b10) sat_diff = {1'b1, {(WB-1){1'b0}}};
            else                          sat_diff = d[WB-1:0];
        end
    endfunction

    assign x_full = {{11{audio_in[15]}}, audio_in} <<< FRAC;

    // stage 2: G^2
    assign g_sq  = coeff_dout * coeff_dout;
    assign g2_c  = g_sq[31:16];

    // stage 3: G^4 = (G^2)^2
    assign g2_sq = g2_r * g2_r;
    assign g4_c  = g2_sq[31:16];

    // stage 4: x = K G^4 in Q16 = (res G^4) * 960 >> 16
    // 960 = 1024 - 64: two shifts and a subtract, because res_g4 is 25 bits
    // and the 960 constant would make the other operand 34 bits wide, too
    // large for the 27x18 slice (it fell back to a LUT multiplier).
    assign res_g4   = res_q * g4_r;
    assign x_scaled = (res_g4 << 10) - (res_g4 << 6);
    assign x_c      = x_scaled[33:16];

    // stage 5: reciprocal index, and the first Horner step of S
    // 271 = 256 + 8 + 4 + 2 + 1, again a shift-add instead of a multiply whose
    // constant operand would be 27 bits wide.
    assign rid_mul = (x_r << 8) + (x_r << 3) + (x_r << 2) + (x_r << 1) + x_r;
    assign ridx_c  = (rid_mul[23:16] > 8'd255) ? 8'd255 : rid_mul[23:16];
    assign gw1     = $signed({1'b0, g_r}) * w1;
    assign h1_c    = w2 + (gw1 >>> 16);

    // stage 6: second Horner step
    assign gw2 = $signed({1'b0, g_r}) * h1_r;
    assign h2_c = w3 + (gw2 >>> 16);

    // stage 7: third Horner step; the reciprocal also lands on coeff_dout here
    assign gw3 = $signed({1'b0, g_r}) * h2_r;
    assign h3_c = w4 + (gw3 >>> 16);

    // stage 8: S = (1-G)(G^3 s1 + G^2 s2 + G s3 + s4)
    assign one_minus_g = 17'd65536 - {1'b0, g_r};
    assign osm = $signed({1'b0, one_minus_g}) * h3_r;
    assign s_c = osm >>> 16;

    // stage 9: K S
    // 960 = 1024 - 64 again; res_s is 36 bits, so the multiply was far outside
    // the slice and became a LUT array.
    assign res_s     = $signed({1'b0, res_q}) * s_r;
    assign ks_scaled = (res_s << 10) - (res_s << 6);
    assign ks_c      = ks_scaled >>> 16;

    // stage 10: u = (x - K S) / (1 + K G^4)
    assign u_full = $signed(x_q - ks_r) * $signed({1'b0, r_r});
    assign u_c    = u_full >>> 16;

    // stages 11..14: the four TPT one-poles.  Each 28-bit difference is
    // saturated to 27 bits so the product is one MULTALU27X18 slice, not a
    // two-slice MULT27X36 (see the header).
    assign dp1 = u_r - w1;
    assign pd1 = sat_diff(dp1);
    assign sv1 = $signed({1'b0, g_r}) * pd1;
    assign v1  = sv1 >>> 16;
    assign y1_c = w1 + v1;

    assign dp2 = y1_r - w2;
    assign pd2 = sat_diff(dp2);
    assign sv2 = $signed({1'b0, g_r}) * pd2;
    assign v2  = sv2 >>> 16;
    assign y2_c = w2 + v2;

    assign dp3 = y2_r - w3;
    assign pd3 = sat_diff(dp3);
    assign sv3 = $signed({1'b0, g_r}) * pd3;
    assign v3  = sv3 >>> 16;
    assign y3_c = w3 + v3;

    assign dp4 = y3_r - w4;
    assign pd4 = sat_diff(dp4);
    assign sv4 = $signed({1'b0, g_r}) * pd4;
    assign v4  = sv4 >>> 16;
    assign y4_c = w4 + v4;

    // -------------------------------------------------------------- saturator
    function automatic logic signed [15:0] sat16(input logic signed [WB-1:0] value);
        logic signed [WB-1:0] shifted;
        begin
            shifted = value >>> FRAC;
            if (shifted > 27'sd32767)      sat16 = 16'sh7fff;
            else if (shifted < -27'sd32768) sat16 = 16'sh8000;
            else                            sat16 = shifted[15:0];
        end
    endfunction

    // ------------------------------------------------------------- sequencing
    // No step counter is needed: the valid chain both advertises and gates every
    // stage, so the pipeline advances one sample at a time and cannot overlap the
    // next sample_ce as long as sample_ce is at least 15 clocks apart (48 kHz out
    // of 80 MHz gives 1667).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vap        <= 14'd0;
            coeff_addr <= 10'd0;
            w1         <= '0;
            w2         <= '0;
            w3         <= '0;
            w4         <= '0;
            nx1        <= '0;
            nx2        <= '0;
            nx3        <= '0;
            nx4        <= '0;
            x_q        <= '0;
            res_q      <= 8'd0;
            ci_q       <= 12'd0;
            sat_r      <= '0;
            audio_out  <= '0;
            out_valid  <= 1'b0;
        end else begin
            vap       <= {vap[12:0], sample_ce};
            out_valid <= sample_ce;

            // stage 0: consume the new sample, publish the previous result
            if (sample_ce) begin
                x_q        <= x_full;
                res_q      <= res;
                ci_q       <= (ci > CI_MAX) ? CI_MAX : ci;
                coeff_addr <= ci_q[9:0];   // ci_q is already clamped to CI_MAX
                w1         <= nx1;
                w2         <= nx2;
                w3         <= nx3;
                w4         <= nx4;
                audio_out  <= sat_r;
            end

            // stage 1 (vap[0]) is the coefficient read latency: the address was
            // written on the sample_ce edge, dout arrives one clock later.

            // stage 2: G arrives, G^2 is formed
            if (vap[1]) begin
                g_r  <= coeff_dout;
                g2_r <= g2_c;
            end

            // stage 3: G^4
            if (vap[2]) g4_r <= g4_c;

            // stage 4: x = K G^4 (Q16)
            if (vap[3]) x_r <= x_c;

            // stage 5: reciprocal address, first Horner step
            if (vap[4]) begin
                coeff_addr <= R_BASE + {2'b00, ridx_c};
                h1_r       <= h1_c;
            end

            // stage 6: second Horner step
            if (vap[5]) h2_r <= h2_c;

            // stage 7: third Horner step, and the reciprocal
            if (vap[6]) begin
                h3_r <= h3_c;
                r_r  <= coeff_dout;
            end

            // stage 8: S
            if (vap[7]) s_r <= s_c;

            // stage 9: K S
            if (vap[8]) ks_r <= ks_c;

            // stage 10: u
            if (vap[9]) u_r <= u_c;

            // stage 11: pole 1
            if (vap[10]) begin
                y1_r <= y1_c;
                nx1  <= w1 + v1 + v1;
            end

            // stage 12: pole 2
            if (vap[11]) begin
                y2_r <= y2_c;
                nx2  <= w2 + v2 + v2;
            end

            // stage 13: pole 3
            if (vap[12]) begin
                y3_r <= y3_c;
                nx3  <= w3 + v3 + v3;
            end

            // stage 14: pole 4, then the one and only saturation
            if (vap[13]) begin
                nx4   <= w4 + v4 + v4;
                sat_r <= sat16(y4_c);
            end
        end
    end

endmodule
