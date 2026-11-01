// Tick-driven contour capture, independent of the LIVE event stream.
//
// Arming only starts a search for the next tick 0; the K samples are then
// written in order, so sample[i] always belongs to loop tick i.  A loop that is
// only half captured keeps valid=0 on the untouched ticks, which the DP treats
// as rests, so a partial take can never rotate the melody.
module v2_loop_contour_capture #(
  parameter integer K = 32
) (
  input  logic clk, rst_n,
  input  logic arm,                 // one-cycle pulse from the host command
  input  logic tick_pulse,          // v2_tick_gen
  input  logic [6:0] mtick,         // v2_tick_gen musical tick
  input  logic [15:0] y,            // cursor_y
  input  logic engaged,             // cursor_engaged
  input  logic [4:0] rd_index,
  output logic [15:0] rd_data,
  output logic [K-1:0] valid_mask,
  output logic full
);
  localparam integer SB = (K <= 1) ? 1 : $clog2(K);

  logic [15:0] mem [0:K-1];
  logic [SB-1:0] wr;
  logic armed;
  logic waiting_zero;
  integer i;

  assign rd_data = {6'd0, mem[rd_index[SB-1:0]]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      armed <= 1'b0;
      waiting_zero <= 1'b0;
      wr <= {SB{1'b0}};
      full <= 1'b0;
      valid_mask <= {K{1'b0}};
      for (i = 0; i < K; i = i + 1) mem[i] <= 16'd0;
    end else if (arm) begin
      armed <= 1'b1;
      waiting_zero <= 1'b1;
      wr <= {SB{1'b0}};
      full <= 1'b0;
      valid_mask <= {K{1'b0}};
      for (i = 0; i < K; i = i + 1) mem[i] <= 16'd0;
    end else if (armed && tick_pulse) begin
      if (waiting_zero) begin
        // The first sample must be loop tick 0, wherever the host armed us.
        if (mtick[4:0] == 5'd0) begin
          waiting_zero <= 1'b0;
          mem[0] <= y[15:6];
          valid_mask[0] <= engaged;
          wr <= {{(SB-1){1'b0}}, 1'b1};
          if (K == 1) begin
            full <= 1'b1;
            armed <= 1'b0;
          end
        end
      end else begin
        mem[wr] <= y[15:6];
        valid_mask[wr] <= engaged;
        if (wr == (K - 1)) begin
          full <= 1'b1;
          armed <= 1'b0;
        end else begin
          wr <= wr + 1'b1;
        end
      end
    end
  end
endmodule
