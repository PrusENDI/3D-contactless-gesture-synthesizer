module v2_position_validity (
  input logic clk, input logic rst_n,
  input logic frame_in_valid,
  input logic valid_xyz, input logic saturated, input logic gap,
  input logic [15:0] sequence_id,
  input logic [7:0] calibration_epoch, input logic [7:0] active_epoch,
  input logic active_profile_valid,
  input logic [7:0] calibration_reason_in,
  output logic frame_valid, output logic lost, output logic degraded,
  output logic [15:0] gap_count, output logic [7:0] calibration_reason,
  output logic note_permitted
);
  import v2_input_pkg::*;
  logic have_sequence;
  logic [15:0] previous_sequence;
  always_ff @(posedge clk or negedge rst_n) begin : quality
    logic [15:0] delta;
    logic [16:0] missing;
    logic [15:0] next_gap_count;
    logic [7:0] reason;
    if (!rst_n) begin
      have_sequence<=1'b0; previous_sequence<=16'd0; gap_count<=16'd0;
      frame_valid<=1'b0; lost<=1'b0; degraded<=1'b0; calibration_reason<=8'd0; note_permitted<=1'b0;
    end else begin
      frame_valid<=1'b0; lost<=1'b0; degraded<=1'b0; note_permitted<=1'b0; calibration_reason<=8'd0;
      if (frame_in_valid) begin
        delta = sequence_id - previous_sequence;
        next_gap_count = gap_count;
        reason = calibration_reason_in;
        if (have_sequence && delta > 16'd1) begin
          reason = reason | V2_REASON_GAP;
          missing = delta - 17'd1;
          if ({1'b0,gap_count} + missing > 17'h0ffff) next_gap_count = 16'hffff;
          else next_gap_count = gap_count + missing[15:0];
        end else if (gap && (!have_sequence || delta <= 16'd1)) begin
          reason = reason | V2_REASON_GAP;
          if (gap_count != 16'hffff) next_gap_count = gap_count + 16'd1;
        end
        if (!valid_xyz) reason = reason | V2_REASON_INVALID;
        if (saturated) reason = reason | V2_REASON_SATURATED;
        if ((calibration_epoch != 8'd0) && (calibration_epoch != active_epoch)) reason = reason | V2_REASON_EPOCH | V2_REASON_PROFILE;
        if (!active_profile_valid) reason = reason | V2_REASON_PROFILE;
        calibration_reason<=reason; gap_count<=next_gap_count;
        lost<=|(reason & V2_REASON_GAP);
        degraded<=|(reason & (V2_REASON_GAP|V2_REASON_EPOCH|V2_REASON_CLAMP|V2_REASON_PROFILE|V2_REASON_ARITH_SAT));
        frame_valid<=!(|(reason & (V2_REASON_INVALID|V2_REASON_SATURATED|V2_REASON_GAP|V2_REASON_EPOCH|V2_REASON_PROFILE|V2_REASON_ARITH_SAT)));
        note_permitted<=!(|(reason & (V2_REASON_INVALID|V2_REASON_SATURATED|V2_REASON_GAP|V2_REASON_EPOCH|V2_REASON_PROFILE|V2_REASON_ARITH_SAT)));
        previous_sequence<=sequence_id; have_sequence<=1'b1;
      end
    end
  end
endmodule
