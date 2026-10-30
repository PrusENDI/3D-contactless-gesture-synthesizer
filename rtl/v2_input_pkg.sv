package v2_input_pkg;
  typedef struct packed {
    logic [15:0] frame_sequence;
    logic [31:0] timestamp_ticks;
    logic signed [16:0] raw_x;
    logic signed [16:0] raw_y;
    logic [16:0] raw_z;
    logic touch;
    logic presence;
    logic valid_xyz;
    logic saturated;
    logic gap;
    logic [7:0] calibration_epoch;
  } v2_input_frame_t;
  localparam logic [7:0] V2_REASON_INVALID=8'h01;
  localparam logic [7:0] V2_REASON_SATURATED=8'h02;
  localparam logic [7:0] V2_REASON_GAP=8'h04;
  localparam logic [7:0] V2_REASON_EPOCH=8'h08;
  localparam logic [7:0] V2_REASON_CLAMP=8'h10;
  localparam logic [7:0] V2_REASON_PROFILE=8'h20;
  localparam logic [7:0] V2_REASON_ARITH_SAT=8'h40;
endpackage


