// GW5A DPB-backed implementation of the V2 32-slot event store.
// Six 16-bit lanes carry each 96-bit event; the nine-bit address packs
// bank, track, and slot (2*6*32 = 384 logical words).
module v2_loop_event_store_dpb #(
  parameter integer TRACKS=6,
  parameter integer DEPTH=32,
  parameter integer SLOT_BITS=(DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter integer COUNT_BITS=$clog2(DEPTH+1),
  parameter integer COPY_BITS=(TRACKS*DEPTH <= 1) ? 1 : $clog2(TRACKS*DEPTH),
  // 34 seconds at the 100 MHz system clock, matching the V2 wire contract.
  // Tests and lower-level integrations may override this with a short value.
  parameter [31:0] BOUNDARY_TIMEOUT_CYCLES=32'd3_400_000_000
) (
 input logic clk,rst_n,abort,loop_boundary,
 input logic ctrl_valid, output logic ctrl_ready, input logic [2:0] ctrl_op, input logic [2:0] ctrl_track, output logic ctrl_done,
 input logic write_valid, output logic write_ready, input logic [2:0] write_track, input logic [SLOT_BITS-1:0] write_slot, input logic [95:0] write_data,
 input logic read_enable, input logic [2:0] read_track, input logic [SLOT_BITS-1:0] read_index, output logic read_valid, output logic read_slot_valid, output logic [95:0] read_data,
 output logic active_bank, output logic shadow_bank, output logic commit_pending, output logic commit_ack, output logic busy,
 output logic [TRACKS*COUNT_BITS-1:0] record_count, output logic [TRACKS-1:0] overflow, output logic active_valid,
 output logic commit_timeout, output logic [31:0] commit_wait_cycles
);
  localparam integer BANK_DEPTH=TRACKS*DEPTH;
  localparam integer LAST_COPY=TRACKS*DEPTH-1;
  localparam logic [2:0] PREPARE_OVERDUB=3'd0, CLEAR_TRACK=3'd1, CLEAR_ALL=3'd2,
                         COMMIT_REQUEST=3'd3, ABORT_CMD=3'd4, PREPARE_RECORD=3'd5;
  logic [COUNT_BITS-1:0] counts [0:1][0:TRACKS-1];
  logic copy_active,copy_pending,copy_record;
  logic [2:0] copy_track;
  logic [COPY_BITS-1:0] copy_index,copy_write_index;
  logic read_pending,read_pending_slot_valid;
  logic [95:0] read_reg;
  logic [31:0] boundary_age;
  logic [15:0] dpb_doa [0:5];
  logic [8:0] ram_a_addr,ram_b_addr;
  logic ram_a_en,ram_b_en;
  logic [95:0] ram_b_data;
  integer b,t,k;

  function automatic [8:0] logical_addr(input logic bank,input logic [2:0] track,input logic [SLOT_BITS-1:0] slot);
    logic [10:0] tmp_addr;
    begin
      tmp_addr = (bank ? BANK_DEPTH : 0) + track*DEPTH + slot;
      logical_addr = tmp_addr[8:0];
    end
  endfunction

  assign shadow_bank=~active_bank;
  assign busy=copy_active||commit_pending;
  assign ctrl_ready=rst_n&&!abort&&(!busy || ctrl_op==ABORT_CMD);
  assign write_ready=rst_n&&!abort&&!busy&&!ctrl_valid&&(write_track<TRACKS)&&
    (write_slot==counts[shadow_bank][write_track])&&(counts[shadow_bank][write_track]<DEPTH);
  assign read_data=read_slot_valid?read_reg:96'd0;
  always_comb begin
    record_count='0;
    active_valid=1'b0;
    for (k=0;k<TRACKS;k=k+1) begin
      record_count[k*COUNT_BITS +: COUNT_BITS]=counts[shadow_bank][k];
      active_valid = active_valid || (counts[active_bank][k] != 0);
    end
  end

  // Port A is the active-bank synchronous read/copy source. Port B is the
  // shadow-bank write/copy destination. Copy writes trail reads by one clock.
  always_comb begin
    ram_a_en=1'b0; ram_a_addr='0; ram_b_en=1'b0; ram_b_addr='0; ram_b_data='0;
    if (copy_active) begin
      ram_a_en = copy_index <= LAST_COPY;
      ram_a_addr = logical_addr(active_bank, copy_index/DEPTH, copy_index%DEPTH);
      if (copy_pending) begin
        ram_b_en = 1'b1;
        ram_b_addr = logical_addr(shadow_bank, copy_write_index/DEPTH, copy_write_index%DEPTH);
        ram_b_data = {dpb_doa[5],dpb_doa[4],dpb_doa[3],dpb_doa[2],dpb_doa[1],dpb_doa[0]};
      end
    end else if (read_enable && !busy && read_track<TRACKS) begin
      ram_a_en=1'b1; ram_a_addr=logical_addr(active_bank,read_track,read_index);
    end else if (write_valid && write_ready) begin
      ram_b_en=1'b1; ram_b_addr=logical_addr(shadow_bank,write_track,write_slot); ram_b_data=write_data;
    end
  end

  for (genvar lane=0; lane<6; lane=lane+1) begin : g_lane
    DPB #(
      .BIT_WIDTH_0(16), .BIT_WIDTH_1(16), .READ_MODE0(1'b0), .READ_MODE1(1'b0),
      .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00), .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
      .RESET_MODE("SYNC")
    ) ram (
      .CLKA(clk), .CLKB(clk), .CEA(ram_a_en), .CEB(ram_b_en), .OCEA(1'b1), .OCEB(1'b1),
      .WREA(1'b0), .WREB(ram_b_en), .RESETA(1'b0), .RESETB(1'b0),
      .BLKSELA(3'b000), .BLKSELB(3'b000),
      .ADA({1'b0,ram_a_addr,4'b0011}), .ADB({1'b0,ram_b_addr,4'b0011}),
      .DIA(16'd0), .DIB(ram_b_data[lane*16 +: 16]), .DOA(dpb_doa[lane]), .DOB()
    );
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      active_bank<=0; copy_active<=0; copy_pending<=0; copy_record<=0; copy_track<=0;
      copy_index<=0; copy_write_index<=0; read_pending<=0; read_pending_slot_valid<=0;
      read_reg<=0; read_valid<=0; read_slot_valid<=0; commit_pending<=0; commit_ack<=0;
      commit_timeout<=0; commit_wait_cycles<=0; boundary_age<=0;
      ctrl_done<=0; overflow<=0;
      for(b=0;b<2;b=b+1) for(t=0;t<TRACKS;t=t+1) counts[b][t]<=0;
    end else begin
      ctrl_done<=0; commit_ack<=0; read_valid<=0; read_slot_valid<=0;
      if(abort) begin
        copy_active<=0; copy_pending<=0; commit_pending<=0; overflow<=0;
        boundary_age<=0; commit_timeout<=0; commit_wait_cycles<=0;
        for(t=0;t<TRACKS;t=t+1) counts[shadow_bank][t]<=0;
      end else if(ctrl_valid&&ctrl_ready&&ctrl_op==ABORT_CMD) begin
        copy_active<=0; copy_pending<=0; commit_pending<=0; overflow<=0; ctrl_done<=1;
        boundary_age<=0; commit_timeout<=0; commit_wait_cycles<=0;
        for(t=0;t<TRACKS;t=t+1) counts[shadow_bank][t]<=0;
      end else if(copy_active) begin
        copy_pending<=1'b1;
        if(copy_index<LAST_COPY) copy_index<=copy_index+1'b1;
        if(copy_pending) begin
          if(copy_write_index==LAST_COPY) begin
            copy_active<=0; copy_pending<=0; ctrl_done<=1;
            if(copy_record) counts[shadow_bank][copy_track]<=0;
          end else copy_write_index<=copy_write_index+1'b1;
        end
      end else if(commit_pending&&loop_boundary) begin
        active_bank<=shadow_bank; commit_pending<=0; commit_ack<=1; overflow<=0;
        commit_wait_cycles<=boundary_age; boundary_age<=0;
        for(t=0;t<TRACKS;t=t+1) counts[active_bank][t]<=0;
      end else if (commit_pending &&
                   ((BOUNDARY_TIMEOUT_CYCLES <= 32'd1) ||
                    (boundary_age >= (BOUNDARY_TIMEOUT_CYCLES - 32'd1)))) begin
        // A timed-out boundary never publishes the shadow bank. Drop its
        // metadata so a later PREPARE starts from the still-active bank.
        commit_pending<=0; commit_timeout<=1'b1;
        commit_wait_cycles<=boundary_age; boundary_age<=0;
        for(t=0;t<TRACKS;t=t+1) begin
          counts[shadow_bank][t]<=0;
          overflow[t]<=1'b0;
        end
      end else if (commit_pending) begin
        boundary_age <= boundary_age + 32'd1;
      end else if(ctrl_valid&&ctrl_ready) begin
        case(ctrl_op)
          PREPARE_OVERDUB,PREPARE_RECORD: begin
            copy_active<=1; copy_pending<=0; copy_record<=ctrl_op==PREPARE_RECORD;
            copy_track<=ctrl_track; copy_index<=0; copy_write_index<=0;
            for(t=0;t<TRACKS;t=t+1) counts[shadow_bank][t]<=counts[active_bank][t];
          end
          CLEAR_TRACK: begin ctrl_done<=1; if(ctrl_track<TRACKS) begin counts[shadow_bank][ctrl_track]<=0; overflow[ctrl_track]<=0; end end
          CLEAR_ALL: begin ctrl_done<=1; for(t=0;t<TRACKS;t=t+1) counts[shadow_bank][t]<=0; overflow<=0; end
          COMMIT_REQUEST: begin
            ctrl_done<=1; commit_pending<=1; boundary_age<=0; commit_timeout<=1'b0;
          end
          default: ctrl_done<=1;
        endcase
      end else begin
        if(write_valid&&!write_ready&&write_track<TRACKS&&counts[shadow_bank][write_track]>=DEPTH) overflow[write_track]<=1;
        if(write_valid&&write_ready) counts[shadow_bank][write_track]<=counts[shadow_bank][write_track]+1'b1;
      end

      if(read_pending) begin
        read_pending<=0; read_valid<=1; read_slot_valid<=read_pending_slot_valid;
        read_reg<={dpb_doa[5],dpb_doa[4],dpb_doa[3],dpb_doa[2],dpb_doa[1],dpb_doa[0]};
      end else if(read_enable&&!busy&&read_track<TRACKS) begin
        read_pending<=1; read_pending_slot_valid<=read_index<counts[active_bank][read_track];
      end
    end
  end
endmodule
