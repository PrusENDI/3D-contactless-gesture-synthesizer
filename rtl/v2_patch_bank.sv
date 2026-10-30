// V2 indexed patch shadow/active bank.
//
// Each family/track/index is encoded into a 10-bit address and stored in two
// 16-bit DPB lanes. Upload writes only the shadow bank. APPLY first scans the
// shadow bank for CRC16 and then copies it into the active bank only at idle or
// a loop boundary. The explicit DPB implementation prevents a 2-bank
// 1024x32-bit patch store from becoming a large register array.
module v2_patch_bank #(
    parameter integer USE_GOWIN_RAM = 0
) (
    input logic clk, input logic rst_n,
    input logic [1:0] select_family, input logic [2:0] select_track,
    input logic [7:0] select_index,
    input logic write_valid, output logic write_ready, input logic signed [31:0] write_value,
    output logic signed [31:0] active_value,
    output logic signed [31:0] shadow_value,
    input logic crc_valid, input logic [15:0] expected_crc,
    input logic apply_valid, output logic apply_ready, input logic [15:0] expected_version,
    input logic idle, input logic loop_boundary,
    output logic [15:0] active_version, output logic shadow_dirty,
    output logic crc_ok, output logic apply_busy, output logic [7:0] last_error
);
    import v2_contract_pkg::*;

    typedef enum logic [1:0] { S_IDLE, S_CRC, S_WAIT, S_COPY } state_t;
    state_t state;
    logic [15:0] shadow_crc;
    logic [5:0] scan_index, copy_index;
    logic [5:0] pending_count;
    logic [1:0] pending_family;
    logic [2:0] pending_track;
    logic [15:0] crc_acc;
    logic rd_pending;
    logic [31:0] covered [0:3][0:7];

    logic [31:0] shadow_rd_data, active_rd_data;
    logic [9:0] shadow_rd_addr, active_rd_addr;
    logic shadow_rd_en, active_rd_en;
    logic shadow_wr_en, active_wr_en;
    logic [9:0] shadow_wr_addr, active_wr_addr;
    logic [31:0] shadow_wr_data, active_wr_data;

    function automatic integer param_count(input logic [1:0] family);
        case (family)
          V2_FAMILY_PATCH: param_count = 20;
          V2_FAMILY_CALIBRATION: param_count = 15;
          V2_FAMILY_RULE: param_count = 7;
          V2_FAMILY_CURSOR: param_count = 5;
          default: param_count = 0;
        endcase
    endfunction

    function automatic logic value_valid(input logic [1:0] family, input logic [2:0] track,
                                         input logic [7:0] index, input logic signed [31:0] value);
        value_valid = v2_patch_value_valid(family, track, index, value);
    endfunction

    function automatic logic [9:0] make_addr(input logic [1:0] family,
                                              input logic [2:0] track,
                                              input logic [7:0] index);
        make_addr = {family, track, index[4:0]};
    endfunction

    function automatic logic [15:0] crc16_byte(input logic [15:0] crc_in, input logic [7:0] byte_in);
        logic [15:0] crc;
        integer bit_i;
        begin
            crc = crc_in ^ {byte_in,8'h00};
            for (bit_i=0; bit_i<8; bit_i=bit_i+1)
                crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
            crc16_byte = crc;
        end
    endfunction

    function automatic logic [15:0] crc32(input logic [15:0] crc_in, input logic [31:0] value);
        logic [15:0] c;
        begin
            c = crc16_byte(crc_in,value[31:24]);
            c = crc16_byte(c,value[23:16]);
            c = crc16_byte(c,value[15:8]);
            crc32 = crc16_byte(c,value[7:0]);
        end
    endfunction

    function automatic logic coverage_complete(input logic [1:0] family, input logic [2:0] track);
        integer j;
        begin
            coverage_complete = 1'b1;
            for (j = 0; j < 32; j = j + 1)
                if (j < param_count(family) && !covered[family][track][j])
                    coverage_complete = 1'b0;
        end
    endfunction

    logic shadow_user_rd_en;
    assign active_rd_en = rst_n && (select_family < 4) &&
                          (select_track < 8) && (select_index < 32);
    assign active_rd_addr = make_addr(select_family, select_track, select_index);
    assign active_value = active_rd_en ? active_rd_data : 32'sd0;
    assign shadow_user_rd_en = rst_n && (state == S_IDLE) &&
                               (select_family < 4) && (select_track < 8) &&
                               (select_index < 32);
    assign shadow_value = shadow_user_rd_en ? shadow_rd_data : 32'sd0;

    assign write_ready = rst_n && (state == S_IDLE) &&
                         (select_family < 4) && (select_track < 8) &&
                         (select_index < 32) &&
                         value_valid(select_family, select_track, select_index, write_value);
    assign apply_ready = rst_n && (state == S_IDLE) &&
                         (select_family < 4) && (select_track < 8) &&
                         (select_index < 32);
    assign shadow_wr_en = write_valid && write_ready;
    assign shadow_wr_addr = make_addr(select_family, select_track, select_index);
    assign shadow_wr_data = write_value;
    assign shadow_rd_en = shadow_user_rd_en || (state == S_CRC) || (state == S_COPY);
    assign shadow_rd_addr = (state == S_CRC) ?
                            make_addr(pending_family, pending_track,
                                      scan_index + (rd_pending ? 1'b1 : 1'b0)) :
                            (state == S_COPY) ?
                            make_addr(pending_family, pending_track,
                                      copy_index + (rd_pending ? 1'b1 : 1'b0)) :
                            make_addr(select_family, select_track, select_index);
    assign active_wr_en = (state == S_COPY) && rd_pending;
    assign active_wr_addr = make_addr(pending_family, pending_track, copy_index);
    assign active_wr_data = shadow_rd_data;

    generate
        if (USE_GOWIN_RAM) begin : g_gowin
            for (genvar lane = 0; lane < 2; lane = lane + 1) begin : g_lane
                DPB #(
                    .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
                    .READ_MODE0(1'b0), .READ_MODE1(1'b0),
                    .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
                    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
                    .RESET_MODE("SYNC")
                ) shadow_ram (
                    .CLKA(clk), .CLKB(clk),
                    .CEA(shadow_rd_en), .CEB(shadow_wr_en), .OCEA(1'b1), .OCEB(1'b1),
                    .WREA(1'b0), .WREB(shadow_wr_en), .RESETA(1'b0), .RESETB(1'b0),
                    .BLKSELA(3'b000), .BLKSELB(3'b000),
                    .ADA({shadow_rd_addr,4'b0011}), .ADB({shadow_wr_addr,4'b0011}),
                    .DIA(16'd0), .DIB(shadow_wr_data[lane*16 +: 16]),
                    .DOA(shadow_rd_data[lane*16 +: 16]), .DOB()
                );
                DPB #(
                    .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
                    .READ_MODE0(1'b0), .READ_MODE1(1'b0),
                    .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
                    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
                    .RESET_MODE("SYNC")
                ) active_ram (
                    .CLKA(clk), .CLKB(clk),
                    .CEA(active_rd_en), .CEB(active_wr_en), .OCEA(1'b1), .OCEB(1'b1),
                    .WREA(1'b0), .WREB(active_wr_en), .RESETA(1'b0), .RESETB(1'b0),
                    .BLKSELA(3'b000), .BLKSELB(3'b000),
                    .ADA({active_rd_addr,4'b0011}), .ADB({active_wr_addr,4'b0011}),
                    .DIA(16'd0), .DIB(active_wr_data[lane*16 +: 16]),
                    .DOA(active_rd_data[lane*16 +: 16]), .DOB()
                );
            end
        end else begin : g_rtl
            logic [31:0] shadow_mem [0:1023];
            logic [31:0] active_mem [0:1023];
            always_ff @(posedge clk) begin
                if (shadow_wr_en) shadow_mem[shadow_wr_addr] <= shadow_wr_data;
                if (shadow_rd_en) shadow_rd_data <= shadow_mem[shadow_rd_addr];
                if (active_wr_en) active_mem[active_wr_addr] <= active_wr_data;
                if (active_rd_en) active_rd_data <= active_mem[active_rd_addr];
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin : state_machine
        logic [15:0] crc_next;
        if (!rst_n) begin
            state <= S_IDLE;
            shadow_crc <= 16'hffff;
            scan_index <= 0;
            copy_index <= 0;
            pending_count <= 0;
            pending_family <= 0;
            pending_track <= 0;
            crc_acc <= 16'hffff;
            rd_pending <= 1'b0;
            active_version <= 16'd0;
            shadow_dirty <= 1'b0;
            crc_ok <= 1'b0;
            apply_busy <= 1'b0;
            last_error <= 8'd0;
            for (integer f = 0; f < 4; f = f + 1)
                for (integer t = 0; t < 8; t = t + 1)
                    covered[f][t] <= 32'd0;
        end else begin
            if (crc_valid && select_family < 4 && select_track < 8)
                shadow_crc <= expected_crc;
            if (shadow_wr_en) begin
                covered[select_family][select_track][select_index] <= 1'b1;
                shadow_dirty <= 1'b1;
                crc_ok <= 1'b0;
                last_error <= 8'd0;
            end

            case (state)
                S_IDLE: begin
                    rd_pending <= 1'b0;
                    if (apply_valid && apply_ready) begin
                        if (expected_version != active_version) begin
                            last_error <= 8'd2;
                            crc_ok <= 1'b0;
                        end else if (!coverage_complete(select_family, select_track)) begin
                            last_error <= V2_ERR_INCOMPLETE;
                            crc_ok <= 1'b0;
                        end else begin
                            state <= S_CRC;
                            apply_busy <= 1'b1;
                            pending_family <= select_family;
                            pending_track <= select_track;
                            pending_count <= param_count(select_family);
                            scan_index <= 0;
                            crc_acc <= 16'hffff;
                            last_error <= 8'd0;
                        end
                    end
                end
                S_CRC: begin
                    if (!rd_pending) begin
                        rd_pending <= 1'b1;
                    end else begin
                        crc_next = crc32(crc_acc, shadow_rd_data);
                        if (scan_index == pending_count - 1'b1) begin
                            rd_pending <= 1'b0;
                            if (crc_next != shadow_crc) begin
                                state <= S_IDLE;
                                apply_busy <= 1'b0;
                                crc_ok <= 1'b0;
                                last_error <= V2_ERR_WT_CRC;
                            end else begin
                                state <= S_WAIT;
                                crc_acc <= crc_next;
                            end
                        end else begin
                            crc_acc <= crc_next;
                            scan_index <= scan_index + 1'b1;
                        end
                    end
                end
                S_WAIT: begin
                    if (idle || loop_boundary) begin
                        state <= S_COPY;
                        copy_index <= 0;
                        rd_pending <= 1'b0;
                    end
                end
                S_COPY: begin
                    if (!rd_pending) begin
                        rd_pending <= 1'b1;
                    end else if (copy_index == pending_count - 1'b1) begin
                        active_version <= active_version + 1'b1;
                        shadow_dirty <= 1'b0;
                        crc_ok <= 1'b1;
                        apply_busy <= 1'b0;
                        last_error <= 8'd0;
                        state <= S_IDLE;
                        rd_pending <= 1'b0;
                    end else begin
                        copy_index <= copy_index + 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
