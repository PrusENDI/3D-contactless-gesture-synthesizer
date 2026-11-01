// Rewrites every valid run shorter than MIN_RUN into the previous run.
//
// The Potts DP refuses a segment that mixes rest and data and requires every
// non-initial segment to be at least MIN_RUN long, so a short run leaves no
// valid segmentation at all and the backtrace publishes garbage.  Absorbing
// short runs first makes a path always exist; the first run may stay short
// because the DP already allows a short initial segment.
//
// Runs are processed left to right and rewritten in place, so a chain of
// consecutive short runs keeps collapsing (a single pass over the raw mask
// would leave the second one standing).
module v2_loop_rest_purify #(
  parameter integer K = 32,
  parameter integer MIN_RUN = 4
) (
  input  logic clk, rst_n,
  input  logic start,
  input  logic [K-1:0] raw_valid,
  output logic [K-1:0] purified_valid,
  output logic busy,
  output logic done
);
  localparam integer SB = (K <= 1) ? 1 : $clog2(K);

  localparam logic [1:0] IDLE = 2'd0, SCAN = 2'd1, ABSORB = 2'd2;

  logic [1:0] state;
  logic [K-1:0] pur;
  logic [SB:0] idx;
  logic [SB:0] run_start;
  logic [SB:0] wpos, wend;
  logic absorb_value;
  logic pend_idx_set;
  logic [SB:0] pend_idx, pend_run;
  logic tail_absorb;

  assign purified_valid = pur;
  assign busy = (state != IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      pur <= {K{1'b0}};
      idx <= '0;
      run_start <= '0;
      wpos <= '0;
      wend <= '0;
      absorb_value <= 1'b0;
      pend_idx_set <= 1'b0;
      pend_idx <= '0;
      pend_run <= '0;
      tail_absorb <= 1'b0;
      done <= 1'b0;
    end else begin
      done <= 1'b0;
      case (state)
        IDLE: begin
          if (start) begin
            pur <= raw_valid;
            idx <= {{(SB-1){1'b0}}, 1'b1};
            run_start <= '0;
            tail_absorb <= 1'b0;
            pend_idx_set <= 1'b0;
            state <= SCAN;
          end
        end
        SCAN: begin
          if (idx < K) begin
            if (pur[idx] != pur[idx-1]) begin
              if (((idx - run_start) < MIN_RUN) && (run_start != 0)) begin
                wpos <= run_start;
                wend <= idx;
                absorb_value <= pur[run_start - 1'b1];
                pend_idx <= idx;
                pend_run <= idx;
                pend_idx_set <= 1'b1;
                state <= ABSORB;
              end else begin
                run_start <= idx;
                idx <= idx + 1'b1;
              end
            end else begin
              idx <= idx + 1'b1;
            end
          end else if (((idx - run_start) < MIN_RUN) && (run_start != 0)) begin
            // Tail: the last run is short too, absorb it and finish.
            wpos <= run_start;
            wend <= idx;
            absorb_value <= pur[run_start - 1'b1];
            tail_absorb <= 1'b1;
            state <= ABSORB;
          end else begin
            state <= IDLE;
            done <= 1'b1;
          end
        end
        ABSORB: begin
          if (wpos < wend) begin
            pur[wpos] <= absorb_value;
            wpos <= wpos + 1'b1;
          end else if (tail_absorb) begin
            tail_absorb <= 1'b0;
            state <= IDLE;
            done <= 1'b1;
          end else if (pend_idx_set) begin
            pend_idx_set <= 1'b0;
            run_start <= pend_run;
            idx <= pend_idx + 1'b1;
            state <= SCAN;
          end else begin
            state <= IDLE;
            done <= 1'b1;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
