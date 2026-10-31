// Simple cursor: absolute mapping, no filter state machine.
//
// The previous timed filter carried a median network, an IIR, a rebase path, a
// rate limiter and three dividers.  In practice it made the published coordinate
// lag the hand, freeze on frames that skipped the engaged path, and drift from
// the sensor position.  This module replaces it with a direct per-frame map:
//
//   cursor = frame + 32768      (sensor is signed 16-bit, output is 0..65535)
//   gate   = engage below Z_ENGAGE, release above Z_RELEASE   (hysteresis)
//   depth  = proximity, Z_LOW..Z_HIGH mapped to 0..65535
//
// One frame in, one output update out.  No FIFO, no divider, no hidden state
// beyond the engage latch.  The complex version is kept at
// artifacts/v2_cursor_filter_timed.complex.sv.bak for reference.
module v2_cursor_filter_timed #(
  parameter integer Z_LOW     = 4000,
  parameter integer Z_HIGH    = 12000,
  parameter integer Z_ENGAGE  = 30000,
  parameter integer Z_RELEASE = 36000
) (
  input logic clk, input logic rst_n,
  input logic frame_in_valid,
  input logic signed [31:0] frame_x, frame_y, frame_z,
  input logic frame_valid, frame_saturated, frame_gap, frame_degraded,
  input logic [7:0] calibration_reason,
  input logic [15:0] frame_sequence,
  input logic [31:0] frame_timestamp,
  input logic left_edge,
  input logic sample_ce,
  output logic signed [31:0] cursor_x, cursor_y, cursor_z,
  output logic [15:0] normalized_pitch,
  output logic [15:0] velocity_control, depth_control,
  output logic [1:0] state,
  output logic [4:0] dbg_fsm_state,
  output logic point_valid, rebased, stable_valid,
  output logic signed [31:0] audio_cursor_x, audio_cursor_y, audio_cursor_z,
  output logic [15:0] audio_pitch, audio_velocity, audio_depth,
  output logic audio_valid,
  output logic [15:0] audio_sequence,
  output logic [31:0] audio_timestamp,
  output logic frame_output_valid
);
  localparam logic [1:0] STATE_DISENGAGED = 2'd0;
  localparam logic [1:0] STATE_ENGAGED    = 2'd1;

  logic engaged;
  logic signed [31:0] mapped_x, mapped_y;
  logic [15:0] clamped_x, clamped_y;
  logic [15:0] depth_now;

  // Absolute map with a learned neutral: the sensor's rest position is not zero,
  // so the first frame after reset becomes the origin.  Keep the sensing area
  // clear while the board boots, exactly like the PC's force-calibration step.
  logic have_neutral;
  logic signed [31:0] neutral_x, neutral_y;
  assign mapped_x = (frame_x - neutral_x) + 32'sd32768;
  assign mapped_y = (frame_y - neutral_y) + 32'sd32768;

  // The telemetry field is 16 bits: clamp instead of letting a value above 65535
  // wrap around to zero, which looked like the cursor jumping across the screen.
  always_comb begin
    if (mapped_x < 0) clamped_x = 16'd0;
    else if (mapped_x > 32'sd65535) clamped_x = 16'hffff;
    else clamped_x = mapped_x[15:0];
    if (mapped_y < 0) clamped_y = 16'd0;
    else if (mapped_y > 32'sd65535) clamped_y = 16'hffff;
    else clamped_y = mapped_y[15:0];
  end

  // Depth is proximity: closer (smaller Z) is stronger.  A shift keeps the
  // division out of the datapath; one LSB of depth per 4 units of Z.
  always_comb begin
    if (frame_z <= Z_LOW) depth_now = 16'd0;
    else if (frame_z >= Z_HIGH) depth_now = 16'hffff;
    else depth_now = (frame_z[15:0] - Z_LOW[15:0]) << 4;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cursor_x <= 32'sd32768; cursor_y <= 32'sd32768; cursor_z <= 32'sd0;
      normalized_pitch <= 16'd32768; velocity_control <= 16'd0; depth_control <= 16'd0;
      state <= STATE_DISENGAGED; dbg_fsm_state <= 5'd0;
      point_valid <= 1'b0; stable_valid <= 1'b0;
      audio_cursor_x <= 32'sd32768; audio_cursor_y <= 32'sd32768; audio_cursor_z <= 32'sd0;
      audio_pitch <= 16'd32768; audio_velocity <= 16'd0; audio_depth <= 16'd0;
      audio_valid <= 1'b0; audio_sequence <= 16'd0; audio_timestamp <= 32'd0;
      frame_output_valid <= 1'b0; engaged <= 1'b0;
      have_neutral <= 1'b0; neutral_x <= 32'sd0; neutral_y <= 32'sd0;
    end else begin
      frame_output_valid <= frame_in_valid;
      point_valid <= 1'b0;
      if (frame_in_valid) begin
        if (!have_neutral) begin
          neutral_x <= frame_x;
          neutral_y <= frame_y;
          have_neutral <= 1'b1;
        end
        // Engage hysteresis on proximity so the gate cannot chatter.
        if (frame_z <= Z_ENGAGE) engaged <= 1'b1;
        else if (frame_z >= Z_RELEASE) engaged <= 1'b0;

        cursor_x <= ({16'd0, clamped_x});
        cursor_y <= ({16'd0, clamped_y});
        cursor_z <= frame_z;
        normalized_pitch <= clamped_y;
        depth_control <= depth_now;
        velocity_control <= depth_now;
        state <= engaged ? STATE_ENGAGED : STATE_DISENGAGED;
        dbg_fsm_state <= {3'd0, engaged, frame_valid};
        point_valid <= frame_valid && (engaged || (frame_z <= Z_ENGAGE));
        stable_valid <= engaged;

        audio_cursor_x <= ({16'd0, clamped_x});
        audio_cursor_y <= ({16'd0, clamped_y});
        audio_cursor_z <= frame_z;
        audio_pitch <= clamped_y;
        audio_velocity <= depth_now;
        audio_depth <= depth_now;
        audio_valid <= engaged;
        audio_sequence <= frame_sequence;
        audio_timestamp <= frame_timestamp;
      end
    end
  end

  assign rebased = 1'b0;
endmodule
