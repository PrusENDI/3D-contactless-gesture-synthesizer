// One-shot SSD1306 writer.
//
// After reset this module holds the panel in reset, waits for it to wake, sends
// the 25-byte initialisation sequence, then pushes the whole 1024-byte frame as
// 8 pages (page address, low column, high column, 128 data bytes).  Then it
// stops: sck never toggles again, so the design costs nothing in steady state.
//
// SPI is mode 0 (clock idle low, data sampled on the rising edge), MSB first,
// and slow: SPI_DIV divides the board clock, there is no second clock domain.
// At 50 MHz and SPI_DIV = 50 that is 1 MHz, and the frame takes about 8.6 ms.
//
// The frame lives outside this module (`v2_oled_image`, one BSRAM), so the
// address is combinational and the data is one cycle behind it; one byte lasts
// SPI_DIV*8 clocks, so that latency is never visible.
module v2_oled_static #(
    // Clocks per SPI bit.  50 at 50 MHz = 1 MHz.
    parameter integer SPI_DIV = 50,
    // res_n held low.  5000 at 50 MHz = 100 us (the panel wants >= 3 us).
    parameter integer RESET_CYCLES = 5000,
    // Quiet time after reset release before the first command.  The SSD1306
    // datasheet asks for 100 ms, which is 5_000_000 clocks at 50 MHz; a
    // testbench overrides this to a few cycles.
    parameter integer WAKE_CYCLES = 5_000_000
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,        // level: leave IDLE once high
    input  logic [7:0] img_data,     // framebuffer byte for img_addr
    output logic [9:0] img_addr,
    output logic       sck,
    output logic       mosi,
    output logic       dc,
    output logic       cs_n,
    output logic       res_n,
    output logic       blk,
    output logic       busy,
    output logic       done
);
    // The SSD1306 initialisation, verbatim from the spec (25 bytes):
    // display off, clock, multiplex, offset, start line, charge pump, page
    // addressing, segment remap, COM scan, COM pins, contrast, precharge,
    // VCOMH, RAM content, normal, display on.
    localparam integer INIT_BYTES = 25;

    function automatic logic [7:0] init_byte(input logic [4:0] index);
        case (index)
            5'd0:  init_byte = 8'hAE;
            5'd1:  init_byte = 8'hD5;
            5'd2:  init_byte = 8'h80;
            5'd3:  init_byte = 8'hA8;
            5'd4:  init_byte = 8'h3F;
            5'd5:  init_byte = 8'hD3;
            5'd6:  init_byte = 8'h00;
            5'd7:  init_byte = 8'h40;
            5'd8:  init_byte = 8'h8D;
            5'd9:  init_byte = 8'h14;
            5'd10: init_byte = 8'h20;
            5'd11: init_byte = 8'h02;   // page addressing
            5'd12: init_byte = 8'hA1;   // segment remap: column 0 on the left
            5'd13: init_byte = 8'hC8;   // COM scan downwards
            5'd14: init_byte = 8'hDA;
            5'd15: init_byte = 8'h12;
            5'd16: init_byte = 8'h81;
            5'd17: init_byte = 8'h7F;   // contrast
            5'd18: init_byte = 8'hD9;
            5'd19: init_byte = 8'hF1;
            5'd20: init_byte = 8'hDB;
            5'd21: init_byte = 8'h40;
            5'd22: init_byte = 8'hA4;   // display follows RAM
            5'd23: init_byte = 8'hA6;   // not inverted
            default: init_byte = 8'hAF; // display on
        endcase
    endfunction

    typedef enum logic [2:0] {
        ST_IDLE, ST_RESET, ST_WAKE, ST_NEXT, ST_LOAD, ST_SHIFT, ST_DONE
    } state_t;

    state_t      state_q;
    logic [23:0] delay_q;
    logic [4:0]  init_q;        // 0..24 while initialising, then saturated
    logic [2:0]  page_q;
    logic [7:0]  step_q;        // 0..2 command bytes, 3..130 data columns
    logic [15:0] half_q;
    logic [3:0]  bit_q;
    logic [7:0]  shift_q;
    logic        sck_q, mosi_q, dc_q, cs_n_q, res_n_q, done_q;

    // Column of the data byte currently on step_q, and the framebuffer address.
    wire [6:0] data_col = step_q[6:0] - 7'd3;

    // The next byte and whether it is a command or frame data.
    logic [7:0] next_byte;
    logic       next_is_data;
    always_comb begin
        next_byte    = 8'h00;
        next_is_data = 1'b0;
        if (init_q < 5'(INIT_BYTES)) begin
            next_byte = init_byte(init_q);
        end else begin
            case (step_q)
                8'd0: next_byte = 8'hB0 | {5'd0, page_q};  // page address
                8'd1: next_byte = 8'h00;                   // column, low nibble
                8'd2: next_byte = 8'h10;                   // column, high nibble
                default: begin
                    next_byte    = img_data;
                    next_is_data = 1'b1;
                end
            endcase
        end
    end

    // Combinational so the frame byte is already valid when the byte starts.
    assign img_addr = {page_q, data_col};
    assign sck      = sck_q;
    assign mosi     = mosi_q;
    assign dc       = dc_q;
    assign cs_n     = cs_n_q;
    assign res_n    = res_n_q;
    assign blk      = 1'b1;                 // backlight on, polarity as wired
    assign busy     = (state_q != ST_IDLE) && (state_q != ST_DONE);
    assign done     = done_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q  <= ST_IDLE;
            delay_q  <= 24'd0;
            init_q   <= 5'd0;
            page_q   <= 3'd0;
            step_q   <= 8'd0;
            half_q   <= 16'd0;
            bit_q    <= 4'd0;
            shift_q  <= 8'd0;
            sck_q    <= 1'b0;
            mosi_q   <= 1'b0;
            dc_q     <= 1'b0;
            cs_n_q   <= 1'b1;
            res_n_q  <= 1'b0;               // keep the panel in reset
            done_q   <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    cs_n_q <= 1'b1;
                    sck_q  <= 1'b0;
                    if (start) begin
                        res_n_q <= 1'b0;
                        delay_q <= 24'd0;
                        state_q <= ST_RESET;
                    end
                end

                // res_n low for RESET_CYCLES, then released.
                ST_RESET: begin
                    res_n_q <= 1'b0;
                    if (delay_q >= 24'(RESET_CYCLES - 1)) begin
                        delay_q <= 24'd0;
                        res_n_q <= 1'b1;
                        state_q <= ST_WAKE;
                    end else begin
                        delay_q <= delay_q + 24'd1;
                    end
                end

                // Quiet time before the first command.
                ST_WAKE: begin
                    if (delay_q >= 24'(WAKE_CYCLES - 1)) begin
                        delay_q <= 24'd0;
                        state_q <= ST_NEXT;
                    end else begin
                        delay_q <= delay_q + 24'd1;
                    end
                end

                // Load one byte and start its clock burst.  A frame byte needs
                // one extra cycle: img_addr only settles on this edge, and the
                // BSRAM output follows one clock later.
                ST_NEXT: begin
                    dc_q    <= next_is_data;
                    cs_n_q  <= 1'b0;
                    sck_q   <= 1'b0;
                    half_q  <= 16'd0;
                    bit_q   <= 4'd7;
                    if (next_is_data) begin
                        state_q <= ST_LOAD;
                    end else begin
                        shift_q <= next_byte;
                        mosi_q  <= next_byte[7];
                        state_q <= ST_SHIFT;
                    end
                end

                // The frame byte is valid now that img_addr has been sampled.
                ST_LOAD: begin
                    shift_q <= img_data;
                    mosi_q  <= img_data[7];
                    state_q <= ST_SHIFT;
                end

                // Eight bits, MSB first.  Data is set up while sck is low.
                ST_SHIFT: begin
                    if (half_q >= 16'(SPI_DIV / 2 - 1)) begin
                        half_q <= 16'd0;
                        if (!sck_q) begin
                            sck_q <= 1'b1;          // rising edge: slave samples
                        end else begin
                            sck_q <= 1'b0;          // falling edge: set up the next
                            if (bit_q == 4'd0) begin
                                cs_n_q <= 1'b1;
                                if (init_q < 5'(INIT_BYTES)) begin
                                    if (init_q < 5'(INIT_BYTES - 1)) begin
                                        init_q <= init_q + 5'd1;
                                        state_q <= ST_NEXT;
                                    end else begin
                                        init_q <= 5'(INIT_BYTES);
                                        page_q <= 3'd0;
                                        step_q <= 8'd0;
                                        state_q <= ST_NEXT;
                                    end
                                end else if (step_q < 8'd130) begin
                                    step_q <= step_q + 8'd1;
                                    state_q <= ST_NEXT;
                                end else if (page_q == 3'd7) begin
                                    done_q  <= 1'b1;
                                    state_q <= ST_DONE;
                                end else begin
                                    page_q <= page_q + 3'd1;
                                    step_q <= 8'd0;
                                    state_q <= ST_NEXT;
                                end
                            end else begin
                                bit_q  <= bit_q - 4'd1;
                                mosi_q <= shift_q[bit_q - 4'd1];
                            end
                        end
                    end else begin
                        half_q <= half_q + 16'd1;
                    end
                end

                // Idle forever.  The panel keeps its RAM on its own.
                default: begin
                    cs_n_q <= 1'b1;
                    sck_q  <= 1'b0;
                    mosi_q <= 1'b0;
                    dc_q   <= 1'b0;
                end
            endcase
        end
    end
endmodule
