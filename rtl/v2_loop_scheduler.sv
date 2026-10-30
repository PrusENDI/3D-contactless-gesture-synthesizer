// V2 scheduler: six-track, three-pass (OFF/ON/CONTROL) scan with held output.
// The scan covers every one of the 32 slots before advancing track/pass.
module v2_loop_scheduler #(
  parameter integer TRACKS=6,
  parameter integer DEPTH=32,
  parameter integer SLOT_BITS=(DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
 input logic clk,rst_n,run,stop,flush,input logic [2:0] selected_track,input logic [6:0] loop_tick,
 input logic read_valid,read_slot_valid,input logic [95:0] read_data,
 output logic read_enable,output logic [2:0] read_track,output logic [SLOT_BITS-1:0] read_index,
 output logic event_valid,input logic event_ready,output logic [95:0] event_data,output logic fault_valid,
 output logic loop_boundary);
  localparam logic [3:0] EV_NOTE_ON=4'd1,EV_NOTE_OFF=4'd2,EV_CONTROL=4'd4,EV_ALL_NOTES_OFF=4'd5,EV_BOUNDARY=4'd6;
  logic [SLOT_BITS-1:0] slot;
  logic [2:0] track;
  logic [1:0] pass;
  logic waiting;
  logic [95:0] held;
  logic [1:0] boundary_stage;
  assign read_track=track;
  assign read_index=slot;
  assign read_enable=run&&!stop&&!flush&&!event_valid&&!waiting;
  assign event_data=held;

  always_ff @(posedge clk or negedge rst_n) begin
    logic [8:0] end_tick;
    if(!rst_n) begin
      slot<=0; track<=0; pass<=0; waiting<=0; held<=0; event_valid<=0;
      fault_valid<=0; loop_boundary<=0; boundary_stage<=0;
    end else begin
      loop_boundary<=0;
      if(stop||flush) begin
        slot<=0; track<=0; pass<=0; waiting<=0; event_valid<=0; boundary_stage<=0;
      end else if(run) begin
        if(read_enable) waiting<=1;
        if(waiting&&read_valid) begin
          waiting<=0;
          end_tick={1'b0,read_data[87:80]}+{1'b0,read_data[79:72]};
          if(read_slot_valid&&((pass==0&&read_data[94:91]==EV_NOTE_OFF&&read_data[87:80]==loop_tick)||
             (pass==1&&read_data[94:91]==EV_NOTE_ON&&read_data[87:80]==loop_tick)||
             (pass==2&&read_data[94:91]==EV_CONTROL&&read_data[87:80]==loop_tick)||
             (pass==0&&read_data[94:91]==EV_NOTE_ON&&read_data[79:72]!=0&&end_tick<128&&end_tick[6:0]==loop_tick))) begin
            held<=read_data;
            if(pass==0&&read_data[94:91]==EV_NOTE_ON&&read_data[79:72]!=0&&end_tick<128&&end_tick[6:0]==loop_tick) begin
              held[94:91]<=EV_NOTE_OFF; held[87:80]<=loop_tick; held[79:72]<=0;
            end
            event_valid<=1;
          end else if(slot==DEPTH-1) begin
            slot<=0;
            if(track==TRACKS-1) begin
              track<=0;
              if(pass==2) begin
                pass<=0;
                if(loop_tick==127) boundary_stage<=1;
              end else pass<=pass+1'b1;
            end else track<=track+1'b1;
          end else slot<=slot+1'b1;
        end
        if(event_valid&&event_ready) begin
          event_valid<=0;
          if(slot==DEPTH-1) begin
            slot<=0;
            if(track==TRACKS-1) begin
              track<=0;
              if(pass==2) begin
                pass<=0;
                if(loop_tick==127) boundary_stage<=1;
              end else pass<=pass+1'b1;
            end else track<=track+1'b1;
          end else slot<=slot+1'b1;
        end
        if(boundary_stage==1&&!event_valid) begin
          held<=96'd0; held[94:91]<=EV_ALL_NOTES_OFF; held[87:80]<=loop_tick;
          event_valid<=1; boundary_stage<=2;
        end
        if(boundary_stage==2&&event_valid&&event_ready) begin
          held<=96'd0; held[94:91]<=EV_BOUNDARY; held[87:80]<=loop_tick;
          event_valid<=1; boundary_stage<=3;
        end
        if(boundary_stage==3&&event_valid&&event_ready) begin
          event_valid<=0; loop_boundary<=1; boundary_stage<=0;
        end
      end
    end
  end
endmodule
