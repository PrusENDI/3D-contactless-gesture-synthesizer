// Continuous SSD1306 refresh for the scope picture.
//
// Unlike v2_oled_static (one-shot, production), this writer never stops: after
// the init table it streams the whole 1024-byte framebuffer, then starts over.
// While streaming it writes each byte back shifted right by one, so old points
// fade out -- that is the phosphor persistence the scope look needs.
//
// SPI is mode 0 (idle low, sample on rising edge), MSB first, SPI_DIV clocks per
// bit (80 at 80 MHz = 1 MHz).  One frame is ~8.4 ms; FRAME_GAP then pads the
// period out to about 30 fps.
module v2_oled_scope_wr #(
    parameter integer SPI_DIV    = 80,
    parameter integer RESET_CYCLES = 8000,      // 100 us at 80 MHz
    parameter integer WAKE_CYCLES  = 8_000_000, // 100 ms
    parameter integer FRAME_GAP    = 2_000_000, // ~25 ms at 80 MHz
    // A byte is halved once every DECAY_FRAMES frames: 16 frames at 30 fps is
    // about half a second of persistence.
    parameter integer DECAY_FRAMES = 16,
    // 1 = send 1-px vertical stripes instead of the framebuffer.  A bring-up
    // pattern: if the stripes are clean, SPI, addressing and init are right and
    // the picture logic is what needs looking at.
    parameter integer TEST_STRIPES = 0
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,       // level: leave IDLE when high
    input  logic [7:0] fb_rdata,
    output logic [9:0] fb_addr,
    output logic [7:0] fb_wdata,
    output logic       fb_we,
    output logic       sck,
    output logic       mosi,
    output logic       dc,
    output logic       cs_n,
    output logic       res_n,
    output logic       blk,
    output logic       frame         // one-cycle pulse at the end of a frame
);
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
            5'd11: init_byte = 8'h02;
            5'd12: init_byte = 8'hA1;
            5'd13: init_byte = 8'hC8;
            5'd14: init_byte = 8'hDA;
            5'd15: init_byte = 8'h12;
            5'd16: init_byte = 8'h81;
            5'd17: init_byte = 8'h7F;
            5'd18: init_byte = 8'hD9;
            5'd19: init_byte = 8'hF1;
            5'd20: init_byte = 8'hDB;
            5'd21: init_byte = 8'h40;
            5'd22: init_byte = 8'hA4;
            5'd23: init_byte = 8'hA6;
            default: init_byte = 8'hAF;
        endcase
    endfunction

    typedef enum logic [2:0] {S_IDLE, S_RESET, S_WAKE, S_NEXT, S_LOAD, S_DECAY,
                              S_SHIFT, S_GAP} state_t;
    state_t      state_q;
    logic [23:0] delay_q;
    logic [4:0]  init_q;
    logic [2:0]  page_q;
    logic [7:0]  step_q;
    logic [16:0] gap_q;
    logic [15:0] half_q;
    logic [3:0]  bit_q;
    logic [7:0]  shift_q;
    logic [7:0]  decay_cnt_q;
    logic        sck_q, mosi_q, dc_q, cs_n_q, res_n_q, frame_q;

    // Persistence: only one frame in DECAY_FRAMES halves the bytes.
    wire decay_due = (decay_cnt_q == 8'd0);

    wire [6:0] data_col = step_q[6:0] - 7'd3;

    logic [7:0] next_byte;
    logic       next_is_data;
    always_comb begin
        next_byte    = 8'h00;
        next_is_data = 1'b0;
        if (init_q < 5'(INIT_BYTES)) begin
            next_byte = init_byte(init_q);
        end else begin
            case (step_q)
                8'd0: next_byte = 8'hB0 | {5'd0, page_q};
                8'd1: next_byte = 8'h00;
                8'd2: next_byte = 8'h10;
                default: begin
                    next_byte    = fb_rdata;
                    next_is_data = 1'b1;
                end
            endcase
        end
    end

    assign fb_addr = {page_q, data_col};
    assign sck     = sck_q;
    assign mosi    = mosi_q;
    assign dc      = dc_q;
    assign cs_n    = cs_n_q;
    assign res_n   = res_n_q;
    assign blk     = 1'b1;
    assign frame   = frame_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
            delay_q <= 24'd0;
            init_q  <= 5'd0;
            page_q  <= 3'd0;
            step_q  <= 8'd0;
            gap_q   <= 17'd0;
            half_q  <= 16'd0;
            bit_q   <= 4'd0;
            shift_q <= 8'd0;
            decay_cnt_q <= 8'd0;
            sck_q   <= 1'b0;
            mosi_q  <= 1'b0;
            dc_q    <= 1'b0;
            cs_n_q  <= 1'b1;
            res_n_q <= 1'b0;
            frame_q <= 1'b0;
            fb_wdata <= 8'd0;
            fb_we    <= 1'b0;
        end else begin
            frame_q <= 1'b0;
            fb_we   <= 1'b0;

            case (state_q)
                S_IDLE: begin
                    cs_n_q <= 1'b1;
                    sck_q  <= 1'b0;
                    if (start) begin
                        res_n_q <= 1'b0;
                        delay_q <= 24'd0;
                        state_q <= S_RESET;
                    end
                end

                S_RESET: begin
                    res_n_q <= 1'b0;
                    if (delay_q >= 24'(RESET_CYCLES - 1)) begin
                        delay_q <= 24'd0;
                        res_n_q <= 1'b1;
                        state_q <= S_WAKE;
                    end else begin
                        delay_q <= delay_q + 24'd1;
                    end
                end

                S_WAKE: begin
                    if (delay_q >= 24'(WAKE_CYCLES - 1)) begin
                        delay_q <= 24'd0;
                        state_q <= S_NEXT;
                    end else begin
                        delay_q <= delay_q + 24'd1;
                    end
                end

                S_NEXT: begin
                    dc_q   <= next_is_data;
                    cs_n_q <= 1'b0;
                    sck_q  <= 1'b0;
                    half_q <= 16'd0;
                    bit_q  <= 4'd7;
                    if (next_is_data) begin
                        state_q <= S_LOAD;      // fb_addr settles, read lands next cycle
                    end else begin
                        shift_q <= next_byte;
                        mosi_q  <= next_byte[7];
                        state_q <= S_SHIFT;
                    end
                end

                // The framebuffer byte is valid now.  Latch it, then fade it in
                // the next cycle: the read and the decay write must not share a
                // cycle, or the block RAM becomes a rejected write mode.
                S_LOAD: begin
                    shift_q  <= TEST_STRIPES ? {8{data_col[0]}} : fb_rdata;
                    mosi_q   <= TEST_STRIPES ? data_col[0] : fb_rdata[7];
                    state_q  <= S_DECAY;
                end

                S_DECAY: begin
                    fb_wdata <= {1'b0, shift_q[7:1]};
                    fb_we    <= (!TEST_STRIPES && decay_due) ? 1'b1 : 1'b0;
                    state_q  <= S_SHIFT;
                end

                S_SHIFT: begin
                    if (half_q >= 16'(SPI_DIV / 2 - 1)) begin
                        half_q <= 16'd0;
                        if (!sck_q) begin
                            sck_q <= 1'b1;
                        end else begin
                            sck_q <= 1'b0;
                            if (bit_q == 4'd0) begin
                                cs_n_q <= 1'b1;
                                if (init_q < 5'(INIT_BYTES)) begin
                                    if (init_q < 5'(INIT_BYTES - 1)) begin
                                        init_q <= init_q + 5'd1;
                                        state_q <= S_NEXT;
                                    end else begin
                                        init_q <= 5'(INIT_BYTES);
                                        page_q <= 3'd0;
                                        step_q <= 8'd0;
                                        state_q <= S_NEXT;
                                    end
                                end else if (step_q < 8'd130) begin
                                    step_q <= step_q + 8'd1;
                                    state_q <= S_NEXT;
                                end else if (page_q == 3'd7) begin
                                    frame_q <= 1'b1;
                                    decay_cnt_q <= (decay_cnt_q >= 8'(DECAY_FRAMES - 1))
                                                   ? 8'd0 : decay_cnt_q + 8'd1;
                                    page_q <= 3'd0;
                                    step_q <= 8'd0;
                                    gap_q  <= 17'd0;
                                    state_q <= S_GAP;
                                end else begin
                                    page_q <= page_q + 3'd1;
                                    step_q <= 8'd0;
                                    state_q <= S_NEXT;
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

                // Frame pacing: ~30 fps.
                default: begin
                    if (gap_q >= 17'(FRAME_GAP)) state_q <= S_NEXT;
                    else                        gap_q <= gap_q + 17'd1;
                end
            endcase
        end
    end
endmodule
