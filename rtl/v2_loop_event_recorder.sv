// V2 six-track event recorder.  Its local replay store and the downstream
// write holding register use the same 32-slot/track contract as the V2 store.
module v2_loop_event_recorder /* synthesis syn_noprune=1 */ #(
  parameter integer TRACKS = 6,
  parameter integer DEPTH = 32,
  parameter integer SLOT_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter integer COUNT_BITS = $clog2(DEPTH+1)
) (
  input logic clk, input logic rst_n,
  input logic record_start, input logic record_stop, input logic abort,
  input logic event_valid, output logic event_ready,
  input logic [95:0] event_data,
  input logic [31:0] event_tick,
  input logic write_ready,
  output logic loop_write_valid, output logic [95:0] loop_write_data,
  input logic read_req, input logic [2:0] read_track, input logic [SLOT_BITS-1:0] read_index,
  output logic read_valid, output logic [95:0] read_data,
  output logic [15:0] event_count,
  output logic [COUNT_BITS-1:0] track_event_count [0:TRACKS-1],
  output logic [7:0] fault_code,
  output logic left_edge_armed, output logic gate_state,
  output logic recording
);
  import v2_contract_pkg::*;
  logic [95:0] mem [0:TRACKS-1][0:DEPTH-1];
  logic [SLOT_BITS:0] wr_ptr [0:TRACKS-1];
  logic [31:0] last_tick;
  logic have_tick;
  integer i;
  wire [2:0] input_track = event_data[90:88];
  wire [7:0] input_flags = event_data[23:16];
  wire bad_track = (input_track >= TRACKS);
  wire monotonic = !have_tick || (event_tick >= last_tick);

  // One-entry output holding register: input and downstream write handshakes
  // remain independent, and the output remains stable while write_ready=0.
  assign event_ready = recording && !loop_write_valid && !bad_track && monotonic &&
                       (wr_ptr[input_track] < DEPTH) && (fault_code == 0);

  always_ff @(posedge clk or negedge rst_n) begin : recorder_state
    if (!rst_n) begin
      recording<=0; event_count<=0; fault_code<=0; left_edge_armed<=0;
      gate_state<=0; last_tick<=0; have_tick<=0; loop_write_valid<=0;
      loop_write_data<=0; read_valid<=0; read_data<=0;
      for (i=0;i<TRACKS;i=i+1) begin wr_ptr[i]<=0; track_event_count[i]<=0; end
    end else begin
      if (loop_write_valid && write_ready) loop_write_valid <= 1'b0;
      read_valid <= 1'b0;
      if (record_start) begin
        recording<=1'b1; event_count<=0; fault_code<=0; have_tick<=0;
        left_edge_armed<=0; gate_state<=0;
        for (i=0;i<TRACKS;i=i+1) begin wr_ptr[i]<=0; track_event_count[i]<=0; end
      end
      if (record_stop) recording<=1'b0;
      if (abort) begin recording<=1'b0; fault_code<=V2_FAULT_ABORT; end
      if (event_valid && recording && !bad_track && !monotonic)
        fault_code<=V2_FAULT_TICK;
      else if (event_valid && recording && !bad_track && (wr_ptr[input_track] >= DEPTH))
        fault_code<=V2_FAULT_OVERFLOW;
      if (event_valid && event_ready) begin
        mem[input_track][wr_ptr[input_track][SLOT_BITS-1:0]] <= event_data;
        wr_ptr[input_track] <= wr_ptr[input_track] + 1'b1;
        track_event_count[input_track] <= track_event_count[input_track] + 1'b1;
        event_count <= event_count + 1'b1;
        last_tick <= event_tick; have_tick<=1'b1;
        left_edge_armed <= 1'b1;
        gate_state <= |(input_flags & 8'h03);
        loop_write_valid<=1'b1; loop_write_data<=event_data;
      end
      if (read_req && (read_track < TRACKS) && (read_index < DEPTH) &&
          (read_index < wr_ptr[read_track])) begin
        read_valid<=1'b1; read_data<=mem[read_track][read_index];
      end
    end
  end
endmodule
