// Fixed-point V2 input calibration. Arithmetic is Q16.16 for coupling and gain.
module v2_input_calibration (
  input logic clk, input logic rst_n,
  input logic frame_in_valid,
  input logic signed [16:0] raw_x, raw_y, input logic [16:0] raw_z,
  input logic [15:0] sequence_id, input logic [31:0] timestamp_ticks,
  input logic valid_xyz, input logic saturated, input logic gap,
  input logic [7:0] calibration_epoch_in,
  input logic touch, input logic presence,
  input logic profile_shadow_we, input logic profile_commit,
  input logic signed [31:0] shadow_neutral_x, shadow_neutral_y, shadow_neutral_z,
  input logic signed [31:0] shadow_coupling_x, shadow_coupling_y,
  input logic signed [31:0] shadow_gain_x, shadow_gain_y, shadow_gain_z,
  input logic signed [31:0] shadow_ws_x_min, shadow_ws_x_max,
  input logic signed [31:0] shadow_ws_y_min, shadow_ws_y_max,
  input logic signed [31:0] shadow_ws_z_min, shadow_ws_z_max,
  input logic [7:0] shadow_epoch,
  output logic signed [31:0] calibrated_x, calibrated_y, calibrated_z,
  output logic [15:0] output_sequence, output logic [31:0] output_timestamp_ticks,
  output logic output_touch, output logic output_presence,
  output logic output_valid, output_saturated, output_gap,
  output logic [7:0] output_calibration_epoch,
  output logic [7:0] calibration_reason,
  output logic [7:0] active_epoch,
  output logic active_profile_valid,
  output logic frame_output_strobe,
  output logic signed [31:0] frame_calibrated_x, frame_calibrated_y, frame_calibrated_z,
  output logic [15:0] frame_output_sequence,
  output logic [31:0] frame_output_timestamp_ticks,
  output logic [7:0] frame_output_reason,
  output logic frame_output_valid
);
  import v2_input_pkg::*;
  localparam signed [31:0] ONE_Q16 = 32'sd65536;
  logic signed [31:0] n_x, n_y, n_z, c_x, c_y, g_x, g_y, g_z;
  logic signed [31:0] ws_x_min, ws_x_max, ws_y_min, ws_y_max, ws_z_min, ws_z_max;
  logic [7:0] epoch_active;
  logic signed [31:0] sn_x, sn_y, sn_z, sc_x, sc_y, sg_x, sg_y, sg_z;
  logic signed [31:0] sw_x_min, sw_x_max, sw_y_min, sw_y_max, sw_z_min, sw_z_max;
  logic [7:0] epoch_shadow;
  logic have_sequence;
  logic [15:0] previous_sequence;
  v2_input_pkg::v2_input_frame_t frame_contract;

  function automatic signed [63:0] round_q16(input signed [63:0] value);
    if (value >= 0) round_q16 = (value + 64'sd32768) >>> 16;
    else round_q16 = -(((-value) + 64'sd32768) >>> 16);
  endfunction
  function automatic signed [31:0] sat32(input signed [63:0] value);
    if (value > 64'sd2147483647) sat32 = 32'sh7fffffff;
    else if (value < -64'sd2147483648) sat32 = -32'sh80000000;
    else sat32 = value[31:0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n_x<=0; n_y<=0; n_z<=0; c_x<=0; c_y<=0; g_x<=ONE_Q16; g_y<=ONE_Q16; g_z<=ONE_Q16;
      ws_x_min<=-32'sd32768; ws_x_max<=32'sd32767; ws_y_min<=-32'sd32768; ws_y_max<=32'sd32767;
      ws_z_min<=0; ws_z_max<=32'sd65535; epoch_active<=0; active_profile_valid<=1'b0;
      sn_x<=0; sn_y<=0; sn_z<=0; sc_x<=0; sc_y<=0; sg_x<=ONE_Q16; sg_y<=ONE_Q16; sg_z<=ONE_Q16;
      sw_x_min<=-32'sd32768; sw_x_max<=32'sd32767; sw_y_min<=-32'sd32768; sw_y_max<=32'sd32767;
      sw_z_min<=0; sw_z_max<=32'sd65535; epoch_shadow<=0;
      have_sequence<=1'b0; previous_sequence<=16'd0;
      frame_output_strobe<=1'b0; frame_calibrated_x<=0; frame_calibrated_y<=0; frame_calibrated_z<=0;
      frame_output_sequence<=0; frame_output_timestamp_ticks<=0; frame_output_reason<=0; frame_output_valid<=1'b0;
    end else begin
      frame_output_strobe <= frame_in_valid;
      if (frame_in_valid) begin
        frame_calibrated_x <= calibrated_x; frame_calibrated_y <= calibrated_y; frame_calibrated_z <= calibrated_z;
        frame_output_sequence <= output_sequence; frame_output_timestamp_ticks <= output_timestamp_ticks;
        frame_output_reason <= calibration_reason; frame_output_valid <= output_valid;
      end
      if (profile_shadow_we) begin
        sn_x<=shadow_neutral_x; sn_y<=shadow_neutral_y; sn_z<=shadow_neutral_z; sc_x<=shadow_coupling_x; sc_y<=shadow_coupling_y;
        sg_x<=shadow_gain_x; sg_y<=shadow_gain_y; sg_z<=shadow_gain_z; sw_x_min<=shadow_ws_x_min; sw_x_max<=shadow_ws_x_max;
        sw_y_min<=shadow_ws_y_min; sw_y_max<=shadow_ws_y_max; sw_z_min<=shadow_ws_z_min; sw_z_max<=shadow_ws_z_max; epoch_shadow<=shadow_epoch;
      end
      if (frame_in_valid) begin
        previous_sequence <= sequence_id;
        have_sequence <= 1'b1;
      end
      // A write+commit in one cycle is rejected; shadow remains staged for a later atomic commit.
      if (profile_commit && !profile_shadow_we && (sw_x_min <= sw_x_max) && (sw_y_min <= sw_y_max) && (sw_z_min <= sw_z_max) &&
          (sg_x >= 0) && (sg_y >= 0) && (sg_z >= 0)) begin
        n_x<=sn_x; n_y<=sn_y; n_z<=sn_z; c_x<=sc_x; c_y<=sc_y; g_x<=sg_x; g_y<=sg_y; g_z<=sg_z;
        ws_x_min<=sw_x_min; ws_x_max<=sw_x_max; ws_y_min<=sw_y_min; ws_y_max<=sw_y_max; ws_z_min<=sw_z_min; ws_z_max<=sw_z_max;
        epoch_active<=epoch_shadow; active_profile_valid<=1'b1;
      end
      // Simultaneous shadow-write/commit or invalid profile leaves the active bank untouched.
    end
  end

  always_comb begin : transform
    logic signed [63:0] sx, sy, sz, dx, dy, dz, qx, qy, qz, gx, gy, gz;
    logic signed [31:0] cx, cy, cz;
    logic clamp_seen, arith_sat_seen, bad_input, sequence_gap_seen;
    frame_contract.frame_sequence = sequence_id;
    frame_contract.timestamp_ticks = timestamp_ticks;
    frame_contract.raw_x = raw_x; frame_contract.raw_y = raw_y; frame_contract.raw_z = raw_z;
    frame_contract.touch = touch; frame_contract.presence = presence;
    frame_contract.valid_xyz = valid_xyz; frame_contract.saturated = saturated; frame_contract.gap = gap;
    frame_contract.calibration_epoch = calibration_epoch_in;
    sequence_gap_seen = have_sequence && ((sequence_id - previous_sequence) > 16'd1);
    calibration_reason = 8'd0;
    if (!frame_contract.valid_xyz) calibration_reason |= V2_REASON_INVALID;
    if (frame_contract.saturated) calibration_reason |= V2_REASON_SATURATED;
    if (frame_contract.gap || sequence_gap_seen) calibration_reason |= V2_REASON_GAP;
    if ((frame_contract.calibration_epoch != 8'd0) && (frame_contract.calibration_epoch != epoch_active)) calibration_reason |= V2_REASON_EPOCH | V2_REASON_PROFILE;
    if (!active_profile_valid) calibration_reason |= V2_REASON_PROFILE;
    bad_input = !frame_in_valid || !frame_contract.valid_xyz || frame_contract.saturated || frame_contract.gap || sequence_gap_seen ||
                (((frame_contract.calibration_epoch != 8'd0) && (frame_contract.calibration_epoch != epoch_active)) || !active_profile_valid);
    calibrated_x = 32'sd0; calibrated_y = 32'sd0; calibrated_z = 32'sd0;
    output_valid = 1'b0; clamp_seen = 1'b0; arith_sat_seen = 1'b0;
    if (!bad_input) begin
      // Frozen order: sign extension -> neutral -> Z coupling -> gain -> clamp -> output.
      sx={{47{frame_contract.raw_x[16]}},frame_contract.raw_x};
      sy={{47{frame_contract.raw_y[16]}},frame_contract.raw_y};
      sz={{47{frame_contract.raw_z[16]}},frame_contract.raw_z};
      dx=sx-n_x; dy=sy-n_y; dz=sz-n_z;
      qx=dx-round_q16(c_x*dz); qy=dy-round_q16(c_y*dz); qz=dz;
      gx=round_q16(qx*g_x); gy=round_q16(qy*g_y); gz=round_q16(qz*g_z);
      if ((gx > 64'sd2147483647) || (gx < -64'sd2147483648) ||
          (gy > 64'sd2147483647) || (gy < -64'sd2147483648) ||
          (gz > 64'sd2147483647) || (gz < -64'sd2147483648)) arith_sat_seen = 1'b1;
      cx=sat32(gx); cy=sat32(gy); cz=sat32(gz);
      if(cx<ws_x_min) begin cx=ws_x_min; clamp_seen=1'b1; end else if(cx>ws_x_max) begin cx=ws_x_max; clamp_seen=1'b1; end
      if(cy<ws_y_min) begin cy=ws_y_min; clamp_seen=1'b1; end else if(cy>ws_y_max) begin cy=ws_y_max; clamp_seen=1'b1; end
      if(cz<ws_z_min) begin cz=ws_z_min; clamp_seen=1'b1; end else if(cz>ws_z_max) begin cz=ws_z_max; clamp_seen=1'b1; end
      calibrated_x=cx; calibrated_y=cy; calibrated_z=cz; output_valid=1'b1;
      if (arith_sat_seen) begin
        calibration_reason |= V2_REASON_ARITH_SAT;
        calibrated_x=32'sd0; calibrated_y=32'sd0; calibrated_z=32'sd0; output_valid=1'b0;
      end
      if (clamp_seen) calibration_reason |= V2_REASON_CLAMP;
    end
    output_sequence=frame_contract.frame_sequence; output_timestamp_ticks=frame_contract.timestamp_ticks;
    output_touch=frame_contract.touch; output_presence=frame_contract.presence;
    output_saturated=frame_contract.saturated; output_gap=frame_contract.gap || sequence_gap_seen; output_calibration_epoch=frame_contract.calibration_epoch;
    active_epoch=epoch_active;
  end
endmodule

