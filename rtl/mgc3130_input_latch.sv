// V1-compatible report latch plus V2 raw-frame boundary.
// X/Y are centered signed17 (unsigned sensor count minus 32768); Z is unsigned17.
module mgc3130_input_latch (
    input wire clk, input wire rst_n,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire [15:0] x_position, input wire [15:0] y_position,
    input wire [15:0] z_position, input wire [7:0] gesture_code,
    output reg input_valid, output reg xyz_valid_latched,
    output reg [15:0] x_latched, output reg [15:0] y_latched,
    output reg [15:0] z_latched, output reg [7:0] gesture_latched,
    input wire [31:0] touch_info, input wire touch_valid,
    output reg report_valid_latched, output reg report_error_latched,
    output reg touch_valid_latched, output reg [31:0] touch_info_latched,
    output reg [15:0] v2_sequence, output reg [31:0] v2_timestamp_ticks,
    output reg signed [16:0] v2_raw_x, output reg signed [16:0] v2_raw_y,
    output reg [16:0] v2_raw_z, output reg v2_frame_valid,
    output reg v2_gap, output reg v2_saturated, output reg [7:0] v2_calibration_epoch,
    output reg v2_touch, output reg v2_presence,
    output reg v2_xyz_valid, output reg v2_report_error,
    output reg v2_touch_field_valid, output reg [31:0] v2_touch_info,
    // V2-only metadata.  Legacy positional/named callers may omit these
    // trailing ports; omitted controls take the generated counter/default 0.
    input wire v2_saturated_in, input wire v2_sequence_valid,
    input wire [15:0] v2_sequence_in
);
    reg [15:0] sequence_counter;
    reg [31:0] free_timestamp_ticks;
    // GestIC TouchInfo low five bits are S/W/N/E/center electrode state.
    wire [4:0] decoded_electrodes;
    wire decoded_touch;
    v2_touch_info_decoder u_touch_decoder(.field_valid(touch_valid && !report_error), .touch_info(touch_info), .electrode_mask(decoded_electrodes), .touch_state(decoded_touch));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_valid<=0; xyz_valid_latched<=0; x_latched<=0; y_latched<=0; z_latched<=0; gesture_latched<=0;
            report_valid_latched<=0; report_error_latched<=0; touch_valid_latched<=0; touch_info_latched<=0;
            sequence_counter<=0; free_timestamp_ticks<=0; v2_sequence<=0; v2_timestamp_ticks<=0;
            v2_raw_x<=0; v2_raw_y<=0; v2_raw_z<=0; v2_frame_valid<=0; v2_gap<=0; v2_saturated<=0;
            v2_calibration_epoch<=0; v2_touch<=0; v2_presence<=0; v2_xyz_valid<=0; v2_report_error<=0;
            v2_touch_field_valid<=0; v2_touch_info<=0;
        end else begin
            free_timestamp_ticks <= free_timestamp_ticks + 1'b1;
            input_valid<=0; xyz_valid_latched<=0;
            report_valid_latched<=report_valid; report_error_latched<=report_valid && report_error;
            touch_valid_latched<=0;
            v2_frame_valid<=0; v2_gap<=0; v2_saturated<=0; v2_touch<=0; v2_presence<=0;
            v2_xyz_valid<=0; v2_report_error<=0; v2_touch_field_valid<=0; v2_touch_info<=0;
            // v2_frame_valid is a transport strobe: every report, including invalid/error, is emitted.
            if (report_valid) begin
                if (v2_sequence_valid) begin
                    sequence_counter <= v2_sequence_in + 1'b1;
                    v2_sequence <= v2_sequence_in;
                end else begin
                    sequence_counter <= sequence_counter + 1'b1;
                    v2_sequence <= sequence_counter;
                end
                v2_timestamp_ticks <= free_timestamp_ticks;
                v2_raw_x <= $signed({1'b0,x_position}) - 17'sd32768;
                v2_raw_y <= $signed({1'b0,y_position}) - 17'sd32768;
                v2_raw_z <= {1'b0,z_position};
                v2_frame_valid <= 1'b1;
                v2_gap <= report_error;
                // Keep XYZ validity independent from the transport gap/error
                // flag.  The V2 consumer reports GAP separately; a frame can
                // carry valid coordinates while still being degraded by a
                // missing sequence.
                v2_xyz_valid <= xyz_valid;
                v2_report_error <= report_error;
                v2_presence <= xyz_valid;
                v2_touch_field_valid <= touch_valid && !report_error;
                v2_touch_info <= (touch_valid && !report_error) ? touch_info : 32'd0;
                v2_touch <= decoded_touch;
                // Sensor saturation is an explicit input policy; endpoint values are valid coordinates.
                case (v2_saturated_in)
                    1'b1: v2_saturated <= 1'b1;
                    default: v2_saturated <= 1'b0;
                endcase
                touch_valid_latched <= touch_valid && !report_error;
                // A report without a valid TouchInfo field publishes zero;
                // between reports the previous field remains available.
                touch_info_latched <= (touch_valid && !report_error) ? touch_info : 32'd0;
            end
            if (report_valid && xyz_valid && !report_error) begin
                x_latched<=x_position; y_latched<=y_position; z_latched<=z_position; gesture_latched<=gesture_code;
                input_valid<=1'b1; xyz_valid_latched<=1'b1;
            end
        end
    end
endmodule
