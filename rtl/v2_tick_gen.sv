// Musical tick generator: one tick = one 16th note, 128 ticks = 8 bars.
//
//   samples_per_tick = 48000 * 60 / (BPM * 4) = 720000 / BPM        (rounded)
//
// The division runs once per BPM write (20 clocks), not per sample: a sequential
// restoring divider is far cheaper than a constant divider in the datapath, and
// a tempo change is a host action, not a per-sample event.
//
// Writing BPM clears the tick and the phase counter so a tempo change restarts
// the bar instead of jumping phase mid-loop.
module v2_tick_gen (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        sample_ce,
  input  logic [15:0] bpm,
  input  logic        bpm_we,
  input  logic        restart,   // host tempo change restarts the bar; auto tempo does not
  output logic        tick_pulse,
  output logic [6:0]  tick,
  output logic [23:0] samples_per_tick
);

  localparam logic [19:0] DIVIDEND = 20'd720000;
  localparam logic [15:0] BPM_DEF  = 16'd120;

  logic        div_busy;
  logic [4:0]  div_step;
  logic [19:0] div_quot;
  logic [19:0] div_rem;
  logic [19:0] div_dend;
  logic [15:0] div_sor;
  logic [23:0] spt_q;
  logic [23:0] phase_cnt;
  logic        pulse_q;

  wire [20:0] rem_shift = {div_rem, div_dend[19]};
  wire [20:0] sub_term  = {5'd0, div_sor};
  wire        sub_ok    = (rem_shift >= sub_term);
  wire [15:0] bpm_use   = (bpm == 16'd0) ? BPM_DEF : bpm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_busy <= 1'b0; div_step <= 5'd0; div_quot <= 20'd0; div_rem <= 20'd0;
      div_dend <= DIVIDEND; div_sor <= BPM_DEF; spt_q <= 24'd6000;
      phase_cnt <= 24'd0; tick <= 7'd0; pulse_q <= 1'b0;
    end else begin
      pulse_q <= 1'b0;
      if (bpm_we) begin
        // Dividend carries bpm/2 so the quotient is the rounded samples-per-tick.
        div_busy <= 1'b1; div_step <= 5'd0; div_quot <= 20'd0; div_rem <= 20'd0;
        div_dend <= DIVIDEND + {15'd0, bpm_use[15:1]};
        div_sor  <= bpm_use;
        // A host tempo change restarts the bar.  The X-driven LIVE tempo updates
        // at frame rate; resetting the phase there would suppress every tick
        // while the hand moves, so only `restart` clears the counter.
        if (restart) begin
          tick <= 7'd0;
          phase_cnt <= 24'd0;
        end
      end else if (div_busy) begin
        if (sub_ok) begin
          div_rem  <= rem_shift[19:0] - {4'd0, div_sor};
          div_quot <= {div_quot[18:0], 1'b1};
        end else begin
          div_rem  <= rem_shift[19:0];
          div_quot <= {div_quot[18:0], 1'b0};
        end
        div_dend <= {div_dend[18:0], 1'b0};
        div_step <= div_step + 5'd1;
        if (div_step == 5'd19) begin
          div_busy <= 1'b0;
          // Quotient after the last step is the old quotient shifted in with this
          // step's bit; the dividend already carried bpm/2, so it is rounded.
          spt_q <= {4'd0, div_quot[18:0], sub_ok};
        end
      end else if (sample_ce) begin
        if (spt_q != 24'd0 && (phase_cnt + 24'd1) >= spt_q) begin
          phase_cnt <= 24'd0;
          pulse_q   <= 1'b1;
          tick      <= (tick == 7'd127) ? 7'd0 : (tick + 7'd1);
        end else begin
          phase_cnt <= phase_cnt + 24'd1;
        end
      end
    end
  end

  assign tick_pulse       = pulse_q;
  assign samples_per_tick = spt_q;

endmodule
