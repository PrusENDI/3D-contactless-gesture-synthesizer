// Bounded fixed-point Potts DP: one (end,start,degree) cell is evaluated per
// cell sequence. Costs saturate at 32'h3fffffff; ties prefer longer segments
// then lower degree. Backpointers are traced before the held event stream is
// published.
//
// Resource shape (2026-10-29 B stream):
// - the board profile (HORIZON<=63) keeps the dp table in explicit GW5A DPB
//   lanes, so the two 32-bit variable-index read muxes disappear from fabric
//   logic.  A cell is then evaluated as SEGMENT -> RD1 -> RD2 -> CELL_COMMIT,
//   with the registered DPB read replacing the asynchronous array read.
// - larger horizons (the portable HORIZON=128 default) keep the previous
//   register-array dp table; they are simulation-only and never placed.
// - the event holding RAM is sized by the DP segment bound (EV_CAP).
// - cost/err arithmetic stays 32-bit signed, the cell order, tie-break and
//   saturation are unchanged, so emitted events are bit-identical.
module v2_potts_commit_fsm #(
 parameter integer MAX_EVENTS=32,
 parameter integer MIN_LENGTH=4,
 // The contract exposes a 128-point contour.  A shorter horizon is useful
 // for a board build whose loop store has a smaller fixed capacity; the
 // default preserves the full 128-point behavior used by existing tests.
 parameter integer HORIZON=128
)(
 input logic clk,rst_n,input logic start,input logic [15:0] lambda_q16,input logic [127:0] rest_mask,
 input logic signed [15:0] contour [0:127], output logic busy,output logic [7:0] progress,
 output logic done,output logic overflow,output logic backtrace_valid,output logic event_valid,
 input logic event_ready,output logic [95:0] event_data,output logic [5:0] event_count);
 localparam [3:0] IDLE=0,INIT=1,CELL=2,SEGMENT=3,RD1=4,RD2=5,CELL_COMMIT=6,WRITE=7,TRACE=8,EMIT=9;
 // A contour of HORIZON ticks with MIN_LENGTH minimum segment length can never
 // emit more than HORIZON/MIN_LENGTH+1 segments.  The board profile is
 // HORIZON=32/MIN_LENGTH=4, so 9 entries are enough there; HORIZON=128 still
 // uses the full MAX_EVENTS=32 contract.  Sizing the holding RAM by the smaller
 // bound removes the 32:1 read mux from the board build without changing any
 // event that the DP can produce.
 localparam integer EV_CAP = ((HORIZON/MIN_LENGTH+1) < MAX_EVENTS) ? (HORIZON/MIN_LENGTH+1) : MAX_EVENTS;
 // DPB lanes hold HORIZON+1 words; the board profile needs 33, so 6 address
 // bits are enough and fit the 1024-row DPB view.
 localparam integer DP_RAM = (HORIZON <= 63);
 logic [3:0] state;
 integer e,s,d,t,seg_t,init_idx;
 integer signed cost,err,sum,err_acc;
 integer has_rest,has_data,has_rest_acc,has_data_acc;
 integer trace_end,trace_start,trace_deg;
 logic [7:0] bp_s[0:HORIZON],bp_d[0:HORIZON];
 logic [95:0] events[0:EV_CAP-1];
 logic [5:0] wr,rd;
 logic [95:0] temp_event;
 logic [95:0] ev_q;
 logic ev_valid_q;
 logic [7:0] dp_rd_addr,dp_wr_addr;
 logic [31:0] dp_wr_data,dp_s_val,dp_rd_data;
 logic dp_wr_en;
 logic [31:0] commit_cost;
 logic commit_upd;
 logic commit_upd_q;
 logic last_cell;
 logic [7:0] wr_e_q, wr_s_q;
 logic [2:0] wr_d_q;
 logic [31:0] wr_cost_q;
 // Two tables: `level` is the contour value a degree is fitted against (the
 // midpoint of that note's cursor_y interval, decided by the map in
 // v2_live_rule_engine and shifted by six), `midi_note` is what the event
 // carries.  Using one table for both would put 30..978 into the note field.
 function automatic integer level(input integer k); case(k)0:level=30;1:level=135;2:level=286;3:level=421;4:level=557;5:level=707;6:level=858;default:level=978;endcase endfunction
 function automatic integer midi_note(input integer k); case(k)0:midi_note=55;1:midi_note=57;2:midi_note=60;3:midi_note=62;4:midi_note=64;5:midi_note=67;6:midi_note=69;default:midi_note=72;endcase endfunction
 function automatic [31:0] sat(input integer v); if(v>32'sh3fffffff)sat=32'sh3fffffff; else if(v<0)sat=32'd0; else sat=v[31:0]; endfunction
 assign busy=state!=IDLE; assign event_valid=ev_valid_q; assign event_data=ev_valid_q?ev_q:96'd0;
 assign dp_rd_addr = (state==RD1) ? s[7:0] : e[7:0];
 assign dp_wr_addr = (state==INIT) ? init_idx[7:0] : wr_e_q;
 assign dp_wr_data = (state==INIT) ? ((init_idx==0) ? 32'd0 : 32'h3fffffff) : wr_cost_q;
 assign dp_wr_en   = (state==INIT) || ((state==WRITE) && commit_upd_q);
 always_comb begin
  integer signed c,errc;
  errc = err_acc;
  if (errc > 32'sh3fffffff) errc = 32'sh3fffffff;
  c = dp_s_val + errc + ((s==0) ? 0 : lambda_q16);
  commit_cost = sat(c);
  commit_upd = 1'b0;
  if (state==CELL_COMMIT && (!has_rest_acc || !has_data_acc) && ((e-s)>=MIN_LENGTH || s==0))
   commit_upd = (c<dp_rd_data) || ((c==dp_rd_data) && (s<=bp_s[e]));
 end
 generate
  if (DP_RAM) begin : g_dp_ram
   logic [15:0] dp_rd_lo,dp_rd_hi;
   assign dp_rd_data = {dp_rd_hi,dp_rd_lo};
   DPB #(
    .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
    .READ_MODE0(1'b0), .READ_MODE1(1'b0),
    .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
    .RESET_MODE("SYNC")
   ) dp_lo (
    .CLKA(clk), .CLKB(clk),
    .CEA(1'b1), .CEB(dp_wr_en),
    .OCEA(1'b1), .OCEB(1'b1),
    .WREA(1'b0), .WREB(dp_wr_en),
    .RESETA(1'b0), .RESETB(1'b0),
    .BLKSELA(3'b000), .BLKSELB(3'b000),
    .ADA({4'b0, dp_rd_addr[5:0], 4'b0011}),
    .ADB({4'b0, dp_wr_addr[5:0], 4'b0011}),
    .DIA(16'd0), .DIB(dp_wr_data[15:0]),
    .DOA(dp_rd_lo), .DOB()
   );
   DPB #(
    .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
    .READ_MODE0(1'b0), .READ_MODE1(1'b0),
    .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
    .RESET_MODE("SYNC")
   ) dp_hi (
    .CLKA(clk), .CLKB(clk),
    .CEA(1'b1), .CEB(dp_wr_en),
    .OCEA(1'b1), .OCEB(1'b1),
    .WREA(1'b0), .WREB(dp_wr_en),
    .RESETA(1'b0), .RESETB(1'b0),
    .BLKSELA(3'b000), .BLKSELB(3'b000),
    .ADA({4'b0, dp_rd_addr[5:0], 4'b0011}),
    .ADB({4'b0, dp_wr_addr[5:0], 4'b0011}),
    .DIA(16'd0), .DIB(dp_wr_data[31:16]),
    .DOA(dp_rd_hi), .DOB()
   );
  end else begin : g_dp_reg
   logic [31:0] dp[0:HORIZON];
   assign dp_rd_data = (state==RD2) ? dp[s[7:0]] : dp[e[7:0]];
   always_ff @(posedge clk) if (dp_wr_en) dp[dp_wr_addr] <= dp_wr_data;
  end
 endgenerate
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin state<=IDLE;done<=0;overflow<=0;backtrace_valid<=0;progress<=0;e<=0;s<=0;d<=0;wr<=0;rd<=0;event_count<=0;init_idx<=0;ev_valid_q<=1'b0;end else begin done<=0;
   case(state)
    IDLE: if(start)begin state<=INIT;init_idx<=0;wr<=0;rd<=0;overflow<=0;backtrace_valid<=0;progress<=0;end
    INIT: begin
      if(init_idx==HORIZON)begin e<=1;s<=0;d<=0;state<=CELL;end
      else init_idx<=init_idx+1;
    end
    CELL: begin
      err_acc=0; has_rest_acc=0; has_data_acc=0; seg_t=s; state<=SEGMENT;
    end
    SEGMENT: begin
      if (seg_t < e) begin
        if (rest_mask[seg_t]) has_rest_acc=1;
        else begin
          has_data_acc=1;
          err_acc=err_acc+(contour[seg_t]-level(d))*(contour[seg_t]-level(d));
        end
        seg_t=seg_t+1;
      end else state<=RD1;
    end
    RD1: state<=RD2;
    RD2: begin dp_s_val<=dp_rd_data; state<=CELL_COMMIT; end
    CELL_COMMIT: begin
      err=err_acc; has_rest=has_rest_acc; has_data=has_data_acc;
      commit_upd_q <= commit_upd;
      wr_e_q <= e[7:0]; wr_s_q <= s[7:0]; wr_d_q <= d; wr_cost_q <= commit_cost;
      last_cell <= (e==HORIZON && s==HORIZON-1 && d==7);
      if(d==7)begin d<=0;if(s==e-1)begin s<=0;e<=e+1;progress<=e;end else s<=s+1;end else d<=d+1;
      state<=WRITE;
    end
    WRITE: begin
      // The write enable and backpointer data are driven by registers, so the
      // long compare chain that decides an update no longer feeds the RAM CE.
      if(commit_upd_q)begin bp_s[wr_e_q]<=wr_s_q; bp_d[wr_e_q]<={5'd0,wr_d_q}; end
      if(last_cell)begin state<=TRACE;trace_end<=HORIZON;wr<=0;end
      else state<=CELL;
    end
    TRACE: begin
      if(trace_end==0)begin backtrace_valid<=1;event_count<=wr;rd<=0;if(wr==0)begin ev_valid_q<=1'b0;state<=IDLE;done<=1;end else begin ev_q<=events[0];ev_valid_q<=1'b1;state<=EMIT;end end
      else begin trace_start=bp_s[trace_end];trace_deg=bp_d[trace_end];if(!rest_mask[trace_start]&&wr<EV_CAP)begin temp_event=0;temp_event[94:91]=4'd1;temp_event[87:80]=trace_start;temp_event[79:72]=trace_end-trace_start;temp_event[71:64]=midi_note(trace_deg);temp_event[63:56]=8'd100;events[wr]<=temp_event;wr<=wr+1;end else if(wr>=EV_CAP)overflow<=1;trace_end<=trace_start;end
    end
    EMIT: if(ev_valid_q&&event_ready)begin if(rd+1>=wr)begin ev_valid_q<=1'b0;state<=IDLE;done<=1;end else begin rd<=rd+1;ev_q<=events[rd+1];ev_valid_q<=1'b1;end end
   endcase
  end
 end
endmodule
