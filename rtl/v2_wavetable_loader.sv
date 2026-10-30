// V2 A/B/C wavetable shadow uploader.
//
// Each table has two 1024x16 DPB banks. Writes always target the inactive
// bank. APPLY scans the complete shadow table with a registered DPB read,
// checks CRC16/CCITT-FALSE, and toggles the active bank only at idle or a loop
// boundary. No sample memory is reset, so the six table banks remain BSRAM.
module v2_wt_mem #(
    parameter integer DEPTH = 1024,
    parameter integer USE_GOWIN_RAM = 0
) (
    input logic clk, input logic rst_n,
    input logic rd_en, input logic [9:0] rd_addr,
    output logic signed [15:0] rd_data,
    input logic wr_en, input logic [9:0] wr_addr,
    input logic signed [15:0] wr_data
);
    generate
        if (USE_GOWIN_RAM) begin : g_gowin
            DPB #(
                .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
                .READ_MODE0(1'b0), .READ_MODE1(1'b0),
                .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
                .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
                .RESET_MODE("SYNC")
            ) ram (
                .CLKA(clk), .CLKB(clk),
                .CEA(rd_en), .CEB(wr_en), .OCEA(1'b1), .OCEB(1'b1),
                .WREA(1'b0), .WREB(wr_en), .RESETA(1'b0), .RESETB(1'b0),
                .BLKSELA(3'b000), .BLKSELB(3'b000),
                .ADA({rd_addr,4'b0011}), .ADB({wr_addr,4'b0011}),
                .DIA(16'd0), .DIB(wr_data), .DOA(rd_data), .DOB()
            );
        end else begin : g_rtl
            logic signed [15:0] mem [0:DEPTH-1];
            integer i;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rd_data <= 16'sd0;
                    for (i = 0; i < DEPTH; i = i + 1)
                        mem[i] <= 16'sd0;
                end else begin
                    if (wr_en) mem[wr_addr] <= wr_data;
                    if (rd_en) rd_data <= mem[rd_addr];
                end
            end
        end
    endgenerate

endmodule

module v2_wavetable_loader #(
    parameter integer TABLES = 3,
    parameter integer SAMPLES = 1024,
    parameter integer USE_GOWIN_RAM = 0
) (
    input logic clk,
    input logic rst_n,
    input logic wt_write_valid,
    output logic wt_write_ready,
    input logic [1:0] wt_table,
    input logic [9:0] wt_index,
    // Pulse for one clock when the host writes WT_INDEX.  The uploader owns the
    // write pointer from then on: every accepted WT_DATA advances it, which is
    // what docs/v2-fpga-contract-2026-10-25.md:95-97 requires ("Every WT_DATA
    // write stores ... and then increments the index modulo 1024").
    input logic wt_index_load,
    input logic signed [15:0] wt_write_sample,
    input logic wt_crc_valid,
    input logic [15:0] wt_expected_crc,
    input logic wt_apply_valid,
    output logic wt_apply_ready,
    input logic [1:0] wt_apply_table,
    // APPLY payload version (from the APPLY command itself)
    input logic [15:0] wt_apply_version,
    // WT_VERSION register value, so the uploader can enforce the three-way match
    // APPLY payload == WT_VERSION == active version (contract lines 103-106).
    input logic [15:0] wt_version_reg,
    input logic loop_boundary,
    input logic idle,
    input logic [1:0] wt_read_table,
    input logic [9:0] wt_read_index,
    output logic signed [15:0] wt_read_sample,
    output logic wt_active_valid,
    output logic wt_shadow_valid,
    output logic wt_apply_busy,
    output logic wt_crc_error,
    output logic [15:0] wt_active_version,
    output logic [1:0] wt_active_table,
    // Read-only debug observability.  The top connects these to the CSR space only
    // when V2_DEBUG_CSR is non-zero.
    output logic [9:0]  dbg_wr_ptr,
    output logic [5:0]  dbg_covered_count,
    output logic [31:0] dbg_covered,
    output logic        dbg_shadow_open,
    output logic        dbg_table_complete,
    output logic [31:0] dbg_accepted,
    output logic [4:0]  dbg_last_low5,
    output logic [1:0]  dbg_wt_table,
    output logic        dbg_active_bank,
    // one quantity per register (see docs/parallel): state, flags and counters
    output logic [1:0]  dbg_state,
    output logic        dbg_apply_busy,
    output logic        dbg_crc_error,
    output logic [1:0]  dbg_read_table,
    output logic [2:0]  dbg_bank_bits,
    output logic [9:0]  dbg_read_index,
    output logic [31:0] dbg_rejected,
    // Apply and CRC observability.
    output logic [15:0] dbg_crc_final_captured,
    output logic [1:0]  dbg_apply_reject_reason,
    output logic [15:0] dbg_expected_crc_captured,
    output logic [15:0] dbg_apply_version_seen,
    // Functional completion handshake: one pulse when this APPLY resolves, with the
    // outcome and reason, so the top can answer with this transaction's result
    // instead of a sticky flag left over from an earlier one.
    output logic       wt_apply_done,
    output logic       wt_apply_ok,
    output logic [1:0] wt_apply_reason
);

    // Block coverage assumes the table is a whole number of 32-sample blocks.
    // Synthesis ignores this initial block; simulation stops if it is violated.
    initial begin
        if (SAMPLES % 32 != 0) begin
            $display("FATAL: SAMPLES (%0d) is not a multiple of the 32-sample block size", SAMPLES);
            $finish;
        end
    end

    typedef enum logic [1:0] { S_IDLE, S_CRC, S_WAIT } state_t;
    // Coverage is tracked per 32-sample block, not per sample: 3 tables x 2 banks
    // x 32 blocks = 192 bits instead of 6144.  A block counts as covered only
    // when its last sample (pointer low five bits == 31) has been written, so an
    // upload that is interrupted halfway through a block leaves that block
    // unmarked and the table incomplete.
    localparam integer BLOCKS = SAMPLES / 32;
    state_t state;
    logic [TABLES-1:0] active_bank;
    logic [TABLES-1:0] shadow_open;
    logic [BLOCKS-1:0] covered [0:TABLES-1][0:1];
    logic [5:0] covered_count [0:TABLES-1][0:1];
    logic [9:0] wr_ptr;
    logic [31:0] accepted_count;
    logic [4:0]  last_low5;
    logic [31:0] rejected_count;
    logic [15:0] crc_final_captured;
    logic [1:0]  apply_reject_reason;
    logic [15:0] expected_crc_captured;
    logic [15:0] apply_version_seen;
    logic        apply_done_q, apply_ok_q;
    logic [15:0] active_version [0:TABLES-1];
    logic [15:0] expected_crc [0:TABLES-1];
    logic [15:0] crc_acc;
    logic [9:0] crc_index;
    logic [1:0] apply_table_pending;
    logic [15:0] apply_version_pending;
    logic rd_pending;
    logic signed [15:0] mem_rd_data [0:TABLES-1][0:1];
    logic mem_rd_en [0:TABLES-1][0:1];
    logic [9:0] mem_rd_addr [0:TABLES-1][0:1];
    logic mem_wr_en [0:TABLES-1][0:1];
    logic [9:0] mem_wr_addr [0:TABLES-1][0:1];
    logic signed [15:0] mem_wr_data [0:TABLES-1][0:1];
    integer t, b, i;
    integer ct, cb;

    function automatic logic [15:0] crc16_byte(input logic [15:0] crc_in, input logic [7:0] byte_in);
        logic [15:0] crc;
        integer bit_i;
        begin
            crc = crc_in ^ {byte_in, 8'h00};
            for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1)
                crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
            crc16_byte = crc;
        end
    endfunction
    function automatic logic [15:0] crc16_sample(input logic [15:0] crc_in,
                                                  input logic signed [15:0] sample);
        logic [15:0] c;
        begin
            c = crc16_byte(crc_in, sample[15:8]);
            crc16_sample = crc16_byte(c, sample[7:0]);
        end
    endfunction

    function automatic logic table_complete(input logic [1:0] table_id, input logic bank_id);
        table_complete = covered_count[table_id][bank_id] == BLOCKS;
    endfunction

    assign wt_active_table = wt_read_table;
    assign wt_read_sample = (wt_read_table < TABLES)
        ? mem_rd_data[wt_read_table][active_bank[wt_read_table]] : 16'sd0;
    assign wt_active_valid = (wt_read_table < TABLES)
        ? (covered_count[wt_read_table][active_bank[wt_read_table]] == BLOCKS) : 1'b0;
    assign wt_shadow_valid = (wt_read_table < TABLES)
        ? (covered_count[wt_read_table][~active_bank[wt_read_table]] == BLOCKS) : 1'b0;
    assign wt_active_version = (wt_read_table < TABLES) ? active_version[wt_read_table] : 16'd0;
    assign wt_write_ready = rst_n && (state == S_IDLE) &&
                            (wt_table < TABLES) && (wt_index < SAMPLES);
    assign wt_apply_ready = rst_n && (state == S_IDLE) &&
                            (wt_apply_table < TABLES);

    always_comb begin
        for (ct = 0; ct < TABLES; ct = ct + 1) begin
            for (cb = 0; cb < 2; cb = cb + 1) begin
                mem_rd_en[ct][cb] = 1'b0;
                mem_rd_addr[ct][cb] = 10'd0;
                mem_wr_en[ct][cb] = 1'b0;
                mem_wr_addr[ct][cb] = 10'd0;
                mem_wr_data[ct][cb] = 16'sd0;
            end
        end
        if (wt_read_table < TABLES) begin
            mem_rd_en[wt_read_table][active_bank[wt_read_table]] = 1'b1;
            mem_rd_addr[wt_read_table][active_bank[wt_read_table]] = wt_read_index;
        end
        if (wt_write_valid && wt_write_ready) begin
            mem_wr_en[wt_table][~active_bank[wt_table]] = 1'b1;
            mem_wr_addr[wt_table][~active_bank[wt_table]] = wr_ptr;
            mem_wr_data[wt_table][~active_bank[wt_table]] = wt_write_sample;
        end
        if (state == S_CRC) begin
            mem_rd_en[apply_table_pending][~active_bank[apply_table_pending]] = 1'b1;
            mem_rd_addr[apply_table_pending][~active_bank[apply_table_pending]] =
                crc_index + (rd_pending ? 10'd1 : 10'd0);
        end
    end

    generate
        for (genvar gt = 0; gt < TABLES; gt = gt + 1) begin : g_table
            for (genvar gb = 0; gb < 2; gb = gb + 1) begin : g_bank
                v2_wt_mem #(.DEPTH(SAMPLES), .USE_GOWIN_RAM(USE_GOWIN_RAM)) mem (
                    .clk, .rst_n,
                    .rd_en(mem_rd_en[gt][gb]), .rd_addr(mem_rd_addr[gt][gb]),
                    .rd_data(mem_rd_data[gt][gb]),
                    .wr_en(mem_wr_en[gt][gb]), .wr_addr(mem_wr_addr[gt][gb]),
                    .wr_data(mem_wr_data[gt][gb])
                );
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin : state_machine
        logic [15:0] crc_next;
        if (!rst_n) begin
            active_bank <= '0;
            wr_ptr <= 10'd0;
            accepted_count <= 32'd0;
            last_low5 <= 5'd0;
            rejected_count <= 32'd0;
            crc_final_captured <= 16'd0;
            apply_reject_reason <= 2'd0;
            expected_crc_captured <= 16'd0;
            apply_version_seen <= 16'd0;
            apply_done_q <= 1'b0;
            apply_ok_q <= 1'b0;
            shadow_open <= '0;
            wt_apply_busy <= 1'b0;
            wt_crc_error <= 1'b0;
            crc_acc <= 16'hffff;
            crc_index <= 10'd0;
            apply_table_pending <= 2'd0;
            apply_version_pending <= 16'd0;
            rd_pending <= 1'b0;
            state <= S_IDLE;
            for (t = 0; t < TABLES; t = t + 1) begin
                active_version[t] <= 16'd0;
                expected_crc[t] <= 16'hffff;
                for (b = 0; b < 2; b = b + 1)
                    begin
                        covered[t][b] <= {BLOCKS{1'b0}};
                        covered_count[t][b] <= 6'd0;
                    end
            end
        end else begin
            apply_done_q <= 1'b0;   // default: the completion pulse lasts one cycle
            // Upload pointer: loaded by WT_INDEX, advanced by every accepted
            // WT_DATA write.  Ten bits wrap naturally modulo 1024.
            if (wt_write_valid && wt_write_ready) begin
                accepted_count <= accepted_count + 32'd1;
                last_low5 <= wr_ptr[4:0];
            end

            if (wt_write_valid && !wt_write_ready)
                rejected_count <= rejected_count + 32'd1;
            if (wt_index_load)
                wr_ptr <= wt_index;
            else if (wt_write_valid && wt_write_ready)
                wr_ptr <= wr_ptr + 10'd1;

            if (wt_crc_valid && wt_table < TABLES)
                expected_crc[wt_table] <= wt_expected_crc;
            if (wt_write_valid && wt_write_ready) begin
                // Block coverage: mark the block only when its last sample lands
                // (pointer low five bits == 31).  A page that stops early leaves
                // the block unmarked, so an interrupted upload can never make the
                // table look complete.
                if (!shadow_open[wt_table]) begin
                    covered[wt_table][~active_bank[wt_table]] <= {BLOCKS{1'b0}};
                    shadow_open[wt_table] <= 1'b1;
                    if (wr_ptr[4:0] == 5'd31) begin
                        covered[wt_table][~active_bank[wt_table]][wr_ptr[9:5]] <= 1'b1;
                        covered_count[wt_table][~active_bank[wt_table]] <= 6'd1;
                    end else begin
                        covered_count[wt_table][~active_bank[wt_table]] <= 6'd0;
                    end
                end else if (wr_ptr[4:0] == 5'd31) begin
                    covered[wt_table][~active_bank[wt_table]][wr_ptr[9:5]] <= 1'b1;
                    if (!covered[wt_table][~active_bank[wt_table]][wr_ptr[9:5]])
                        covered_count[wt_table][~active_bank[wt_table]] <=
                            covered_count[wt_table][~active_bank[wt_table]] + 6'd1;
                end
            end
            case (state)
                S_IDLE: begin
                    rd_pending <= 1'b0;
                    if (wt_apply_valid && wt_apply_ready) begin
                        apply_version_seen <= wt_apply_version;
                        if (wt_apply_version != active_version[wt_apply_table] ||
                            wt_apply_version != wt_version_reg) begin
                            // Reason 1: the three-way version match failed, so the CRC
                            // engine never ran and the active bank must not change.
                            wt_crc_error <= 1'b1;
                            apply_reject_reason <= 2'd1;
                            apply_done_q <= 1'b1;
                            apply_ok_q <= 1'b0;
                        end else if (!table_complete(wt_apply_table, ~active_bank[wt_apply_table])) begin
                            // Reason 2: coverage incomplete, the CRC engine never ran.
                            wt_crc_error <= 1'b1;
                            apply_reject_reason <= 2'd2;
                            apply_done_q <= 1'b1;
                            apply_ok_q <= 1'b0;
                        end else begin
                            expected_crc_captured <= expected_crc[wt_apply_table];
                            apply_reject_reason <= 2'd0;
                            wt_apply_busy <= 1'b1;
                            apply_table_pending <= wt_apply_table;
                            apply_version_pending <= wt_apply_version;
                            crc_acc <= 16'hffff;
                            crc_index <= 10'd0;
                            state <= S_CRC;
                            wt_crc_error <= 1'b0;
                        end
                    end
                end
                S_CRC: begin
                    if (!rd_pending) begin
                        rd_pending <= 1'b1;
                    end else begin
                        crc_next = crc16_sample(crc_acc,
                            mem_rd_data[apply_table_pending][~active_bank[apply_table_pending]]);
                        if (crc_index == SAMPLES-1) begin
                            rd_pending <= 1'b0;
                            crc_final_captured <= crc_next;   // latch what the comparator saw
                            if (crc_next != expected_crc[apply_table_pending]) begin
                                wt_apply_busy <= 1'b0;
                                wt_crc_error <= 1'b1;
                                apply_reject_reason <= 2'd3;   // engine ran, CRC differed
                                apply_done_q <= 1'b1;
                                apply_ok_q <= 1'b0;
                                state <= S_IDLE;
                            end else begin
                                crc_acc <= crc_next;
                                state <= S_WAIT;
                            end
                        end else begin
                            crc_acc <= crc_next;
                            crc_index <= crc_index + 10'd1;
                        end
                    end
                end
                S_WAIT: begin
                    if (idle || loop_boundary) begin
                        active_bank[apply_table_pending] <= ~active_bank[apply_table_pending];
                        active_version[apply_table_pending] <= apply_version_pending + 16'd1;
                        apply_done_q <= 1'b1;
                        apply_ok_q <= 1'b1;
                        shadow_open[apply_table_pending] <= 1'b0;
                        wt_apply_busy <= 1'b0;
                        wt_crc_error <= 1'b0;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // Debug observability: the CSR space reads these, gated by V2_DEBUG_CSR in the top.
    logic [1:0] dbg_tbl;
    assign dbg_tbl           = (wt_read_table < TABLES) ? wt_read_table : 2'd0;
    assign dbg_wr_ptr        = wr_ptr;
    assign dbg_covered       = covered[dbg_tbl][~active_bank[dbg_tbl]];
    assign dbg_covered_count = covered_count[dbg_tbl][~active_bank[dbg_tbl]];
    assign dbg_shadow_open   = shadow_open[dbg_tbl];
    assign dbg_table_complete= (covered_count[dbg_tbl][~active_bank[dbg_tbl]] == BLOCKS);
    assign dbg_accepted      = accepted_count;
    assign dbg_last_low5     = last_low5;
    assign dbg_wt_table      = dbg_tbl;
    assign dbg_active_bank   = active_bank[dbg_tbl];
    assign dbg_state         = state;
    assign dbg_apply_busy    = wt_apply_busy;
    assign dbg_crc_error     = wt_crc_error;
    assign dbg_read_table    = wt_read_table;
    assign dbg_bank_bits     = active_bank;
    assign dbg_read_index    = wt_read_index;
    assign dbg_rejected      = rejected_count;
    assign dbg_crc_final_captured  = crc_final_captured;
    assign dbg_apply_reject_reason = apply_reject_reason;
    assign dbg_expected_crc_captured = expected_crc_captured;
    assign dbg_apply_version_seen  = apply_version_seen;
    assign wt_apply_done   = apply_done_q;
    assign wt_apply_ok     = apply_ok_q;
    assign wt_apply_reason = apply_reject_reason;
endmodule
