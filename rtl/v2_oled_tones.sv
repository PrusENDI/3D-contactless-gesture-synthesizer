// Combinational picture for the demo panel: "N=xx" on top, 32 staircase bars
// below.  No memory at all -- this is the whole point, see the design (4.3).
//
// SSD1306 page addressing: one byte is 8 vertical pixels of one column, bit 0 is
// the top pixel of the page, page p owns rows 8p..8p+7.
//
// Layout
//   rows  0..13   text "N=xx" (5x7 glyphs scaled 2x, 16 px pitch from column 32)
//   rows 16..63   32 bars, 3 px wide at a 4 px pitch; bar k is k px tall and is
//                 lit while k <= tone_count (k counts from 1)
//
// The 5x7 glyphs are the classic column-major table: byte c is column c, bit r
// is row r, bit 0 on top.
module v2_oled_tones (
    input  logic [9:0] img_addr,      // {page[2:0], col[6:0]}
    input  logic [5:0] tone_count,
    output logic [7:0] img_data
);
    logic [2:0] page;
    logic [6:0] col;
    assign page = img_addr[9:7];
    assign col  = img_addr[6:0];

    // ---------------------------------------------------------------- glyphs --
    // Forty bits per glyph: column 0 in the most significant byte.
    function automatic logic [39:0] glyph(input logic [7:0] ch);
        case (ch)
            8'h4E: glyph = 40'h7F_02_0C_02_7F;   // 'N'
            8'h3D: glyph = 40'h14_14_14_14_14;   // '='
            8'h30: glyph = 40'h3E_51_49_45_3E;   // '0'
            8'h31: glyph = 40'h00_42_7F_40_00;   // '1'
            8'h32: glyph = 40'h42_61_51_49_46;   // '2'
            8'h33: glyph = 40'h21_41_45_4B_31;   // '3'
            8'h34: glyph = 40'h18_14_12_7F_10;   // '4'
            8'h35: glyph = 40'h27_45_45_45_39;   // '5'
            8'h36: glyph = 40'h3C_4A_49_49_30;   // '6'
            8'h37: glyph = 40'h01_71_09_05_03;   // '7'
            8'h38: glyph = 40'h36_49_49_49_36;   // '8'
            8'h39: glyph = 40'h06_49_49_29_1E;   // '9'
            default: glyph = 40'h00_00_00_00_00; // ' '
        endcase
    endfunction

    logic [3:0] tens;
    logic [3:0] units;
    always_comb begin
        if (tone_count >= 6'd30)      tens = 4'd3;
        else if (tone_count >= 6'd20) tens = 4'd2;
        else if (tone_count >= 6'd10) tens = 4'd1;
        else                          tens = 4'd0;
        units = 4'(tone_count - 6'((tens << 3) + (tens << 1)));
    end

    // Character at each of the four 16 px cells: 'N', '=', tens, units.
    function automatic logic [7:0] cell_char(input logic [2:0] index);
        case (index)
            3'd0:    cell_char = 8'h4E;                       // 'N'
            3'd1:    cell_char = 8'h3D;                       // '='
            3'd2:    cell_char = (tens == 4'd0) ? 8'h20 : (8'h30 + {4'd0, tens});
            default: cell_char = 8'h30 + {4'd0, units};
        endcase
    endfunction

    // One pixel of the text area.  Rows 14..15 fall through as 0 because every
    // glyph byte has bit 7 clear.
    function automatic logic text_pixel(input logic [6:0] c, input logic [6:0] row);
        logic [7:0]  ch;
        logic [3:0]  inner;
        logic [2:0]  index;
        logic [2:0]  gcol;
        logic [39:0] g;
        logic [7:0]  gbyte;
        begin
            text_pixel = 1'b0;
            if ((c >= 7'd32) && (c <= 7'd95)) begin
                inner = c[3:0];
                if (inner < 4'd10) begin
                    index = 3'(c[6:4] - 3'd2);
                    ch    = cell_char(index);
                    gcol  = 3'(inner >> 1);
                    g     = glyph(ch);
                    gbyte = 8'(g >> (8 * (4 - gcol)));
                    text_pixel = (gbyte >> 3'(row >> 1)) & 1'b1;
                end
            end
        end
    endfunction

    // One pixel of the bar area.  Slot s (0..31) owns columns 4s..4s+2; bar s is
    // s+1 pixels tall, anchored to the bottom row 63.
    function automatic logic bar_pixel(input logic [6:0] c, input logic [6:0] row);
        logic [5:0] slot;
        begin
            slot = 6'(c >> 2);
            bar_pixel = (c[1:0] != 2'd3) && (slot < tone_count) &&
                        (row >= (7'd63 - {1'b0, slot}));
        end
    endfunction

    always_comb begin
        for (int b = 0; b < 8; b++) begin
            logic [6:0] row;
            row = {page, 3'd0} + 7'(b);
            if (row < 7'd16) img_data[b] = text_pixel(col, row);
            else             img_data[b] = bar_pixel(col, row);
        end
    end
endmodule
