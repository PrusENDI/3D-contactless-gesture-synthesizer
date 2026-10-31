// Linear crossfade between two 16-bit wavetable samples.
//
// out = a + ((b - a) * frac) >>> 8, arithmetic, truncating toward -inf.  frac=0
// returns a exactly; frac=255 lands at most 1 LSB below b.
module v2_wt_mix (
    input  logic signed [15:0] a,
    input  logic signed [15:0] b,
    input  logic        [7:0]  frac,
    output logic signed [15:0] out
);
    logic signed [16:0] diff;
    logic signed [24:0] prod;

    assign diff = $signed({b[15], b}) - $signed({a[15], a});
    assign prod = diff * $signed({1'b0, frac});
    assign out  = a + (prod >>> 8);
endmodule
