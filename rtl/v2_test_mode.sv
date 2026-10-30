// Independent V2 N-tone observability test mode.
// It is deliberately separate from LIVE/LOOP and never consumes EventTable data.
module v2_test_mode #(
    parameter integer MAX_TONES = 32
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   sample_ce,
    input  logic                   csr_valid,
    input  logic                   csr_write,
    input  logic [7:0]             csr_addr,
    input  logic [31:0]            csr_wdata,
    output logic                   csr_ready,
    output logic                   csr_rvalid,
    output logic [31:0]            csr_rdata,
    output logic signed [15:0]     mixed_sample,
    output logic                   sample_valid,
    output logic [31:0]            active_bitmap,
    output logic [31:0]            sample_counter,
    output logic                   test_active,
    output logic                   fault
);
    import v2_contract_pkg::*;

    logic [5:0] tone_count;
    logic [31:0] phase [0:MAX_TONES-1];
    integer i;
    integer tone_index;
    logic signed [31:0] mix_acc;

    assign csr_ready = rst_n;

    function automatic logic [31:0] tone_phase_increment(input integer tone);
        begin
            case (tone)
            1: tone_phase_increment = 32'd19685267;
            2: tone_phase_increment = 32'd39370534;
            3: tone_phase_increment = 32'd59055800;
            4: tone_phase_increment = 32'd78741067;
            5: tone_phase_increment = 32'd98426334;
            6: tone_phase_increment = 32'd118111601;
            7: tone_phase_increment = 32'd137796867;
            8: tone_phase_increment = 32'd157482134;
            9: tone_phase_increment = 32'd177167401;
            10: tone_phase_increment = 32'd196852668;
            11: tone_phase_increment = 32'd216537935;
            12: tone_phase_increment = 32'd236223201;
            13: tone_phase_increment = 32'd255908468;
            14: tone_phase_increment = 32'd275593735;
            15: tone_phase_increment = 32'd295279002;
            16: tone_phase_increment = 32'd314964268;
            17: tone_phase_increment = 32'd334649535;
            18: tone_phase_increment = 32'd354334802;
            19: tone_phase_increment = 32'd374020069;
            20: tone_phase_increment = 32'd393705335;
            21: tone_phase_increment = 32'd413390602;
            22: tone_phase_increment = 32'd433075869;
            23: tone_phase_increment = 32'd452761136;
            24: tone_phase_increment = 32'd472446403;
            25: tone_phase_increment = 32'd492131669;
            26: tone_phase_increment = 32'd511816936;
            27: tone_phase_increment = 32'd531502203;
            28: tone_phase_increment = 32'd551187470;
            29: tone_phase_increment = 32'd570872736;
            30: tone_phase_increment = 32'd590558003;
            31: tone_phase_increment = 32'd610243270;
            32: tone_phase_increment = 32'd629928537;
                default: tone_phase_increment = 32'd0;
            endcase
        end
    endfunction

    function automatic logic signed [15:0] sine_lut(input logic [7:0] index);
        begin
            case (index)
            8'd0: sine_lut = 16'sd0;
            8'd1: sine_lut = 16'sd804;
            8'd2: sine_lut = 16'sd1608;
            8'd3: sine_lut = 16'sd2410;
            8'd4: sine_lut = 16'sd3212;
            8'd5: sine_lut = 16'sd4011;
            8'd6: sine_lut = 16'sd4808;
            8'd7: sine_lut = 16'sd5602;
            8'd8: sine_lut = 16'sd6393;
            8'd9: sine_lut = 16'sd7179;
            8'd10: sine_lut = 16'sd7962;
            8'd11: sine_lut = 16'sd8739;
            8'd12: sine_lut = 16'sd9512;
            8'd13: sine_lut = 16'sd10278;
            8'd14: sine_lut = 16'sd11039;
            8'd15: sine_lut = 16'sd11793;
            8'd16: sine_lut = 16'sd12539;
            8'd17: sine_lut = 16'sd13279;
            8'd18: sine_lut = 16'sd14010;
            8'd19: sine_lut = 16'sd14732;
            8'd20: sine_lut = 16'sd15446;
            8'd21: sine_lut = 16'sd16151;
            8'd22: sine_lut = 16'sd16846;
            8'd23: sine_lut = 16'sd17530;
            8'd24: sine_lut = 16'sd18204;
            8'd25: sine_lut = 16'sd18868;
            8'd26: sine_lut = 16'sd19519;
            8'd27: sine_lut = 16'sd20159;
            8'd28: sine_lut = 16'sd20787;
            8'd29: sine_lut = 16'sd21403;
            8'd30: sine_lut = 16'sd22005;
            8'd31: sine_lut = 16'sd22594;
            8'd32: sine_lut = 16'sd23170;
            8'd33: sine_lut = 16'sd23731;
            8'd34: sine_lut = 16'sd24279;
            8'd35: sine_lut = 16'sd24811;
            8'd36: sine_lut = 16'sd25329;
            8'd37: sine_lut = 16'sd25832;
            8'd38: sine_lut = 16'sd26319;
            8'd39: sine_lut = 16'sd26790;
            8'd40: sine_lut = 16'sd27245;
            8'd41: sine_lut = 16'sd27683;
            8'd42: sine_lut = 16'sd28105;
            8'd43: sine_lut = 16'sd28510;
            8'd44: sine_lut = 16'sd28898;
            8'd45: sine_lut = 16'sd29268;
            8'd46: sine_lut = 16'sd29621;
            8'd47: sine_lut = 16'sd29956;
            8'd48: sine_lut = 16'sd30273;
            8'd49: sine_lut = 16'sd30571;
            8'd50: sine_lut = 16'sd30852;
            8'd51: sine_lut = 16'sd31113;
            8'd52: sine_lut = 16'sd31356;
            8'd53: sine_lut = 16'sd31580;
            8'd54: sine_lut = 16'sd31785;
            8'd55: sine_lut = 16'sd31971;
            8'd56: sine_lut = 16'sd32137;
            8'd57: sine_lut = 16'sd32285;
            8'd58: sine_lut = 16'sd32412;
            8'd59: sine_lut = 16'sd32521;
            8'd60: sine_lut = 16'sd32609;
            8'd61: sine_lut = 16'sd32678;
            8'd62: sine_lut = 16'sd32728;
            8'd63: sine_lut = 16'sd32757;
            8'd64: sine_lut = 16'sd32767;
            8'd65: sine_lut = 16'sd32757;
            8'd66: sine_lut = 16'sd32728;
            8'd67: sine_lut = 16'sd32678;
            8'd68: sine_lut = 16'sd32609;
            8'd69: sine_lut = 16'sd32521;
            8'd70: sine_lut = 16'sd32412;
            8'd71: sine_lut = 16'sd32285;
            8'd72: sine_lut = 16'sd32137;
            8'd73: sine_lut = 16'sd31971;
            8'd74: sine_lut = 16'sd31785;
            8'd75: sine_lut = 16'sd31580;
            8'd76: sine_lut = 16'sd31356;
            8'd77: sine_lut = 16'sd31113;
            8'd78: sine_lut = 16'sd30852;
            8'd79: sine_lut = 16'sd30571;
            8'd80: sine_lut = 16'sd30273;
            8'd81: sine_lut = 16'sd29956;
            8'd82: sine_lut = 16'sd29621;
            8'd83: sine_lut = 16'sd29268;
            8'd84: sine_lut = 16'sd28898;
            8'd85: sine_lut = 16'sd28510;
            8'd86: sine_lut = 16'sd28105;
            8'd87: sine_lut = 16'sd27683;
            8'd88: sine_lut = 16'sd27245;
            8'd89: sine_lut = 16'sd26790;
            8'd90: sine_lut = 16'sd26319;
            8'd91: sine_lut = 16'sd25832;
            8'd92: sine_lut = 16'sd25329;
            8'd93: sine_lut = 16'sd24811;
            8'd94: sine_lut = 16'sd24279;
            8'd95: sine_lut = 16'sd23731;
            8'd96: sine_lut = 16'sd23170;
            8'd97: sine_lut = 16'sd22594;
            8'd98: sine_lut = 16'sd22005;
            8'd99: sine_lut = 16'sd21403;
            8'd100: sine_lut = 16'sd20787;
            8'd101: sine_lut = 16'sd20159;
            8'd102: sine_lut = 16'sd19519;
            8'd103: sine_lut = 16'sd18868;
            8'd104: sine_lut = 16'sd18204;
            8'd105: sine_lut = 16'sd17530;
            8'd106: sine_lut = 16'sd16846;
            8'd107: sine_lut = 16'sd16151;
            8'd108: sine_lut = 16'sd15446;
            8'd109: sine_lut = 16'sd14732;
            8'd110: sine_lut = 16'sd14010;
            8'd111: sine_lut = 16'sd13279;
            8'd112: sine_lut = 16'sd12539;
            8'd113: sine_lut = 16'sd11793;
            8'd114: sine_lut = 16'sd11039;
            8'd115: sine_lut = 16'sd10278;
            8'd116: sine_lut = 16'sd9512;
            8'd117: sine_lut = 16'sd8739;
            8'd118: sine_lut = 16'sd7962;
            8'd119: sine_lut = 16'sd7179;
            8'd120: sine_lut = 16'sd6393;
            8'd121: sine_lut = 16'sd5602;
            8'd122: sine_lut = 16'sd4808;
            8'd123: sine_lut = 16'sd4011;
            8'd124: sine_lut = 16'sd3212;
            8'd125: sine_lut = 16'sd2410;
            8'd126: sine_lut = 16'sd1608;
            8'd127: sine_lut = 16'sd804;
            8'd128: sine_lut = 16'sd0;
            8'd129: sine_lut = -16'sd804;
            8'd130: sine_lut = -16'sd1608;
            8'd131: sine_lut = -16'sd2410;
            8'd132: sine_lut = -16'sd3212;
            8'd133: sine_lut = -16'sd4011;
            8'd134: sine_lut = -16'sd4808;
            8'd135: sine_lut = -16'sd5602;
            8'd136: sine_lut = -16'sd6393;
            8'd137: sine_lut = -16'sd7179;
            8'd138: sine_lut = -16'sd7962;
            8'd139: sine_lut = -16'sd8739;
            8'd140: sine_lut = -16'sd9512;
            8'd141: sine_lut = -16'sd10278;
            8'd142: sine_lut = -16'sd11039;
            8'd143: sine_lut = -16'sd11793;
            8'd144: sine_lut = -16'sd12539;
            8'd145: sine_lut = -16'sd13279;
            8'd146: sine_lut = -16'sd14010;
            8'd147: sine_lut = -16'sd14732;
            8'd148: sine_lut = -16'sd15446;
            8'd149: sine_lut = -16'sd16151;
            8'd150: sine_lut = -16'sd16846;
            8'd151: sine_lut = -16'sd17530;
            8'd152: sine_lut = -16'sd18204;
            8'd153: sine_lut = -16'sd18868;
            8'd154: sine_lut = -16'sd19519;
            8'd155: sine_lut = -16'sd20159;
            8'd156: sine_lut = -16'sd20787;
            8'd157: sine_lut = -16'sd21403;
            8'd158: sine_lut = -16'sd22005;
            8'd159: sine_lut = -16'sd22594;
            8'd160: sine_lut = -16'sd23170;
            8'd161: sine_lut = -16'sd23731;
            8'd162: sine_lut = -16'sd24279;
            8'd163: sine_lut = -16'sd24811;
            8'd164: sine_lut = -16'sd25329;
            8'd165: sine_lut = -16'sd25832;
            8'd166: sine_lut = -16'sd26319;
            8'd167: sine_lut = -16'sd26790;
            8'd168: sine_lut = -16'sd27245;
            8'd169: sine_lut = -16'sd27683;
            8'd170: sine_lut = -16'sd28105;
            8'd171: sine_lut = -16'sd28510;
            8'd172: sine_lut = -16'sd28898;
            8'd173: sine_lut = -16'sd29268;
            8'd174: sine_lut = -16'sd29621;
            8'd175: sine_lut = -16'sd29956;
            8'd176: sine_lut = -16'sd30273;
            8'd177: sine_lut = -16'sd30571;
            8'd178: sine_lut = -16'sd30852;
            8'd179: sine_lut = -16'sd31113;
            8'd180: sine_lut = -16'sd31356;
            8'd181: sine_lut = -16'sd31580;
            8'd182: sine_lut = -16'sd31785;
            8'd183: sine_lut = -16'sd31971;
            8'd184: sine_lut = -16'sd32137;
            8'd185: sine_lut = -16'sd32285;
            8'd186: sine_lut = -16'sd32412;
            8'd187: sine_lut = -16'sd32521;
            8'd188: sine_lut = -16'sd32609;
            8'd189: sine_lut = -16'sd32678;
            8'd190: sine_lut = -16'sd32728;
            8'd191: sine_lut = -16'sd32757;
            8'd192: sine_lut = -16'sd32767;
            8'd193: sine_lut = -16'sd32757;
            8'd194: sine_lut = -16'sd32728;
            8'd195: sine_lut = -16'sd32678;
            8'd196: sine_lut = -16'sd32609;
            8'd197: sine_lut = -16'sd32521;
            8'd198: sine_lut = -16'sd32412;
            8'd199: sine_lut = -16'sd32285;
            8'd200: sine_lut = -16'sd32137;
            8'd201: sine_lut = -16'sd31971;
            8'd202: sine_lut = -16'sd31785;
            8'd203: sine_lut = -16'sd31580;
            8'd204: sine_lut = -16'sd31356;
            8'd205: sine_lut = -16'sd31113;
            8'd206: sine_lut = -16'sd30852;
            8'd207: sine_lut = -16'sd30571;
            8'd208: sine_lut = -16'sd30273;
            8'd209: sine_lut = -16'sd29956;
            8'd210: sine_lut = -16'sd29621;
            8'd211: sine_lut = -16'sd29268;
            8'd212: sine_lut = -16'sd28898;
            8'd213: sine_lut = -16'sd28510;
            8'd214: sine_lut = -16'sd28105;
            8'd215: sine_lut = -16'sd27683;
            8'd216: sine_lut = -16'sd27245;
            8'd217: sine_lut = -16'sd26790;
            8'd218: sine_lut = -16'sd26319;
            8'd219: sine_lut = -16'sd25832;
            8'd220: sine_lut = -16'sd25329;
            8'd221: sine_lut = -16'sd24811;
            8'd222: sine_lut = -16'sd24279;
            8'd223: sine_lut = -16'sd23731;
            8'd224: sine_lut = -16'sd23170;
            8'd225: sine_lut = -16'sd22594;
            8'd226: sine_lut = -16'sd22005;
            8'd227: sine_lut = -16'sd21403;
            8'd228: sine_lut = -16'sd20787;
            8'd229: sine_lut = -16'sd20159;
            8'd230: sine_lut = -16'sd19519;
            8'd231: sine_lut = -16'sd18868;
            8'd232: sine_lut = -16'sd18204;
            8'd233: sine_lut = -16'sd17530;
            8'd234: sine_lut = -16'sd16846;
            8'd235: sine_lut = -16'sd16151;
            8'd236: sine_lut = -16'sd15446;
            8'd237: sine_lut = -16'sd14732;
            8'd238: sine_lut = -16'sd14010;
            8'd239: sine_lut = -16'sd13279;
            8'd240: sine_lut = -16'sd12539;
            8'd241: sine_lut = -16'sd11793;
            8'd242: sine_lut = -16'sd11039;
            8'd243: sine_lut = -16'sd10278;
            8'd244: sine_lut = -16'sd9512;
            8'd245: sine_lut = -16'sd8739;
            8'd246: sine_lut = -16'sd7962;
            8'd247: sine_lut = -16'sd7179;
            8'd248: sine_lut = -16'sd6393;
            8'd249: sine_lut = -16'sd5602;
            8'd250: sine_lut = -16'sd4808;
            8'd251: sine_lut = -16'sd4011;
            8'd252: sine_lut = -16'sd3212;
            8'd253: sine_lut = -16'sd2410;
            8'd254: sine_lut = -16'sd1608;
            8'd255: sine_lut = -16'sd804;
                default: sine_lut = 16'sd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] bitmap_for_count(input logic [5:0] count);
        begin
            if (count == 0) bitmap_for_count = 32'd0;
            else if (count >= 32) bitmap_for_count = 32'hFFFFFFFF;
            else bitmap_for_count = (32'hFFFFFFFF >> (32 - count));
        end
    endfunction

    function automatic logic signed [15:0] saturate(input logic signed [31:0] value);
        begin
            if (value > 32'sd32767) saturate = 16'sh7FFF;
            else if (value < -32'sd32768) saturate = -16'sd32768;
            else saturate = value[15:0];
        end
    endfunction

    // One sine lookup per clock.  A 48 kHz frame is 2083 clocks at 100 MHz, so
    // evaluating the 32 tones serially costs ~33 clocks and lets the 256-entry
    // table exist once instead of once per tone.
    logic [5:0]        ser_index;
    logic              ser_busy;
    logic signed [31:0] ser_acc;
    logic signed [15:0] ser_term;

    always_comb begin
        active_bitmap = test_active ? bitmap_for_count(tone_count) : 32'd0;
    end

    always_comb begin
        ser_term = sine_lut(phase[ser_index][31:24]);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tone_count <= 6'd0;
            test_active <= 1'b0;
            fault <= 1'b0;
            csr_rvalid <= 1'b0;
            csr_rdata <= 32'd0;
            mixed_sample <= 16'sd0;
            sample_valid <= 1'b0;
            sample_counter <= 32'd0;
            ser_busy <= 1'b0; ser_index <= 6'd0; ser_acc <= 32'sd0;
            for (i = 0; i < MAX_TONES; i = i + 1) phase[i] <= 32'd0;
        end else begin
            csr_rvalid <= 1'b0;
            sample_valid <= 1'b0;

            if (csr_valid && csr_ready && (csr_addr >= V2_CSR_TEST_SELECT) &&
                (csr_addr <= (V2_CSR_TEST_SELECT + 8'h0F))) begin
                if (csr_write) begin
                    if (csr_wdata[7:0] == V2_TEST_SELECTOR_N_TONE) begin
                        if (csr_wdata[31:8] == 0) begin
                            tone_count <= 6'd0;
                            test_active <= 1'b0;
                        end else if (csr_wdata[31:8] <= V2_TEST_N_TONE_COUNT_MAX) begin
                            tone_count <= csr_wdata[13:8];
                            test_active <= 1'b1;
                        end else begin
                            fault <= 1'b1;
                        end
                        sample_counter <= 32'd0;
            ser_busy <= 1'b0; ser_index <= 6'd0; ser_acc <= 32'sd0;
                        for (i = 0; i < MAX_TONES; i = i + 1) phase[i] <= 32'd0;
                    end else begin
                        fault <= 1'b1;
                    end
                end else begin
                    csr_rvalid <= 1'b1;
                    csr_rdata <= {tone_count, 18'd0, V2_TEST_SELECTOR_N_TONE};
                end
            end

            // Serial frame engine: start on the sample boundary, accumulate one
            // tone per clock, then publish the frame and advance the phases.
            if (sample_ce && !ser_busy) begin
                ser_acc   <= 32'sd0;
                ser_index <= 6'd0;
                if (test_active) begin
                    ser_busy <= 1'b1;
                end else begin
                    mixed_sample <= 16'sd0;
                    sample_valid <= 1'b0;
                end
            end else if (ser_busy) begin
                if (ser_index >= tone_count) begin
                    mixed_sample   <= saturate(ser_acc);
                    sample_valid   <= 1'b1;
                    sample_counter <= sample_counter + 32'd1;
                    for (i = 0; i < MAX_TONES; i = i + 1)
                        if (i < tone_count) phase[i] <= phase[i] + tone_phase_increment(i + 1);
                    ser_busy <= 1'b0;
                end else begin
                    ser_acc   <= ser_acc + ($signed(ser_term) >>> 5);
                    ser_index <= ser_index + 6'd1;
                end
            end else begin
                sample_valid <= 1'b0;
            end
        end
    end
endmodule
