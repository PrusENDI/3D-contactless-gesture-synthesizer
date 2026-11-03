// Audio -> point plotter for the scope picture.
//
// x is the sample from 55 samples ago (1.15 ms, a quarter period of the 220 Hz
// base tone), y is the current sample.  One tone therefore traces a circle, a
// 2:1 pair traces a figure eight, and thirty-two tones fill the screen -- the
// picture is the audio, not a drawing.
//
// One point every DECIM frames (48 kHz / 16 = 3 k points/s) is enough to draw a
// smooth curve and keeps the read-modify-write well inside one refresh frame.
module v2_oled_scope_plot #(
    // One point per audio frame: the whole closed curve is retraced every
    // 1/220 s = 218 samples, so a sparser plot is aliased noise, not a curve.
    parameter integer DECIM = 1,
    // Delay in samples; 55 is a quarter period at 220 Hz.
    parameter integer DELAY = 55
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              sample_valid,
    input  logic signed [15:0] sample,
    input  logic              muted,
    // framebuffer port A
    output logic [9:0]        fb_addr,
    output logic [7:0]        fb_wdata,
    output logic              fb_we,
    input  logic [7:0]        fb_rdata,
    // last plotted point, for the testbench
    output logic [6:0]        dbg_x,
    output logic [5:0]        dbg_y
);
    // 64-deep delay line.  Index (wr + 64 - DELAY) holds the sample from DELAY
    // frames ago; reading it in the same cycle as writing index wr is safe
    // because DELAY != 0.
    logic signed [15:0] dly [0:63];
    logic [5:0] wr_q;
    logic signed [15:0] delayed;

    assign delayed = dly[(wr_q + 6'd64 - 6'(DELAY & 63)) & 6'h3F];

    // -32768..32767 -> column 0..127 / row 0..63 (row 63 is the bottom).
    logic [16:0] xs, ys;
    logic [6:0]  x_px;
    logic [5:0]  y_px, row;
    assign xs   = {1'b0, delayed} + 17'd32768;
    assign ys   = {1'b0, sample}  + 17'd32768;
    assign x_px = xs[16:9];
    assign y_px = ys[16:10];
    assign row  = 6'd63 - y_px;

    assign dbg_x = x_px;
    assign dbg_y = row;

    typedef enum logic [1:0] {P_IDLE, P_READ, P_WRITE} state_t;
    state_t     state_q;
    logic [9:0] addr_q;
    logic [7:0] mask_q;
    logic [3:0] dec_q;

    logic [9:0] addr_now;
    logic [7:0] mask_now;
    assign addr_now = {row[5:3], x_px};
    assign mask_now = 8'd1 << row[2:0];

    // A point is due every DECIM accepted frames, and never during a gap.
    wire point_due = sample_valid && !muted && (dec_q == 4'(DECIM - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 64; i++) dly[i] <= 16'sd0;
            wr_q    <= 6'd0;
            dec_q   <= 4'd0;
            state_q <= P_IDLE;
            addr_q  <= 10'd0;
            mask_q  <= 8'd0;
            fb_addr <= 10'd0;
            fb_wdata <= 8'd0;
            fb_we   <= 1'b0;
        end else begin
            if (sample_valid) begin
                dly[wr_q] <= sample;
                wr_q      <= wr_q + 6'd1;
                dec_q     <= point_due ? 4'd0 : dec_q + 4'd1;
            end

            case (state_q)
                P_IDLE: begin
                    fb_we <= 1'b0;
                    if (point_due) begin
                        addr_q  <= addr_now;
                        mask_q  <= mask_now;
                        fb_addr <= addr_now;
                        state_q <= P_READ;
                    end
                end
                // fb_rdata is valid now: set the bit and write it back.
                P_READ: begin
                    fb_wdata <= fb_rdata | mask_q;
                    fb_we    <= 1'b1;
                    state_q  <= P_WRITE;
                end
                default: begin
                    fb_we   <= 1'b0;
                    state_q <= P_IDLE;
                end
            endcase
        end
    end
endmodule
