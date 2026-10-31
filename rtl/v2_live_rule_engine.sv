// Independent V2 LIVE rules.  This block emits only the frozen 96-bit event
// contract; it has no connection to the legacy PC EventTable path.
module v2_live_rule_engine #(
  parameter integer TRACK = 0,
  parameter integer NOTE_MIN = 24,
  parameter integer NOTE_MAX = 96,
  parameter integer X_EDGE = 2048,
  parameter integer HYSTERESIS = 1024,
  parameter integer MIN_EVENT_TICKS = 4,
  parameter integer GATE_TOUCH = 0,
  parameter integer PIPELINE_NOTE = 0
) (
  input  logic clk, input logic rst_n,
  input  logic frame_in_valid, input logic frame_valid,
  input  logic frame_degraded, input logic frame_gap, input logic rebased,
  input  logic left_edge,
  input  logic [15:0] x, input logic [15:0] y, input logic [15:0] z,
  input  logic touch, input logic bow, input logic [31:0] tick,
  input logic [7:0] velocity_in, input logic [15:0] brightness_in,
  input logic [15:0] gain_in,
  output logic event_valid, input logic event_ready,
  output logic [95:0] event_data,
  output logic [3:0] event_type, output logic [7:0] event_note,
  output logic [7:0] event_velocity,
  output logic [15:0] event_count,
  output logic [7:0] fault_code,
  output logic left_edge_armed, output logic gate_state,
  output logic active, output logic [7:0] active_note
);
  import v2_contract_pkg::*;

  logic [15:0] prev_x, prev_z;
  logic prev_valid, have_last_event;
  logic [31:0] last_event_tick;
  logic [15:0] event_seq;
  logic candidate_valid;
  logic [3:0] candidate_type;
  logic [7:0] candidate_note, candidate_velocity, candidate_flags;
  logic [15:0] candidate_timbre;
  logic candidate_due, bad_frame, gate_now, edge_cross;
  logic edge_pending, arm_now;
  logic note_change_ok;
  logic note_change_ok_q;
  logic eval_valid, eval_frame_valid, eval_frame_degraded, eval_frame_gap, eval_rebased;
  logic [15:0] eval_x, eval_y, eval_z;
  logic eval_touch, eval_bow, eval_left_edge;
  logic [31:0] eval_tick;
  logic [7:0] eval_velocity_in;
  logic [15:0] eval_brightness_in, eval_gain_in;
  logic [7:0] candidate_note_q;
  logic candidate_valid_q;
  logic [3:0] candidate_type_q;
  logic [7:0] candidate_note_emit_q, candidate_flags_q, candidate_velocity_q;
  logic [15:0] candidate_timbre_q;
  logic [31:0] candidate_tick_q;

  wire rule_frame_in_valid = PIPELINE_NOTE ? eval_valid : frame_in_valid;
  wire rule_frame_valid = PIPELINE_NOTE ? eval_frame_valid : frame_valid;
  wire rule_frame_degraded = PIPELINE_NOTE ? eval_frame_degraded : frame_degraded;
  wire rule_frame_gap = PIPELINE_NOTE ? eval_frame_gap : frame_gap;
  wire rule_rebased = PIPELINE_NOTE ? eval_rebased : rebased;
  wire [15:0] rule_x = PIPELINE_NOTE ? eval_x : x;
  wire [15:0] rule_y = PIPELINE_NOTE ? eval_y : y;
  wire [15:0] rule_z = PIPELINE_NOTE ? eval_z : z;
  wire rule_touch = PIPELINE_NOTE ? eval_touch : touch;
  wire rule_bow = PIPELINE_NOTE ? eval_bow : bow;
  wire rule_left_edge = PIPELINE_NOTE ? eval_left_edge : left_edge;
  wire [31:0] rule_tick = PIPELINE_NOTE ? eval_tick : tick;
  wire [7:0] rule_velocity_in = PIPELINE_NOTE ? eval_velocity_in : velocity_in;
  wire [15:0] rule_brightness_in = PIPELINE_NOTE ? eval_brightness_in : brightness_in;
  wire [15:0] rule_gain_in = PIPELINE_NOTE ? eval_gain_in : gain_in;
  wire emit_candidate_valid = PIPELINE_NOTE ? candidate_valid_q : candidate_valid;
  wire [3:0] emit_candidate_type = PIPELINE_NOTE ? candidate_type_q : candidate_type;
  wire [7:0] emit_candidate_note = PIPELINE_NOTE ? candidate_note_emit_q : candidate_note;
  wire [7:0] emit_candidate_flags = PIPELINE_NOTE ? candidate_flags_q : candidate_flags;
  wire [7:0] emit_candidate_velocity = PIPELINE_NOTE ? candidate_velocity_q : candidate_velocity;
  wire [15:0] emit_candidate_timbre = PIPELINE_NOTE ? candidate_timbre_q : candidate_timbre;
  wire [31:0] emit_candidate_tick = PIPELINE_NOTE ? candidate_tick_q : rule_tick;

  // Pitch mapping from the design note (docs/lead-mapping-report-2026-10-22.md):
  // hand height y in [11534, 54001] spans G3(55)..C5(72), one semitone every
  // 2498 counts, quantised to the A minor pentatonic {55,57,60,62,64,67,69,72}.
  // Only these eight notes exist in the voice engine note ROM.
  function automatic [7:0] map_note(input logic [15:0] value);
    begin
      if      (value < 16'd16530) map_note = 8'd55;   // G3
      else if (value < 16'd19028) map_note = 8'd57;   // A3
      else if (value < 16'd24024) map_note = 8'd60;   // C4
      else if (value < 16'd26522) map_note = 8'd62;   // D4
      else if (value < 16'd34016) map_note = 8'd64;   // E4
      else if (value < 16'd39012) map_note = 8'd67;   // G4
      else if (value < 16'd41510) map_note = 8'd69;   // A4
      else                        map_note = 8'd72;   // C5
    end
  endfunction
  function automatic [31:0] note_boundary(input logic [7:0] note);
    begin
      case (note)
      8'd55: note_boundary = 32'd16530;
      8'd57: note_boundary = 32'd19028;
      8'd60: note_boundary = 32'd24024;
      8'd62: note_boundary = 32'd26522;
      8'd64: note_boundary = 32'd34016;
      8'd67: note_boundary = 32'd39012;
      8'd69: note_boundary = 32'd41510;
      8'd72: note_boundary = 32'd65535;
      default: note_boundary = 32'd0;
      endcase
    end
  endfunction

  always_comb begin
    gate_now = GATE_TOUCH ? rule_touch : rule_bow;
    bad_frame = !rule_frame_valid || rule_frame_degraded || rule_frame_gap || rule_rebased;
    candidate_note = PIPELINE_NOTE ? candidate_note_q : map_note(rule_y);
    candidate_velocity = rule_velocity_in;
    candidate_timbre = rule_brightness_in;
    candidate_type = V2_EV_CONTROL;
    candidate_flags = V2_FLAG_Z | (rule_touch ? V2_FLAG_TOUCH : V2_FLAG_BOW);
    candidate_valid = 1'b0;
    candidate_due = !have_last_event || ((rule_tick - last_event_tick) >= MIN_EVENT_TICKS);
    edge_cross = prev_valid && (((prev_x <= X_EDGE) && (rule_x > X_EDGE)) ||
                                ((prev_x > X_EDGE) && (rule_x <= X_EDGE)));
    arm_now = left_edge_armed || (edge_pending && rule_x > X_EDGE && (!prev_valid || rule_x >= prev_x));
    note_change_ok = 1'b1;
    if (active && (candidate_note != active_note)) begin
      integer boundary;
      boundary = note_boundary(candidate_note > active_note ? active_note + 1'b1 : active_note);
      if (candidate_note > active_note) note_change_ok = (rule_y >= boundary + HYSTERESIS);
      else note_change_ok = (rule_y + HYSTERESIS <= boundary);
    end
    if (rule_frame_in_valid && !bad_frame) begin
      if (!active && arm_now && gate_now && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_NOTE_ON;
        candidate_flags = rule_touch ? V2_FLAG_TOUCH : V2_FLAG_BOW;
      end else if (active && !gate_now && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_NOTE_OFF;
        candidate_note=active_note; candidate_flags=0;
      end else if (active && gate_now && (candidate_note != active_note) && note_change_ok_q && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_REVOICE;
        candidate_flags = rule_touch ? V2_FLAG_TOUCH : V2_FLAG_BOW;
      end else if (active && gate_now && edge_cross && (candidate_note == active_note) && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_REVOICE;
        candidate_flags = (rule_touch ? V2_FLAG_TOUCH : V2_FLAG_BOW) | V2_FLAG_REBASED;
      end else if (prev_valid && (rule_z != prev_z)) begin
        // Depth is expression; pure Z never creates a note event.
        candidate_valid=1'b1; candidate_type=V2_EV_CONTROL;
      end
    end
  end

  always_comb begin
    event_type = event_data[94:91]; event_note = event_data[71:64];
    event_velocity = event_data[63:56];
  end

  always_ff @(posedge clk or negedge rst_n) begin : live_state
    logic [95:0] packed_event;
    if (!rst_n) begin
      event_valid<=0; event_data<=0; event_count<=0; fault_code<=0;
      left_edge_armed<=0; edge_pending<=0; gate_state<=0; active<=0; active_note<=0;
      prev_x<=0; prev_z<=0; prev_valid<=0; have_last_event<=0;
      last_event_tick<=0; event_seq<=0;
      eval_valid <= 1'b0; candidate_note_q <= 8'd0; note_change_ok_q <= 1'b0; candidate_valid_q <= 1'b0;
      candidate_type_q <= V2_EV_CONTROL; candidate_note_emit_q <= 8'd0;
      candidate_flags_q <= 8'd0; candidate_velocity_q <= 8'd0; candidate_timbre_q <= 16'd0;
      candidate_tick_q <= 32'd0;
    end else begin
      note_change_ok_q <= note_change_ok;
      if (PIPELINE_NOTE) begin
        eval_valid <= frame_in_valid;
        if (frame_in_valid) begin
          eval_frame_valid <= frame_valid; eval_frame_degraded <= frame_degraded;
          eval_frame_gap <= frame_gap; eval_rebased <= rebased;
          eval_x <= x; eval_y <= y; eval_z <= z; eval_touch <= touch; eval_bow <= bow;
          eval_left_edge <= left_edge; eval_tick <= tick; eval_velocity_in <= velocity_in;
          eval_brightness_in <= brightness_in; eval_gain_in <= gain_in;
          candidate_note_q <= map_note(y);
        end
        if (!(event_valid && !event_ready)) begin
          candidate_valid_q <= candidate_valid;
          candidate_type_q <= candidate_type;
          candidate_note_emit_q <= candidate_note;
          candidate_flags_q <= candidate_flags;
          candidate_velocity_q <= candidate_velocity;
          candidate_timbre_q <= candidate_timbre;
          candidate_tick_q <= rule_tick;
        end
      end
      if (event_valid && event_ready) event_valid <= 1'b0;
      if (!(event_valid && !event_ready)) gate_state <= gate_now;
      // A stalled output freezes the rule state.  This keeps the pending
      // event and its metadata stable until the ready handshake.
      if (rule_frame_in_valid && !bad_frame && !(event_valid && !event_ready)) begin
        // The edge sample only starts arming; a final rightward sample commits it.
        if (!left_edge_armed && !edge_pending && (rule_left_edge || rule_x <= X_EDGE)) begin
          if (!prev_valid || rule_x >= prev_x) edge_pending <= 1'b1;
          else fault_code <= V2_FAULT_REVERSE;
        end else if (!left_edge_armed && edge_pending) begin
          if (rule_x > X_EDGE && (!prev_valid || rule_x >= prev_x)) begin
            left_edge_armed <= 1'b1;
            edge_pending <= 1'b0;
          end else if (rule_x < prev_x) begin
            edge_pending <= 1'b0;
            fault_code <= V2_FAULT_REVERSE;
          end
        end
        prev_x <= rule_x; prev_z <= rule_z; prev_valid <= 1'b1;
      end else if (rule_frame_in_valid && bad_frame && !(event_valid && !event_ready)) begin
        fault_code <= V2_FAULT_INVALID;
      end
      if (emit_candidate_valid && !(event_valid && !event_ready)) begin
        packed_event = 96'd0;
        packed_event[94:91] = emit_candidate_type;
        packed_event[90:88] = TRACK[2:0];
         packed_event[87:80] = emit_candidate_tick[7:0];
        packed_event[79:72] = 8'd0;
        packed_event[71:64] = emit_candidate_note;
        packed_event[63:56] = emit_candidate_velocity;
        packed_event[55:40] = 16'd0;
        packed_event[39:24] = emit_candidate_timbre;
        packed_event[23:16] = emit_candidate_flags;
        packed_event[15:0] = event_seq;
        if (!event_valid || event_ready) begin
          event_data <= packed_event; event_valid <= 1'b1;
          event_count <= event_count + 1'b1; event_seq <= event_seq + 1'b1;
           have_last_event <= 1'b1; last_event_tick <= emit_candidate_tick;
           if (emit_candidate_type == V2_EV_NOTE_ON) begin active<=1'b1; active_note<=emit_candidate_note; end
           else if (emit_candidate_type == V2_EV_NOTE_OFF) active<=1'b0;
           else if (emit_candidate_type == V2_EV_REVOICE) begin active<=1'b1; active_note<=emit_candidate_note; end
        end
      end
    end
  end
endmodule
