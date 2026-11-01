// Streams the Potts event list into the loop store's shadow track.
//
// The writer owns the store's write port while a commit is running: it starts
// the DP once, forwards every event with a running slot index, and only after
// the DP reports done does it ask the store to publish at the next loop
// boundary.  Requesting the swap earlier would publish a half written track.
module v2_loop_commit_writer (
  input  logic clk, rst_n,
  input  logic kick,                        // 0x28 write pulse
  input  logic dp_ready,                    // the DP's input data is ready
  output logic potts_start,
  input  logic potts_busy,
  input  logic potts_done,
  input  logic potts_event_valid,
  output logic potts_event_ready,
  input  logic [95:0] potts_event_data,
  input  logic store_write_ready,
  output logic store_write_valid,
  output logic [4:0] store_write_slot,
  output logic commit_request,
  output logic run,
  output logic done,
  output logic [5:0] count
);
  logic start_sent;

  assign store_write_valid = run && potts_event_valid;
  assign potts_event_ready = run && store_write_ready;
  assign store_write_slot = count[4:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0;
      done <= 1'b0;
      count <= 6'd0;
      start_sent <= 1'b0;
      potts_start <= 1'b0;
      commit_request <= 1'b0;
    end else begin
      potts_start <= 1'b0;
      commit_request <= 1'b0;
      if (kick) begin
        run <= 1'b1;
        done <= 1'b0;
        count <= 6'd0;
        start_sent <= 1'b0;
      end else if (run) begin
        // Wait until the data the DP will read (the purified valid mask) is
        // ready; a commit that arrives before the capture or purifier is done
        // must still start the DP afterwards.
        if (!start_sent && !potts_busy && dp_ready) begin
          potts_start <= 1'b1;
          start_sent <= 1'b1;
        end
        if (potts_event_valid && store_write_ready) count <= count + 1'b1;
        if (potts_done) begin
          run <= 1'b0;
          done <= 1'b1;
          commit_request <= 1'b1;
        end
      end
    end
  end
endmodule
