// Standard I2S transmitter for PCM5102A.
// 50 MHz input clock -> fractional BCK generator at 64*sample rate.
// Signed 16-bit samples are sign-extended to 24 bits and sent to both
// channels. Data changes on BCK falling edges and is sampled on rising edges.
module i2s_pcm5102a_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SAMPLE_HZ = 48_000,
    parameter integer ACC_WIDTH = 32
) (
    input  wire clk,
    input  wire rst,
    input  wire sample_valid,
    input  wire signed [15:0] sample_in,
    output reg  i2s_bck,
    output reg  i2s_lrck,
    output reg  i2s_din
);
    // The accumulator overflows once per BCK half-period.
    localparam [ACC_WIDTH-1:0] BCK_TOGGLE_INC =
        ((64'd128 * SAMPLE_HZ) << ACC_WIDTH) / CLK_HZ;
    reg [ACC_WIDTH-1:0] phase_acc;
    reg [5:0] bit_count;
    reg signed [15:0] sample_latched;
    reg signed [23:0] frame_sample;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase_acc <= 0;
            bit_count <= 0;
            sample_latched <= 0;
            frame_sample <= 0;
            i2s_bck <= 1'b0;
            i2s_lrck <= 1'b0;
            i2s_din <= 1'b0;
        end else begin
            if (sample_valid)
                sample_latched <= sample_in;

            if (phase_acc + BCK_TOGGLE_INC < phase_acc) begin
                phase_acc <= phase_acc + BCK_TOGGLE_INC;
                i2s_bck <= ~i2s_bck;

                // Update data on falling BCK edges. The first bit is put on
                // DIN before the following rising edge, as required by I2S.
                if (i2s_bck) begin
                    if (bit_count == 6'd63)
                        frame_sample <= {sample_latched, 8'b0};

                    if (bit_count < 6'd32)
                        i2s_lrck <= 1'b0;
                    else
                        i2s_lrck <= 1'b1;

                    case (bit_count)
                        6'd0:  i2s_din <= frame_sample[23];
                        6'd1:  i2s_din <= frame_sample[22];
                        6'd2:  i2s_din <= frame_sample[21];
                        6'd3:  i2s_din <= frame_sample[20];
                        6'd4:  i2s_din <= frame_sample[19];
                        6'd5:  i2s_din <= frame_sample[18];
                        6'd6:  i2s_din <= frame_sample[17];
                        6'd7:  i2s_din <= frame_sample[16];
                        6'd8:  i2s_din <= frame_sample[15];
                        6'd9:  i2s_din <= frame_sample[14];
                        6'd10: i2s_din <= frame_sample[13];
                        6'd11: i2s_din <= frame_sample[12];
                        6'd12: i2s_din <= frame_sample[11];
                        6'd13: i2s_din <= frame_sample[10];
                        6'd14: i2s_din <= frame_sample[9];
                        6'd15: i2s_din <= frame_sample[8];
                        6'd16: i2s_din <= frame_sample[7];
                        6'd17: i2s_din <= frame_sample[6];
                        6'd18: i2s_din <= frame_sample[5];
                        6'd19: i2s_din <= frame_sample[4];
                        6'd20: i2s_din <= frame_sample[3];
                        6'd21: i2s_din <= frame_sample[2];
                        6'd22: i2s_din <= frame_sample[1];
                        6'd23: i2s_din <= frame_sample[0];
                        6'd32: i2s_din <= frame_sample[23];
                        6'd33: i2s_din <= frame_sample[22];
                        6'd34: i2s_din <= frame_sample[21];
                        6'd35: i2s_din <= frame_sample[20];
                        6'd36: i2s_din <= frame_sample[19];
                        6'd37: i2s_din <= frame_sample[18];
                        6'd38: i2s_din <= frame_sample[17];
                        6'd39: i2s_din <= frame_sample[16];
                        6'd40: i2s_din <= frame_sample[15];
                        6'd41: i2s_din <= frame_sample[14];
                        6'd42: i2s_din <= frame_sample[13];
                        6'd43: i2s_din <= frame_sample[12];
                        6'd44: i2s_din <= frame_sample[11];
                        6'd45: i2s_din <= frame_sample[10];
                        6'd46: i2s_din <= frame_sample[9];
                        6'd47: i2s_din <= frame_sample[8];
                        6'd48: i2s_din <= frame_sample[7];
                        6'd49: i2s_din <= frame_sample[6];
                        6'd50: i2s_din <= frame_sample[5];
                        6'd51: i2s_din <= frame_sample[4];
                        6'd52: i2s_din <= frame_sample[3];
                        6'd53: i2s_din <= frame_sample[2];
                        6'd54: i2s_din <= frame_sample[1];
                        6'd55: i2s_din <= frame_sample[0];
                        default: i2s_din <= 1'b0;
                    endcase
                    if (bit_count == 6'd63)
                        bit_count <= 0;
                    else
                        bit_count <= bit_count + 1'b1;
                end
            end else begin
                phase_acc <= phase_acc + BCK_TOGGLE_INC;
            end
        end
    end
endmodule
