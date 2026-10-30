// Double-buffered, tear-free V2 telemetry snapshot.
//
// capture_* is a control/sample-domain boundary. Once accepted, all fields
// are copied into the inactive 20-byte body and its CRC is calculated before
// the bank becomes visible to the byte serializer. TX backpressure only holds
// the selected byte; a later capture fills the other bank and never changes a
// frame already in flight.
module v2_telemetry_snapshot (
    input logic clk, input logic rst_n,
    input logic capture_valid, output logic capture_ready,
    input logic [7:0] capture_type, input logic [15:0] capture_sequence,
    input logic signed [15:0] capture_x, input logic signed [15:0] capture_y,
    input logic signed [15:0] capture_z, input logic [7:0] capture_note,
    input logic [7:0] capture_flags, input logic [7:0] capture_tick,
    input logic [31:0] capture_voice_bitmap, input logic [7:0] capture_fifo_level,
    input logic [7:0] capture_fault_code,
    output logic frame_valid, input logic frame_ready,
    output logic [7:0] frame_byte, output logic frame_last,
    output logic [7:0] dropped_captures
);
    logic [7:0] bank [0:1][0:21];
    logic active_bank;
    logic bank_full [0:1];
    logic [4:0] tx_index;
    logic [15:0] crc_tmp;
    // The 20-byte CRC is folded five bytes per clock over four clocks so the
    // capture cycle no longer contains a 20-step combinational chain.
    logic [15:0] crc_acc;
    logic [2:0]  crc_phase;
    logic        crc_pending, crc_bank;
    logic [7:0]  cap_type, cap_note, cap_flags, cap_tick, cap_fifo_level, cap_fault_code;
    logic [15:0] cap_sequence, cap_x, cap_y, cap_z;
    logic [31:0] cap_voice_bitmap;
    integer i;

    function automatic logic [15:0] crc8_step(input logic [15:0] crc_in,
                                               input logic [7:0] byte_in);
        logic [15:0] c; integer b;
        begin
            c = crc_in ^ {byte_in,8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc8_step = c;
        end
    endfunction

    assign frame_valid = bank_full[active_bank];
    assign frame_byte = bank[active_bank][tx_index];
    assign frame_last = frame_valid && (tx_index == 21);
    // A capture can use the inactive bank while the active frame is being
    // transmitted. If both banks are full, preserve the in-flight snapshot.
    assign capture_ready = !bank_full[~active_bank] && !crc_pending;

    wire capture_accept = capture_valid && capture_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0] body_byte;
        logic [15:0] crc_local;
        integer idx;
        if (!rst_n) begin
            active_bank <= 1'b0;
            bank_full[0] <= 1'b0; bank_full[1] <= 1'b0;
            tx_index <= 0;
            dropped_captures <= 0;
            crc_pending <= 1'b0; crc_phase <= 3'd0; crc_acc <= 16'hffff; crc_bank <= 1'b0;
            for (i = 0; i < 22; i = i + 1) begin
                bank[0][i] <= 0; bank[1][i] <= 0;
            end
        end else begin
            if (frame_valid && frame_ready) begin
                if (tx_index == 21) begin
                    bank_full[active_bank] <= 1'b0;
                    // If the inactive bank is filled on this same edge, it is
                    // the next frame even though bank_full[~active_bank] is
                    // still the old value in this clocked block.
                    if (bank_full[~active_bank] || capture_accept)
                        active_bank <= ~active_bank;
                    tx_index <= 0;
                end else tx_index <= tx_index + 1'b1;
            end
            if (capture_valid) begin
                if (capture_ready) begin
                    bank[~active_bank][0] <= 8'h5A;
                    bank[~active_bank][1] <= 8'h02;
                    bank[~active_bank][2] <= capture_type;
                    bank[~active_bank][3] <= capture_sequence[15:8];
                    bank[~active_bank][4] <= capture_sequence[7:0];
                    bank[~active_bank][5] <= capture_x[15:8]; bank[~active_bank][6] <= capture_x[7:0];
                    bank[~active_bank][7] <= capture_y[15:8]; bank[~active_bank][8] <= capture_y[7:0];
                    bank[~active_bank][9] <= capture_z[15:8]; bank[~active_bank][10] <= capture_z[7:0];
                    bank[~active_bank][11] <= capture_note;
                    bank[~active_bank][12] <= capture_flags;
                    bank[~active_bank][13] <= capture_tick;
                    bank[~active_bank][14] <= capture_voice_bitmap[31:24];
                    bank[~active_bank][15] <= capture_voice_bitmap[23:16];
                    bank[~active_bank][16] <= capture_voice_bitmap[15:8];
                    bank[~active_bank][17] <= capture_voice_bitmap[7:0];
                    bank[~active_bank][18] <= capture_fifo_level;
                    bank[~active_bank][19] <= capture_fault_code;
                    // Latch the payload and let the CRC finish over four clocks.
                    cap_type <= capture_type;
                    cap_sequence <= capture_sequence;
                    cap_x <= capture_x; cap_y <= capture_y; cap_z <= capture_z;
                    cap_note <= capture_note; cap_flags <= capture_flags;
                    cap_tick <= capture_tick; cap_voice_bitmap <= capture_voice_bitmap;
                    cap_fifo_level <= capture_fifo_level; cap_fault_code <= capture_fault_code;
                    crc_acc <= 16'hffff;
                    crc_phase <= 3'd1;
                    crc_bank <= ~active_bank;
                    crc_pending <= 1'b1;
                end else dropped_captures <= dropped_captures + 1'b1;
            end
            // Five bytes per clock, four clocks per snapshot.  The byte
            // selection is constant per phase so each clock contains only five
            // serial CRC steps instead of a 20-way mux chain.
            if (crc_pending) begin
                crc_local = crc_acc;
                case (crc_phase)
                  3'd1: begin
                    crc_local = crc8_step(crc_local, 8'h5A);
                    crc_local = crc8_step(crc_local, 8'h02);
                    crc_local = crc8_step(crc_local, cap_type);
                    crc_local = crc8_step(crc_local, cap_sequence[15:8]);
                    crc_local = crc8_step(crc_local, cap_sequence[7:0]);
                  end
                  3'd2: begin
                    crc_local = crc8_step(crc_local, cap_x[15:8]);
                    crc_local = crc8_step(crc_local, cap_x[7:0]);
                    crc_local = crc8_step(crc_local, cap_y[15:8]);
                    crc_local = crc8_step(crc_local, cap_y[7:0]);
                    crc_local = crc8_step(crc_local, cap_z[15:8]);
                  end
                  3'd3: begin
                    crc_local = crc8_step(crc_local, cap_z[7:0]);
                    crc_local = crc8_step(crc_local, cap_note);
                    crc_local = crc8_step(crc_local, cap_flags);
                    crc_local = crc8_step(crc_local, cap_tick);
                    crc_local = crc8_step(crc_local, cap_voice_bitmap[31:24]);
                  end
                  default: begin
                    crc_local = crc8_step(crc_local, cap_voice_bitmap[23:16]);
                    crc_local = crc8_step(crc_local, cap_voice_bitmap[15:8]);
                    crc_local = crc8_step(crc_local, cap_voice_bitmap[7:0]);
                    crc_local = crc8_step(crc_local, cap_fifo_level);
                    crc_local = crc8_step(crc_local, cap_fault_code);
                  end
                endcase
                if (crc_phase == 3'd4) begin
                    bank[crc_bank][20] <= crc_local[15:8];
                    bank[crc_bank][21] <= crc_local[7:0];
                    bank_full[crc_bank] <= 1'b1;
                    if (!bank_full[active_bank]) active_bank <= crc_bank;
                    crc_pending <= 1'b0;
                    crc_phase <= 3'd0;
                end else begin
                    crc_acc <= crc_local;
                    crc_phase <= crc_phase + 3'd1;
                end
            end
        end
    end
endmodule
