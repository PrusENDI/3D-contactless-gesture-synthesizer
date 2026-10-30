// Deterministic GW5A state bank for the V2 voice engine.
//
// Port A is the registered scan read. Port B is the single serialized
// writeback/event port. Callers must arbitrate rd_en and wr_en so that a
// state word is not written by two independent paths in one cycle.
module v2_voice_state_bank #(
    parameter integer WIDTH = 208,
    parameter integer USE_GOWIN_RAM = 0
) (
    input  logic         clk,
    input  logic         rd_en,
    input  logic [4:0]   rd_addr,
    output logic [WIDTH-1:0] rd_data,
    input  logic         wr_en,
    input  logic [4:0]   wr_addr,
    input  logic [WIDTH-1:0] wr_data
);
    generate
        if (USE_GOWIN_RAM) begin : g_gowin
            // WIDTH bits = independent 16-bit DPB lanes. GW5A DPB
            // uses the upper address bits for the word and low four bits as
            // the byte/bit location within a 16-bit lane.
            for (genvar lane = 0; lane < WIDTH/16; lane = lane + 1) begin : g_lane
                DPB #(
                    .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
                    .READ_MODE0(1'b0), .READ_MODE1(1'b0),
                    .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
                    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
                    .RESET_MODE("SYNC")
                ) ram (
                    .CLKA(clk), .CLKB(clk),
                    .CEA(rd_en), .CEB(wr_en),
                    .OCEA(1'b1), .OCEB(1'b1),
                    .WREA(1'b0), .WREB(wr_en),
                    .RESETA(1'b0), .RESETB(1'b0),
                    .BLKSELA(3'b000), .BLKSELB(3'b000),
                    .ADA({5'b00000, rd_addr, 4'b0011}),
                    .ADB({5'b00000, wr_addr, 4'b0011}),
                    .DIA(16'd0), .DIB(wr_data[lane*16 +: 16]),
                    .DOA(rd_data[lane*16 +: 16]), .DOB()
                );
            end
        end else begin : g_rtl
            logic [WIDTH-1:0] mem [0:31];
            always_ff @(posedge clk) begin
                if (wr_en)
                    mem[wr_addr] <= wr_data;
                if (rd_en)
                    rd_data <= mem[rd_addr];
            end
        end
    endgenerate
endmodule
