// System-domain sample enable for an exact long-term 48 kHz rate.
// The accumulator is bounded below SYSTEM_RATE, so 32 bits are sufficient.
module v2_sample_scheduler #(parameter integer SYSTEM_RATE_HZ = 80_000_000) (
  input  logic        clk_sys,
  input  logic        rst_n,
  output logic        sample_ce,
  output logic [31:0] sample_index
);
  localparam logic [31:0] SAMPLE_RATE = 32'd48_000;
  localparam logic [31:0] SYSTEM_RATE = SYSTEM_RATE_HZ;
  logic [31:0] phase_acc;

  always_ff @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
      phase_acc   <= 32'd0;
      sample_ce   <= 1'b0;
      sample_index <= 32'd0;
    end else begin
      sample_ce <= 1'b0;
      if (phase_acc >= (SYSTEM_RATE - SAMPLE_RATE)) begin
        phase_acc <= phase_acc + SAMPLE_RATE - SYSTEM_RATE;
        sample_ce <= 1'b1;
        sample_index <= sample_index + 32'd1;
      end else begin
        phase_acc <= phase_acc + SAMPLE_RATE;
      end
    end
  end
endmodule
