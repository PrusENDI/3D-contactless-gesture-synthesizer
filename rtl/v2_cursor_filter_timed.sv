// Timing-closed V2 cursor filter.
//
// The original Task 4 reference filter intentionally computes one complete
// frame in one clock.  That is useful for bit-exact replay, but it infers a
// median network, several multipliers and three wide dividers in one path.
// V2 hardware accepts frames into a small FIFO and evaluates the same causal
// state machine over multiple 100 MHz cycles.  The divider is restoring and
// therefore has a bounded one-bit-per-cycle datapath.  No input frame clock
// or second audio clock is introduced.
module v2_cursor_divider_u32 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [31:0] dividend,
  input  logic [15:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] quotient
);
  logic [31:0] dividend_r;
  logic [31:0] quotient_r;
  logic [16:0] remainder_r;
  logic [15:0] divisor_r;
  logic [5:0]  bit_count;
  logic [16:0] remainder_shift;
  logic [31:0] quotient_shift;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy       <= 1'b0;
      done       <= 1'b0;
      quotient   <= 32'd0;
      dividend_r <= 32'd0;
      quotient_r <= 32'd0;
      remainder_r<= 17'd0;
      divisor_r  <= 16'd1;
      bit_count  <= 6'd0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        busy        <= 1'b1;
        dividend_r  <= dividend;
        quotient_r  <= 32'd0;
        remainder_r <= 17'd0;
        divisor_r   <= (divisor == 0) ? 16'd1 : divisor;
        bit_count   <= 6'd0;
      end else if (busy) begin
        remainder_shift = {remainder_r[15:0], dividend_r[31]};
        quotient_shift  = {quotient_r[30:0], 1'b0};
        dividend_r      <= {dividend_r[30:0], 1'b0};
        if (remainder_shift >= {1'b0, divisor_r}) begin
          remainder_r  <= remainder_shift - {1'b0, divisor_r};
          quotient_shift[0] = 1'b1;
        end else begin
          remainder_r  <= remainder_shift;
        end
        quotient_r <= quotient_shift;
        if (bit_count == 6'd31) begin
          busy     <= 1'b0;
          done     <= 1'b1;
          quotient <= quotient_shift;
        end else begin
          bit_count <= bit_count + 1'b1;
        end
      end
    end
  end
endmodule


module v2_cursor_filter_timed #(
  parameter integer ALPHA_LOW_Q16  = 7864,
  parameter integer ALPHA_HIGH_Q16 = 65536,
  parameter integer Z_LOW          = 4000,
  parameter integer Z_HIGH         = 24000,
  parameter integer Z_ENGAGE       = 30000,
  parameter integer Z_RELEASE      = 36000,
  parameter integer MAX_STEP_Q16   = 4096,
  parameter integer SETTLE_TICKS   = 2
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
  output logic point_valid, rebased, stable_valid,
  output logic signed [31:0] audio_cursor_x, audio_cursor_y, audio_cursor_z,
  output logic [15:0] audio_pitch, audio_velocity, audio_depth,
  output logic audio_valid,
  output logic [15:0] audio_sequence,
  output logic [31:0] audio_timestamp,
  output logic frame_output_valid
);
  import v2_input_pkg::*;

  localparam logic [1:0] STATE_DISENGAGED = 2'd0;
  localparam logic [1:0] STATE_ENGAGED    = 2'd1;
  localparam logic [1:0] STATE_REBASED    = 2'd2;
  localparam logic [1:0] STATE_DEGRADED   = 2'd3;
  localparam signed [31:0] Q16_ONE = 32'sd65536;
  localparam signed [31:0] LEFT_EDGE_Q16 = 32'sd2048;
  localparam integer FIFO_DEPTH = 8;

  function automatic signed [31:0] median5(
    input signed [31:0] a0, input signed [31:0] a1,
    input signed [31:0] a2, input signed [31:0] a3,
    input signed [31:0] a4, input integer count);
    reg signed [31:0] v [0:4];
    reg signed [31:0] t;
    integer i, j, n;
    begin
      v[0]=a0; v[1]=a1; v[2]=a2; v[3]=a3; v[4]=a4;
      n = (count < 1) ? 1 : ((count > 5) ? 5 : count);
      for (i=0; i<5; i=i+1)
        for (j=i+1; j<5; j=j+1)
          if ((i<n) && (j<n) && (v[j] < v[i])) begin
            t=v[i]; v[i]=v[j]; v[j]=t;
          end
      median5 = v[n/2];
    end
  endfunction

  function automatic signed [31:0] map_axis(input signed [31:0] value);
    begin
      if (value <= -32'sd32768) map_axis = 32'sd0;
      else if (value >= 32'sd32767) map_axis = Q16_ONE;
      else map_axis = value + 32'sd32768;
    end
  endfunction

  function automatic [15:0] q16_u16(input signed [31:0] value);
    begin
      if (value <= 0) q16_u16 = 16'd0;
      else if (value >= 32'sd65535) q16_u16 = 16'hffff;
      else q16_u16 = value[15:0];
    end
  endfunction

  function automatic signed [31:0] clamp_step(input signed [63:0] value);
    begin
      if (value > MAX_STEP_Q16) clamp_step = MAX_STEP_Q16;
      else if (value < -MAX_STEP_Q16) clamp_step = -MAX_STEP_Q16;
      else clamp_step = value[31:0];
    end
  endfunction

  logic signed [31:0] hist_x [0:4], hist_y [0:4], hist_z [0:4];
  logic [2:0] hist_count;
  logic signed [31:0] filt_x, filt_y, filt_z;
  logic signed [31:0] last_raw_x, last_raw_y;
  logic signed [31:0] previous_target_x, previous_target_y;
  logic signed [31:0] anchor_x, anchor_y;
  logic anchor_valid, engaged, have_frame;
  integer settle_remaining;
  logic [15:0] stable_sequence;
  logic [31:0] stable_timestamp;
  logic signed [31:0] stable_cursor_x, stable_cursor_y, stable_cursor_z;
  logic [15:0] stable_pitch, stable_velocity, stable_depth;

  logic signed [31:0] q_x [0:FIFO_DEPTH-1], q_y [0:FIFO_DEPTH-1], q_z [0:FIFO_DEPTH-1];
  logic q_valid [0:FIFO_DEPTH-1], q_saturated [0:FIFO_DEPTH-1], q_gap [0:FIFO_DEPTH-1];
  logic q_degraded [0:FIFO_DEPTH-1], q_left_edge [0:FIFO_DEPTH-1];
  logic [7:0] q_reason [0:FIFO_DEPTH-1];
  logic [15:0] q_sequence [0:FIFO_DEPTH-1];
  logic [31:0] q_timestamp [0:FIFO_DEPTH-1];
  logic [3:0] q_head, q_tail;
  logic [3:0] q_count;

  logic signed [31:0] in_x, in_y, in_z;
  logic in_valid, in_saturated, in_gap, in_degraded, in_left_edge;
  logic [7:0] in_reason;
  logic [15:0] in_sequence;
  logic [31:0] in_timestamp;
  logic signed [31:0] mx, my, mz, tx, ty;
  logic signed [31:0] alpha_mz, alpha_motion;
  logic signed [31:0] nx, ny, nz, depth_q;
  logic signed [31:0] dx_q, dy_q, dz_q;
  logic signed [63:0] product_q;
  logic signed [63:0] product_x, product_y, product_z;
  logic signed [31:0] step_x_q, step_y_q;
  logic signed [31:0] cursor_next_x, cursor_next_y;
  logic signed [31:0] proximity_q, speed_q, velocity_q;
  logic pure_z_q, was_hidden_q;

  logic div_start, div_busy, div_done;
  logic [31:0] div_dividend;
 // Unsigned shift-add forms for the two small constant multiplies.
 logic [31:0] depth_term, depth_x7, speed_x3;
  logic [15:0] div_divisor;
  logic [31:0] div_quotient;
  v2_cursor_divider_u32 u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start), .dividend(div_dividend),
    .divisor(div_divisor), .busy(div_busy), .done(div_done), .quotient(div_quotient)
  );

  typedef enum logic [5:0] {
    ST_IDLE, ST_CHECK, ST_MEDIAN, ST_MEDIAN_S0, ST_MEDIAN_S1,
    ST_MEDIAN_S2, ST_MEDIAN_S3, ST_MEDIAN_S4, ST_MEDIAN_FINISH,
    ST_MAP, ST_ALPHA_MZ, ST_WAIT_ALPHA_MZ,
    ST_IIR_PREP, ST_MUL_X, ST_MUL_Y, ST_MUL_Z, ST_MUL_Z_ONLY, ST_IIR_APPLY,
    ST_ALPHA_NZ, ST_WAIT_ALPHA_NZ, ST_DEPTH, ST_WAIT_DEPTH, ST_FILTER_COMMIT,
    ST_STATE, ST_MOTION_PREP, ST_MOTION_X, ST_MOTION_Y, ST_MOTION_APPLY,
    ST_MOTION_CLAMP,
    ST_OUTPUT, ST_DROP
  } state_t;
  state_t fsm_state;
  logic signed [31:0] sort_x [0:4], sort_y [0:4], sort_z [0:4];

  function automatic signed [31:0] alpha_from_ratio(input [31:0] ratio);
    reg signed [63:0] p;
    reg signed [31:0] answer;
    begin
      p = (ALPHA_HIGH_Q16 - ALPHA_LOW_Q16) * ratio;
      answer = ALPHA_HIGH_Q16 - (p >>> 16);
      if (answer < 0) alpha_from_ratio = 0;
      else if (answer > 65536) alpha_from_ratio = 65536;
      else alpha_from_ratio = answer;
    end
  endfunction

  task automatic load_direct;
    begin
      in_x <= frame_x; in_y <= frame_y; in_z <= frame_z;
      in_valid <= frame_valid; in_saturated <= frame_saturated; in_gap <= frame_gap;
      in_degraded <= frame_degraded; in_left_edge <= left_edge;
      in_reason <= calibration_reason; in_sequence <= frame_sequence; in_timestamp <= frame_timestamp;
    end
  endtask

  task automatic load_queue_head;
    begin
      in_x <= q_x[q_head]; in_y <= q_y[q_head]; in_z <= q_z[q_head];
      in_valid <= q_valid[q_head]; in_saturated <= q_saturated[q_head]; in_gap <= q_gap[q_head];
      in_degraded <= q_degraded[q_head]; in_left_edge <= q_left_edge[q_head];
      in_reason <= q_reason[q_head]; in_sequence <= q_sequence[q_head]; in_timestamp <= q_timestamp[q_head];
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin : timed_filter_proc
    reg bad;
    reg signed [31:0] sx, sy;
    reg signed [63:0] p;
    reg signed [31:0] next_x, next_y;
    if (!rst_n) begin
      fsm_state <= ST_IDLE;
      q_head <= 0; q_tail <= 0; q_count <= 0;
      hist_count <= 0; filt_x <= 0; filt_y <= 0; filt_z <= 0;
      hist_x[0] <= 0; hist_x[1] <= 0; hist_x[2] <= 0; hist_x[3] <= 0; hist_x[4] <= 0;
      hist_y[0] <= 0; hist_y[1] <= 0; hist_y[2] <= 0; hist_y[3] <= 0; hist_y[4] <= 0;
      hist_z[0] <= 0; hist_z[1] <= 0; hist_z[2] <= 0; hist_z[3] <= 0; hist_z[4] <= 0;
      last_raw_x <= 0; last_raw_y <= 0; previous_target_x <= 0; previous_target_y <= 0;
      anchor_x <= 0; anchor_y <= 0; anchor_valid <= 0; engaged <= 0; have_frame <= 0;
      settle_remaining <= 0;
      cursor_x <= 32768; cursor_y <= 32768; cursor_z <= 0;
      normalized_pitch <= 32768; velocity_control <= 0; depth_control <= 0;
      state <= STATE_DISENGAGED; point_valid <= 0; rebased <= 0; stable_valid <= 0;
      audio_cursor_x <= 0; audio_cursor_y <= 0; audio_cursor_z <= 0;
      audio_pitch <= 0; audio_velocity <= 0; audio_depth <= 0; audio_valid <= 0;
      audio_sequence <= 0; audio_timestamp <= 0; frame_output_valid <= 0;
      stable_sequence <= 0; stable_timestamp <= 0;
      stable_cursor_x <= 0; stable_cursor_y <= 0; stable_cursor_z <= 0;
      stable_pitch <= 0; stable_velocity <= 0; stable_depth <= 0;
      div_start <= 0; div_dividend <= 0; div_divisor <= 1;
      in_x <= 0; in_y <= 0; in_z <= 0; in_valid <= 0; in_saturated <= 0; in_gap <= 0;
      in_degraded <= 0; in_left_edge <= 0; in_reason <= 0; in_sequence <= 0; in_timestamp <= 0;
      mx <= 0; my <= 0; mz <= 0; tx <= 0; ty <= 0; alpha_mz <= 0; alpha_motion <= 0;
      nx <= 0; ny <= 0; nz <= 0; depth_q <= 0; dx_q <= 0; dy_q <= 0; dz_q <= 0;
      product_q <= 0; product_x <= 0; product_y <= 0; product_z <= 0;
      step_x_q <= 0; step_y_q <= 0; cursor_next_x <= 0; cursor_next_y <= 0;
      proximity_q <= 0; speed_q <= 0; velocity_q <= 0; pure_z_q <= 0; was_hidden_q <= 0;
    end else begin
      div_start <= 1'b0;
      point_valid <= 1'b0;
      rebased <= 1'b0;
      frame_output_valid <= 1'b0;

      // Reports normally arrive much slower than the 100 MHz system clock.
      // The FIFO keeps the two adjacent-frame replay case lossless and
      // provides bounded protection if the sensor bursts briefly.
      if (frame_in_valid && (fsm_state != ST_IDLE) && (q_count < FIFO_DEPTH)) begin
        q_x[q_tail] <= frame_x; q_y[q_tail] <= frame_y; q_z[q_tail] <= frame_z;
        q_valid[q_tail] <= frame_valid; q_saturated[q_tail] <= frame_saturated; q_gap[q_tail] <= frame_gap;
        q_degraded[q_tail] <= frame_degraded; q_left_edge[q_tail] <= left_edge;
        q_reason[q_tail] <= calibration_reason; q_sequence[q_tail] <= frame_sequence; q_timestamp[q_tail] <= frame_timestamp;
        q_tail <= (q_tail == FIFO_DEPTH-1) ? 0 : q_tail + 1'b1;
        q_count <= q_count + 1'b1;
      end

      if (sample_ce && stable_valid) begin
        audio_cursor_x <= stable_cursor_x; audio_cursor_y <= stable_cursor_y; audio_cursor_z <= stable_cursor_z;
        audio_pitch <= stable_pitch; audio_velocity <= stable_velocity; audio_depth <= stable_depth;
        audio_sequence <= stable_sequence; audio_timestamp <= stable_timestamp;
        audio_valid <= 1'b1;
        // The metadata is held in the stable registers when a point is
        // published.  It is intentionally not regenerated from sample_ce.
      end

      case (fsm_state)
        ST_IDLE: begin
          if (q_count != 0) begin
            load_queue_head();
            q_head <= (q_head == FIFO_DEPTH-1) ? 0 : q_head + 1'b1;
            q_count <= q_count - 1'b1;
            fsm_state <= ST_CHECK;
          end else if (frame_in_valid) begin
            load_direct();
            fsm_state <= ST_CHECK;
          end
        end

        ST_CHECK: begin
          bad = !in_valid || in_saturated || in_gap || in_degraded ||
                ((in_reason & (V2_REASON_INVALID|V2_REASON_SATURATED|V2_REASON_GAP|
                               V2_REASON_EPOCH|V2_REASON_PROFILE|V2_REASON_ARITH_SAT)) != 0);
          if (bad) begin
            state <= STATE_DEGRADED;
            point_valid <= 1'b0;
            frame_output_valid <= 1'b1;
            fsm_state <= ST_IDLE;
          end else begin
            fsm_state <= ST_MEDIAN;
          end
        end

        ST_MEDIAN: begin
          if (hist_count < 5) begin
            sort_x[0] <= in_x; sort_y[0] <= in_y; sort_z[0] <= in_z;
            sort_x[1] <= hist_x[0]; sort_y[1] <= hist_y[0]; sort_z[1] <= hist_z[0];
            sort_x[2] <= hist_x[1]; sort_y[2] <= hist_y[1]; sort_z[2] <= hist_z[1];
            sort_x[3] <= hist_x[2]; sort_y[3] <= hist_y[2]; sort_z[3] <= hist_z[2];
            sort_x[4] <= hist_x[3]; sort_y[4] <= hist_y[3]; sort_z[4] <= hist_z[3];
          end else begin
            sort_x[0] <= in_x; sort_y[0] <= in_y; sort_z[0] <= in_z;
            sort_x[1] <= hist_x[0]; sort_y[1] <= hist_y[0]; sort_z[1] <= hist_z[0];
            sort_x[2] <= hist_x[1]; sort_y[2] <= hist_y[1]; sort_z[2] <= hist_z[1];
            sort_x[3] <= hist_x[2]; sort_y[3] <= hist_y[2]; sort_z[3] <= hist_z[2];
            sort_x[4] <= hist_x[3]; sort_y[4] <= hist_y[3]; sort_z[4] <= hist_z[3];
          end
          fsm_state <= ST_MEDIAN_S0;
        end

        // Five odd-even transposition stages replace the deeply nested
        // function loop in the reference implementation.  Each state has at
        // most one compare/swap level between registers.
        ST_MEDIAN_S0: begin
          if (sort_x[0] > sort_x[1]) begin sort_x[0] <= sort_x[1]; sort_x[1] <= sort_x[0]; end
          if (sort_x[2] > sort_x[3]) begin sort_x[2] <= sort_x[3]; sort_x[3] <= sort_x[2]; end
          if (sort_y[0] > sort_y[1]) begin sort_y[0] <= sort_y[1]; sort_y[1] <= sort_y[0]; end
          if (sort_y[2] > sort_y[3]) begin sort_y[2] <= sort_y[3]; sort_y[3] <= sort_y[2]; end
          if (sort_z[0] > sort_z[1]) begin sort_z[0] <= sort_z[1]; sort_z[1] <= sort_z[0]; end
          if (sort_z[2] > sort_z[3]) begin sort_z[2] <= sort_z[3]; sort_z[3] <= sort_z[2]; end
          fsm_state <= ST_MEDIAN_S1;
        end
        ST_MEDIAN_S1: begin
          if (sort_x[1] > sort_x[2]) begin sort_x[1] <= sort_x[2]; sort_x[2] <= sort_x[1]; end
          if (sort_x[3] > sort_x[4]) begin sort_x[3] <= sort_x[4]; sort_x[4] <= sort_x[3]; end
          if (sort_y[1] > sort_y[2]) begin sort_y[1] <= sort_y[2]; sort_y[2] <= sort_y[1]; end
          if (sort_y[3] > sort_y[4]) begin sort_y[3] <= sort_y[4]; sort_y[4] <= sort_y[3]; end
          if (sort_z[1] > sort_z[2]) begin sort_z[1] <= sort_z[2]; sort_z[2] <= sort_z[1]; end
          if (sort_z[3] > sort_z[4]) begin sort_z[3] <= sort_z[4]; sort_z[4] <= sort_z[3]; end
          fsm_state <= ST_MEDIAN_S2;
        end
        ST_MEDIAN_S2: begin
          if (sort_x[0] > sort_x[1]) begin sort_x[0] <= sort_x[1]; sort_x[1] <= sort_x[0]; end
          if (sort_x[2] > sort_x[3]) begin sort_x[2] <= sort_x[3]; sort_x[3] <= sort_x[2]; end
          if (sort_y[0] > sort_y[1]) begin sort_y[0] <= sort_y[1]; sort_y[1] <= sort_y[0]; end
          if (sort_y[2] > sort_y[3]) begin sort_y[2] <= sort_y[3]; sort_y[3] <= sort_y[2]; end
          if (sort_z[0] > sort_z[1]) begin sort_z[0] <= sort_z[1]; sort_z[1] <= sort_z[0]; end
          if (sort_z[2] > sort_z[3]) begin sort_z[2] <= sort_z[3]; sort_z[3] <= sort_z[2]; end
          fsm_state <= ST_MEDIAN_S3;
        end
        ST_MEDIAN_S3: begin
          if (sort_x[1] > sort_x[2]) begin sort_x[1] <= sort_x[2]; sort_x[2] <= sort_x[1]; end
          if (sort_x[3] > sort_x[4]) begin sort_x[3] <= sort_x[4]; sort_x[4] <= sort_x[3]; end
          if (sort_y[1] > sort_y[2]) begin sort_y[1] <= sort_y[2]; sort_y[2] <= sort_y[1]; end
          if (sort_y[3] > sort_y[4]) begin sort_y[3] <= sort_y[4]; sort_y[4] <= sort_y[3]; end
          if (sort_z[1] > sort_z[2]) begin sort_z[1] <= sort_z[2]; sort_z[2] <= sort_z[1]; end
          if (sort_z[3] > sort_z[4]) begin sort_z[3] <= sort_z[4]; sort_z[4] <= sort_z[3]; end
          fsm_state <= ST_MEDIAN_S4;
        end
        ST_MEDIAN_S4: begin
          if (sort_x[0] > sort_x[1]) begin sort_x[0] <= sort_x[1]; sort_x[1] <= sort_x[0]; end
          if (sort_x[2] > sort_x[3]) begin sort_x[2] <= sort_x[3]; sort_x[3] <= sort_x[2]; end
          if (sort_y[0] > sort_y[1]) begin sort_y[0] <= sort_y[1]; sort_y[1] <= sort_y[0]; end
          if (sort_y[2] > sort_y[3]) begin sort_y[2] <= sort_y[3]; sort_y[3] <= sort_y[2]; end
          if (sort_z[0] > sort_z[1]) begin sort_z[0] <= sort_z[1]; sort_z[1] <= sort_z[0]; end
          if (sort_z[2] > sort_z[3]) begin sort_z[2] <= sort_z[3]; sort_z[3] <= sort_z[2]; end
          fsm_state <= ST_MEDIAN_FINISH;
        end
        ST_MEDIAN_FINISH: begin
          mx <= sort_x[2]; my <= sort_y[2]; mz <= sort_z[2];
          fsm_state <= ST_MAP;
        end

        ST_MAP: begin
          tx <= map_axis(mx);
          ty <= map_axis(my);
          fsm_state <= ST_ALPHA_MZ;
        end

        ST_ALPHA_MZ: begin
          if (mz <= Z_LOW) begin alpha_mz <= ALPHA_HIGH_Q16; fsm_state <= ST_IIR_PREP; end
          else if (mz >= Z_HIGH) begin alpha_mz <= ALPHA_LOW_Q16; fsm_state <= ST_IIR_PREP; end
          else begin
            div_dividend <= (mz - Z_LOW) << 16;
            div_divisor <= Z_HIGH - Z_LOW;
            div_start <= 1'b1;
            fsm_state <= ST_WAIT_ALPHA_MZ;
          end
        end

        ST_WAIT_ALPHA_MZ: begin
          if (div_done) begin alpha_mz <= alpha_from_ratio(div_quotient); fsm_state <= ST_IIR_PREP; end
        end

        ST_IIR_PREP: begin
          pure_z_q <= (hist_count != 0) && (in_x == last_raw_x) && (in_y == last_raw_y);
          if (hist_count == 0) begin
            nx <= tx; ny <= ty; nz <= mz; fsm_state <= ST_ALPHA_NZ;
          end else if ((in_x == last_raw_x) && (in_y == last_raw_y)) begin
            dx_q <= 0; dy_q <= 0; dz_q <= mz - filt_z; fsm_state <= ST_MUL_Z_ONLY;
          end else begin
            dx_q <= tx - filt_x; dy_q <= ty - filt_y; dz_q <= mz - filt_z; fsm_state <= ST_MUL_X;
          end
        end

        ST_MUL_X: begin product_x <= $signed(dx_q) * $signed(alpha_mz); fsm_state <= ST_MUL_Y; end
        ST_MUL_Y: begin product_y <= $signed(dy_q) * $signed(alpha_mz); fsm_state <= ST_MUL_Z; end
        ST_MUL_Z: begin product_z <= $signed(dz_q) * $signed(alpha_mz); fsm_state <= ST_IIR_APPLY; end
        ST_MUL_Z_ONLY: begin product_z <= $signed(dz_q) * $signed(alpha_mz); fsm_state <= ST_IIR_APPLY; end

        ST_IIR_APPLY: begin
          if (hist_count == 0) begin
            // Values were already registered in ST_IIR_PREP.
          end else if (pure_z_q) begin
            nx <= filt_x; ny <= filt_y; nz <= filt_z + (product_z >>> 16);
          end else begin
            nx <= filt_x + (product_x >>> 16);
            ny <= filt_y + (product_y >>> 16);
            nz <= filt_z + (product_z >>> 16);
          end
          fsm_state <= ST_ALPHA_NZ;
        end

        ST_ALPHA_NZ: begin
          if (nz <= Z_LOW) begin alpha_motion <= ALPHA_HIGH_Q16; fsm_state <= ST_DEPTH; end
          else if (nz >= Z_HIGH) begin alpha_motion <= ALPHA_LOW_Q16; fsm_state <= ST_DEPTH; end
          else begin
            div_dividend <= (nz - Z_LOW) << 16;
            div_divisor <= Z_HIGH - Z_LOW;
            div_start <= 1'b1;
            fsm_state <= ST_WAIT_ALPHA_NZ;
          end
        end

        ST_WAIT_ALPHA_NZ: begin
          if (div_done) begin alpha_motion <= alpha_from_ratio(div_quotient); fsm_state <= ST_DEPTH; end
        end

        ST_DEPTH: begin
          if (nz <= Z_LOW) begin depth_q <= 0; fsm_state <= ST_FILTER_COMMIT; end
          else if (nz >= Z_HIGH) begin depth_q <= Q16_ONE; fsm_state <= ST_FILTER_COMMIT; end
          else begin
            div_dividend <= (nz - Z_LOW) << 16;
            div_divisor <= Z_HIGH - Z_LOW;
            div_start <= 1'b1;
            fsm_state <= ST_WAIT_DEPTH;
          end
        end

        ST_WAIT_DEPTH: begin
          if (div_done) begin
            if (div_quotient > 32'd65536) depth_q <= Q16_ONE;
            else depth_q <= div_quotient;
            fsm_state <= ST_FILTER_COMMIT;
          end
        end

        ST_FILTER_COMMIT: begin
          // Commit the causal filter state only after all arithmetic for this
          // frame has completed.  This is the same state ordering as the
          // single-cycle reference implementation.
          filt_x <= nx; filt_y <= ny; filt_z <= nz; last_raw_x <= in_x; last_raw_y <= in_y; cursor_z <= nz;
          if (hist_count < 5) hist_count <= hist_count + 1'b1;
          hist_x[0] <= in_x; hist_y[0] <= in_y; hist_z[0] <= in_z;
          if (hist_count >= 1) begin hist_x[1] <= hist_x[0]; hist_y[1] <= hist_y[0]; hist_z[1] <= hist_z[0]; end
          if (hist_count >= 2) begin hist_x[2] <= hist_x[1]; hist_y[2] <= hist_y[1]; hist_z[2] <= hist_z[1]; end
          if (hist_count >= 3) begin hist_x[3] <= hist_x[2]; hist_y[3] <= hist_y[2]; hist_z[3] <= hist_z[2]; end
          if (hist_count >= 4) begin hist_x[4] <= hist_x[3]; hist_y[4] <= hist_y[3]; hist_z[4] <= hist_z[3]; end
          proximity_q <= Q16_ONE - depth_q;
          depth_term = Q16_ONE - depth_q;
          depth_x7 = (depth_term << 3) - depth_term;
          velocity_q <= 32'sd32768 + (depth_x7 >> 4);
          depth_control <= q16_u16(depth_q);
          fsm_state <= ST_STATE;
        end

        ST_STATE: begin
          was_hidden_q <= have_frame && !anchor_valid;
          if (engaged && (in_z > Z_RELEASE)) begin
            engaged <= 1'b0; anchor_valid <= 1'b0; state <= STATE_DISENGAGED;
            point_valid <= 1'b0; frame_output_valid <= 1'b1; have_frame <= 1'b1; fsm_state <= ST_IDLE;
          end else if (!engaged && (in_z < Z_ENGAGE) &&
                       ((have_frame && !anchor_valid) || in_left_edge || (tx <= LEFT_EDGE_Q16))) begin
            engaged <= 1'b1; anchor_valid <= 1'b1; anchor_x <= nx; anchor_y <= ny;
            previous_target_x <= nx; previous_target_y <= ny; settle_remaining <= SETTLE_TICKS;
            state <= (have_frame && !anchor_valid) ? STATE_REBASED : STATE_ENGAGED;
            rebased <= (have_frame && !anchor_valid); point_valid <= 1'b1;
            if (have_frame && !anchor_valid) stable_valid <= 1'b0;
            velocity_control <= q16_u16(velocity_q);
            have_frame <= 1'b1; frame_output_valid <= 1'b1; fsm_state <= ST_IDLE;
          end else if (engaged) begin
            dx_q <= nx - previous_target_x; dy_q <= ny - previous_target_y;
            fsm_state <= ST_MOTION_PREP;
          end else begin
            state <= STATE_DISENGAGED; point_valid <= 1'b0; velocity_control <= q16_u16(velocity_q);
            have_frame <= 1'b1; frame_output_valid <= 1'b1; fsm_state <= ST_IDLE;
          end
        end

        ST_MOTION_PREP: begin
          product_x <= $signed(dx_q) * $signed(alpha_motion);
          fsm_state <= ST_MOTION_Y;
        end

        ST_MOTION_Y: begin
          product_y <= $signed(dy_q) * $signed(alpha_motion);
          fsm_state <= ST_MOTION_APPLY;
        end

        ST_MOTION_APPLY: begin
          sx = product_x >>> 16; sy = product_y >>> 16;
          if (settle_remaining > 0) begin sx = 0; sy = 0; settle_remaining <= settle_remaining - 1; end
          step_x_q <= clamp_step(sx); step_y_q <= clamp_step(sy);
          fsm_state <= ST_MOTION_CLAMP;
        end

        ST_MOTION_CLAMP: begin
          next_x = cursor_x + step_x_q; next_y = cursor_y + step_y_q;
          if (next_x < 0) next_x = 0; else if (next_x > Q16_ONE) next_x = Q16_ONE;
          if (next_y < 0) next_y = 0; else if (next_y > Q16_ONE) next_y = Q16_ONE;
          cursor_next_x <= next_x; cursor_next_y <= next_y;
          fsm_state <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
          cursor_x <= cursor_next_x; cursor_y <= cursor_next_y; normalized_pitch <= q16_u16(cursor_next_y);
          previous_target_x <= nx; previous_target_y <= ny; point_valid <= 1'b1; stable_valid <= 1'b1;
          speed_q <= ((step_x_q < 0) ? -step_x_q : step_x_q);
          if ((step_y_q < 0) && (-step_y_q > ((step_x_q < 0) ? -step_x_q : step_x_q))) speed_q <= -step_y_q;
          else if (step_y_q > ((step_x_q < 0) ? -step_x_q : step_x_q)) speed_q <= step_y_q;
          speed_x3 = (speed_q[31:0] << 1) + speed_q[31:0];
          velocity_control <= q16_u16(velocity_q + (speed_x3 >> 4));
          stable_cursor_x <= cursor_next_x; stable_cursor_y <= cursor_next_y; stable_cursor_z <= nz;
          stable_pitch <= q16_u16(cursor_next_y); stable_velocity <= q16_u16(velocity_q + (speed_x3 >> 4));
          stable_depth <= q16_u16(depth_q); stable_sequence <= in_sequence; stable_timestamp <= in_timestamp;
          state <= in_degraded ? STATE_DEGRADED : STATE_ENGAGED;
          have_frame <= 1'b1; frame_output_valid <= 1'b1; fsm_state <= ST_IDLE;
        end

        default: fsm_state <= ST_IDLE;
      endcase
    end
  end
endmodule
