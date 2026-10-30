// Verilog-2001 register controller. The official IP owns SDA/SCL bit timing.
module mgc3130_reader #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000,
    parameter [6:0] I2C_ADDR = 7'h42
) (
    input wire clk, input wire rst_n,
    inout wire i2c_sda, inout wire i2c_scl, inout wire mgc_ts,
    output reg report_valid, output reg xyz_valid,
    output reg [15:0] x_position, y_position, z_position,
    output reg [7:0] gesture_code,
    output reg report_error, output reg [3:0] error_code,
    output reg busy,
    output reg [31:0] debug_error_context,
    output reg [15:0] debug_output_mask,
    output reg [7:0] debug_message_size,
    // Raw SDK TouchInfo word, valid only alongside report_valid. Touch is
    // independent of XYZ validity; absent/malformed/error reports clear it.
    output reg [31:0] touch_info, output reg touch_valid
);
    localparam [15:0] PRESCALE = CLK_HZ / (5 * I2C_HZ) - 1;
    localparam integer BYTE_TIMEOUT = CLK_HZ / 100; // 10 ms
    localparam integer FRAME_TIMEOUT = CLK_HZ / 10; // 100 ms
    localparam integer RETRY_DELAY = CLK_HZ / 200; // 5 ms
    localparam integer TS_SETUP = CLK_HZ / 100_000; // 10 us
    reg ip_reset_n;
    reg ip_wr_en, ip_rd_en;
    reg [2:0] ip_wr_addr, ip_rd_addr;
    reg [7:0] ip_wr_data;
    wire [7:0] ip_rd_data;
    wire ip_interrupt;
    Gowin_I2C_Master u_i2c_master (
        .I_CLK(clk), .I_RESETN(rst_n & ip_reset_n),
        .I_TX_EN(ip_wr_en), .I_WADDR(ip_wr_addr), .I_WDATA(ip_wr_data),
        .I_RX_EN(ip_rd_en), .I_RADDR(ip_rd_addr), .O_RDATA(ip_rd_data),
        .O_IIC_INT(ip_interrupt), .SDA(i2c_sda), .SCL(i2c_scl)
    );
    reg ts_oe;
    assign mgc_ts = ts_oe ? 1'b0 : 1'bz;
    reg ts_meta, ts_in, sda_meta, sda_in, scl_meta, scl_in;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ts_meta <= 1; ts_in <= 1; sda_meta <= 1; sda_in <= 1;
            scl_meta <= 1; scl_in <= 1;
        end else begin
            ts_meta <= mgc_ts; ts_in <= ts_meta;
            sda_meta <= i2c_sda; sda_in <= sda_meta;
            scl_meta <= i2c_scl; scl_in <= scl_meta;
        end
    end
    localparam [5:0]
        ST_CFG_LO=0, ST_CFG_HI=1, ST_CFG_ENABLE=2, ST_WAIT_TS=3,
        ST_TS_SETUP=4, ST_ADDRESS=5, ST_ADDRESS_CMD=6,
        ST_POLL=7, ST_STATUS=8, ST_READ_CMD=9,
        ST_RX_REQUEST=10, ST_RX_BYTE=11, ST_PARSE_PREP=12, ST_PARSE=13,
        ST_STOP_ERROR=14, ST_ERROR_REPORT=15, ST_RELEASE=16,
        ST_DELAY=17, ST_RECOVER=18, ST_RESET_HOLD=19,
        ST_WR_GAP=20, ST_WR_RETURN=21, ST_RD_GAP=22, ST_RD_CAPTURE=23;
    reg [5:0] state, return_state;
    reg [7:0] reg_read_data, ip_status;
    reg [7:0] frame [0:254]; // Size includes the four-byte header
    reg [7:0] frame_length, rx_byte, tx_byte, last_message_id;
    // Field order/length from Microchip GestIC SDK 1.2.0 api/src/stream.c,
    // gestic_handle_data_output(), and api/include/gestic_api.h.
    wire [15:0] output_mask;
    wire [7:0] gesture_offset, touch_offset, position_offset, required_length;
    wire [7:0] electrode_bytes;
    assign output_mask = {frame[5], frame[4]};
    assign gesture_offset = 8'd8 + (output_mask[0] ? 8'd2 : 8'd0);
    assign touch_offset = gesture_offset + (output_mask[1] ? 8'd4 : 8'd0);
    assign position_offset = gesture_offset +
        (output_mask[1] ? 8'd4 : 8'd0) +
        (output_mask[2] ? 8'd4 : 8'd0) +
        (output_mask[3] ? 8'd2 : 8'd0);
    assign electrode_bytes = (output_mask[10:8] == 3'd0) ? 8'd16 : 8'd20;
    assign required_length = position_offset +
        (output_mask[4] ? 8'd6 : 8'd0) +
        (output_mask[5] ? 8'd4 : 8'd0) +
        (output_mask[11] ? electrode_bytes : 8'd0) +
        (output_mask[12] ? electrode_bytes : 8'd0);
    reg [15:0] parse_output_mask;
    reg [7:0] parse_gesture_offset, parse_touch_offset, parse_position_offset, parse_required_length;
    reg [7:0] parse_electrode_bytes;
    reg [1:0] operation; // 0 address, 1 read, 2 error STOP
    reg command_active, transaction_active;
    reg tip_seen;
    reg [31:0] command_timer, frame_timer, delay_timer;

    // Registered enables; read latency matches the official reference design.
    task write_register;
        input [2:0] address;
        input [7:0] data;
        input [5:0] continuation;
        begin
            ip_wr_addr <= address; ip_wr_data <= data; ip_wr_en <= 1;
            return_state <= continuation; state <= ST_WR_GAP;
        end
    endtask
    task read_register;
        input [2:0] address;
        input [5:0] continuation;
        begin
            ip_rd_addr <= address; ip_rd_en <= 1;
            return_state <= continuation; state <= ST_RD_GAP;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_CFG_LO; return_state <= ST_WAIT_TS;
            ip_reset_n <= 1;
            ip_wr_en <= 0; ip_wr_addr <= 0; ip_wr_data <= 0;
            ip_rd_en <= 0; ip_rd_addr <= 0;
            reg_read_data <= 0; ip_status <= 0; ts_oe <= 0;
            frame_length <= 0; rx_byte <= 0; tx_byte <= 0;
            last_message_id <= 0; operation <= 0;
            command_active <= 0; transaction_active <= 0;
            tip_seen <= 0; debug_error_context <= 0;
            debug_output_mask <= 0; debug_message_size <= 0;
            parse_output_mask <= 0; parse_gesture_offset <= 0; parse_touch_offset <= 0;
            parse_position_offset <= 0; parse_required_length <= 0; parse_electrode_bytes <= 0;
            command_timer <= 0; frame_timer <= 0; delay_timer <= 0;
            report_valid <= 0; report_error <= 0; xyz_valid <= 0;
            touch_info <= 0; touch_valid <= 0;
            error_code <= 0; busy <= 0;
            x_position <= 0; y_position <= 0; z_position <= 0; gesture_code <= 0;
        end else begin
            ip_wr_en <= 0; ip_rd_en <= 0;
            report_valid <= 0; report_error <= 0;
            touch_valid <= 0;
            if (command_active) command_timer <= command_timer + 1'b1;
            if (transaction_active) frame_timer <= frame_timer + 1'b1;
            case (state)
                ST_WR_GAP: state <= ST_WR_RETURN;
                ST_WR_RETURN: state <= return_state;
                ST_RD_GAP: state <= ST_RD_CAPTURE;
                ST_RD_CAPTURE: begin
                    reg_read_data <= ip_rd_data; state <= return_state;
                end
                ST_CFG_LO: write_register(3'd0, PRESCALE[7:0], ST_CFG_HI);
                ST_CFG_HI: write_register(3'd1, PRESCALE[15:8], ST_CFG_ENABLE);
                ST_CFG_ENABLE: write_register(3'd2, 8'h80, ST_WAIT_TS);
                ST_WAIT_TS: begin
                    busy <= 0; ts_oe <= 0;
                    if (!ts_in) begin
                        ts_oe <= 1; busy <= 1; transaction_active <= 1;
                        frame_timer <= 0; delay_timer <= 0;
                        rx_byte <= 0; frame_length <= 0;
                        state <= ST_TS_SETUP;
                    end
                end
                ST_TS_SETUP: begin
                    if (delay_timer < TS_SETUP-1) delay_timer <= delay_timer + 1'b1;
                    else if (sda_in && scl_in) state <= ST_ADDRESS;
                end
                ST_ADDRESS: begin
                    tx_byte <= {I2C_ADDR, 1'b1};
                    write_register(3'd3, {I2C_ADDR, 1'b1}, ST_ADDRESS_CMD);
                end
                ST_ADDRESS_CMD: begin
                    operation <= 0; command_active <= 1; command_timer <= 0;
                    tip_seen <= 0;
                    write_register(3'd4, 8'h90, ST_POLL); // official START WRITE
                end
                ST_POLL: read_register(3'd4, ST_STATUS);
                ST_STATUS: begin
                    ip_status <= reg_read_data;
                    if (reg_read_data[1]) tip_seen <= 1;
                    if (reg_read_data[5]) begin
                        debug_error_context <= {state, operation, reg_read_data, rx_byte, frame_length};
                        error_code <= 4'd3; state <= ST_RECOVER;
                    end else if (operation == 2) begin
                        // STOP-only completion is determined by bus idle.
                        if (!reg_read_data[6]) begin
                            command_active <= 0; state <= ST_ERROR_REPORT;
                        end else state <= ST_POLL;
                    end else if (tip_seen && !reg_read_data[1]) begin
                        // Use the official example's TIP completion sequence.
                        // Observe TIP=1 first to reject the initial idle value.
                        // Do not depend on IF while acknowledging interrupts.
                        if (operation == 0) begin
                            command_active <= 0;
                            if (reg_read_data[7]) begin
                                debug_error_context <= {state, operation, reg_read_data, rx_byte, frame_length};
                                error_code <= 4'd1; state <= ST_STOP_ERROR;
                            end else state <= ST_READ_CMD;
                        end else if ((rx_byte == frame_length-1'b1) &&
                                     (rx_byte != 0) && reg_read_data[6])
                            state <= ST_POLL; // wait for the final STOP
                        else begin
                            command_active <= 0; state <= ST_RX_REQUEST;
                        end
                    end else state <= ST_POLL;
                end
                ST_READ_CMD: begin
                    operation <= 1; command_active <= 1; command_timer <= 0;
                    tip_seen <= 0;
                    if ((rx_byte != 0) && (rx_byte == frame_length-1'b1))
                        write_register(3'd4, 8'h68, ST_POLL); // READ NACK STOP
                    else write_register(3'd4, 8'h20, ST_POLL); // READ ACK
                end
                ST_RX_REQUEST: read_register(3'd3, ST_RX_BYTE);
                ST_RX_BYTE: begin
                    frame[rx_byte] <= reg_read_data;
                    if (rx_byte == 0) begin
                        frame_length <= reg_read_data;
                        if (reg_read_data < 8'd4) begin
                            debug_error_context <= {state, operation, ip_status, rx_byte, reg_read_data};
                            error_code <= 4'd4; state <= ST_STOP_ERROR;
                        end else begin
                            rx_byte <= 8'd1; state <= ST_READ_CMD;
                        end
                    end else if (rx_byte == frame_length-1'b1) state <= ST_PARSE_PREP;
                    else begin
                        rx_byte <= rx_byte + 1'b1; state <= ST_READ_CMD;
                    end
                end
                ST_PARSE_PREP: begin
                    parse_output_mask <= output_mask;
                    parse_gesture_offset <= gesture_offset;
                    parse_touch_offset <= touch_offset;
                    parse_position_offset <= position_offset;
                    parse_required_length <= required_length;
                    parse_electrode_bytes <= electrode_bytes;
                    state <= ST_PARSE;
                end
                ST_PARSE: begin
                    last_message_id <= frame[3];
                    // Fully drain startup/status messages without treating
                    // them as malformed sensor reports.
                    if (frame[3] == 8'h91) begin
                        report_valid <= 1;
                        debug_output_mask <= parse_output_mask;
                        debug_message_size <= frame_length;
                        touch_info <= 0;
                        if ((frame_length >= 8'd8) &&
                            (frame_length >= parse_required_length) &&
                            ((parse_output_mask & 16'hE0C0) == 16'd0) &&
                            (parse_output_mask[10:8] <= 3'd1)) begin
                            xyz_valid <= parse_output_mask[4] && frame[7][0];
                            touch_valid <= parse_output_mask[2];
                            if (parse_output_mask[2])
                                touch_info <= {frame[parse_touch_offset+8'd3], frame[parse_touch_offset+8'd2],
                                               frame[parse_touch_offset+8'd1], frame[parse_touch_offset]};
                            if (parse_output_mask[1]) gesture_code <= frame[parse_gesture_offset];
                            else gesture_code <= 0;
                            if (parse_output_mask[4] && frame[7][0]) begin
                                x_position <= {frame[parse_position_offset+8'd1], frame[parse_position_offset]};
                                y_position <= {frame[parse_position_offset+8'd3], frame[parse_position_offset+8'd2]};
                                z_position <= {frame[parse_position_offset+8'd5], frame[parse_position_offset+8'd4]};
                            end
                            error_code <= 0;
                            debug_error_context <= 0;
                        end else begin
                            // Reject truncated layouts and unknown mask bits.
                            xyz_valid <= 0; error_code <= 4'd7; report_error <= 1;
                            debug_error_context <= {state, operation, ip_status, rx_byte, frame_length};
                        end
                    end
                    state <= ST_RELEASE;
                end
                ST_STOP_ERROR: begin
                    operation <= 2; command_active <= 1; command_timer <= 0;
                    write_register(3'd4, 8'h40, ST_POLL); // official STOP
                end
                ST_ERROR_REPORT: begin
                    report_valid <= 1; report_error <= 1; xyz_valid <= 0;
                    touch_info <= 0; touch_valid <= 0;
                    state <= ST_RELEASE;
                end
                ST_RELEASE: begin
                    ts_oe <= 0; busy <= 0; transaction_active <= 0;
                    command_active <= 0; delay_timer <= 0; state <= ST_DELAY;
                end
                ST_DELAY: begin
                    if (delay_timer == RETRY_DELAY-1) state <= ST_WAIT_TS;
                    else delay_timer <= delay_timer + 1'b1;
                end
                ST_RECOVER: begin
                    // A stuck command cannot reliably generate STOP. Reset
                    // the IP, release TS and reconfigure after a retry delay.
                    ip_reset_n <= 0; ip_wr_en <= 0; ip_rd_en <= 0;
                    command_active <= 0; transaction_active <= 0;
                    ts_oe <= 0; busy <= 0;
                    report_valid <= 1; report_error <= 1; xyz_valid <= 0;
                    touch_info <= 0; touch_valid <= 0;
                    delay_timer <= 0; state <= ST_RESET_HOLD;
                end
                ST_RESET_HOLD: begin
                    if (delay_timer == RETRY_DELAY-1) begin
                        ip_reset_n <= 1; state <= ST_CFG_LO;
                    end else delay_timer <= delay_timer + 1'b1;
                end
                default: begin error_code <= 4'd8; state <= ST_RECOVER; end
            endcase
            // Watchdog overrides ordinary transitions, including register IO.
            if ((state != ST_RECOVER) &&
                ((command_active && (command_timer >= BYTE_TIMEOUT-1)) ||
                 (transaction_active && (frame_timer >= FRAME_TIMEOUT-1)))) begin
                if (command_active && (command_timer >= BYTE_TIMEOUT-1))
                    error_code <= 4'd2; // command timeout
                else if (state == ST_TS_SETUP) error_code <= 4'd5; // bus stayed low
                else error_code <= 4'd6; // total message timeout
                debug_error_context <= {state, operation, ip_status, rx_byte, frame_length};
                command_active <= 0; transaction_active <= 0;
                ip_wr_en <= 0; ip_rd_en <= 0; state <= ST_RECOVER;
            end
        end
    end
endmodule
