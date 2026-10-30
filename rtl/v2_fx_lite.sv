// Resource-bounded V2 effects: gain -> one-pole low-pass -> delay -> one comb.
//
// The delay and comb stores are explicit GW5A DPB instances in the hardware
// configuration. The old variable-indexed unpacked arrays were read
// asynchronously and Gowin implemented them as 16,443 fabric registers. The
// read side is therefore deliberately one sample-ce pipeline stage behind the
// write side; this is audio-sample latency, not a delay in the event, Loop, or
// I2S control paths.
module v2_fx_mem #(
    parameter integer DEPTH = 1024,
    parameter integer ADDR_WIDTH = 10,
    parameter integer USE_GOWIN_RAM = 0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic rd_en,
    input  logic [ADDR_WIDTH-1:0] rd_addr,
    output logic signed [15:0] rd_data,
    input  logic wr_en,
    input  logic [ADDR_WIDTH-1:0] wr_addr,
    input  logic signed [15:0] wr_data
);
    generate
        if (USE_GOWIN_RAM) begin : g_gowin
            // GW5A DPB address is a 14-bit address for a 16-bit lane. The
            // low four bits select the lane; upper bits select its word.
            localparam integer ADDR_PAD = 14 - ADDR_WIDTH - 4;
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
                .ADA({{ADDR_PAD{1'b0}}, rd_addr, 4'b0011}),
                .ADB({{ADDR_PAD{1'b0}}, wr_addr, 4'b0011}),
                .DIA(16'd0), .DIB(wr_data),
                .DOA(rd_data), .DOB()
            );
        end else begin : g_rtl
            logic signed [15:0] mem [0:DEPTH-1];
            integer i;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rd_data <= 16'sd0;
                    for (i = 0; i < DEPTH; i = i + 1)
                        mem[i] <= 16'sd0;
                end else if (wr_en)
                    mem[wr_addr] <= wr_data;
                if (rst_n && rd_en)
                    rd_data <= mem[rd_addr];
            end
            // The fallback is only a simulation model. Hardware uses the
            // explicit DPB branch above, so this reset loop cannot inhibit
            // block-RAM inference in the actual synthesis configuration.
        end
    endgenerate
endmodule

module v2_fx_lite #(
    parameter integer DELAY_DEPTH = 1024,
    parameter integer COMB_DEPTH = 256,
    parameter integer USE_GOWIN_RAM = 0
) (
    input logic clk, input logic rst_n, input logic sample_ce,
    input logic signed [15:0] audio_in, output logic signed [15:0] audio_out,
    input logic fx_enable, input logic [1:0] fx_level,
    input logic [17:0] fx_gain_q16, input logic [15:0] fx_cutoff_q16,
    input logic [9:0] fx_delay_samples, input logic [15:0] fx_feedback_q15,
    input logic [15:0] fx_reverb_mix_q15,
    output logic [1:0] fx_status_level, output logic fx_clip
);
    logic signed [15:0] delay_rd_data, comb_rd_data;
    logic [9:0] delay_ptr, delay_rd_ptr;
    logic [7:0] comb_ptr, comb_rd_ptr;
    logic signed [31:0] lp_state;
    logic signed [31:0] pending_lp;
    logic [1:0] pending_level;
    logic [15:0] pending_feedback;
    logic [15:0] pending_reverb_mix;
    logic pending_valid;
    logic signed [47:0] gain_value, lp_value;
    logic signed [47:0] effect_value, feedback_value, delay_write_value;
    logic [1:0] level_now;

    always_comb begin
        level_now = fx_enable ? fx_level : 2'd0;
        fx_status_level = level_now;
        gain_value = ($signed(audio_in) * $signed({1'b0, fx_gain_q16})) >>> 16;
        lp_value = lp_state + (((gain_value - lp_state) *
                    $signed({1'b0, fx_cutoff_q16})) >>> 16);
        delay_rd_ptr = delay_ptr - fx_delay_samples;
        comb_rd_ptr = comb_ptr - 8'd37;
        feedback_value = ($signed(delay_rd_data) *
                    $signed({1'b0, pending_feedback})) >>> 15;
        delay_write_value = lp_value + feedback_value;
        effect_value = pending_lp;
        if (pending_level >= 2'd2)
            effect_value = pending_lp + delay_rd_data;
        if (pending_level >= 2'd3)
            effect_value = effect_value + (($signed(comb_rd_data) *
                $signed({1'b0, pending_reverb_mix})) >>> 15);
    end

    v2_fx_mem #(.DEPTH(DELAY_DEPTH), .ADDR_WIDTH(10),
                .USE_GOWIN_RAM(USE_GOWIN_RAM)) delay_mem (
        .clk, .rst_n, .rd_en(sample_ce && (level_now >= 2'd2)),
        .rd_addr(delay_rd_ptr), .rd_data(delay_rd_data),
        .wr_en(sample_ce && (level_now >= 2'd1)), .wr_addr(delay_ptr),
        .wr_data(delay_write_value[15:0])
    );
    v2_fx_mem #(.DEPTH(COMB_DEPTH), .ADDR_WIDTH(8),
                .USE_GOWIN_RAM(USE_GOWIN_RAM)) comb_mem (
        .clk, .rst_n, .rd_en(sample_ce && (level_now >= 2'd3)),
        .rd_addr(comb_rd_ptr), .rd_data(comb_rd_data),
        .wr_en(sample_ce && (level_now >= 2'd3)), .wr_addr(comb_ptr),
        .wr_data(effect_value[15:0])
    );

    function automatic logic signed [15:0] saturate(input logic signed [47:0] value);
        begin
            if (value > 48'sd32767) saturate = 16'sh7fff;
            else if (value < -48'sd32768) saturate = -16'sd32768;
            else saturate = value[15:0];
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_out <= 16'sd0;
            fx_clip <= 1'b0;
            delay_ptr <= 10'd0;
            comb_ptr <= 8'd0;
            lp_state <= 32'sd0;
            pending_lp <= 32'sd0;
            pending_level <= 2'd0;
            pending_feedback <= 16'd0;
            pending_reverb_mix <= 16'd0;
            pending_valid <= 1'b0;
        end else if (sample_ce) begin
            // Level zero is a true bypass. It does not consume the memory
            // pipeline and therefore has no added audio sample latency.
            if (level_now == 2'd0) begin
                audio_out <= audio_in;
                fx_clip <= 1'b0;
                pending_valid <= 1'b0;
            end else begin
                if (pending_valid) begin
                    fx_clip <= (effect_value > 48'sd32767) ||
                               (effect_value < -48'sd32768);
                    audio_out <= saturate(effect_value);
                end else begin
                    audio_out <= 16'sd0;
                    fx_clip <= 1'b0;
                end
                lp_state <= lp_value[31:0];
                pending_lp <= lp_value[31:0];
                pending_level <= level_now;
                pending_feedback <= fx_feedback_q15;
                pending_reverb_mix <= fx_reverb_mix_q15;
                pending_valid <= 1'b1;
                delay_ptr <= delay_ptr + 10'd1;
                comb_ptr <= comb_ptr + 8'd1;
            end
        end
    end
endmodule
