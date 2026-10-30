// V2's only UART protocol endpoint.
//
// The byte parser accepts the frozen 11-byte control packet and exposes a
// ready/valid command boundary to the CSR/control plane. Replies are accepted
// through rsp_* and serialized as the frozen 22-byte telemetry-shaped ACK or
// NACK frame. RX parsing, command delivery and TX serialization are all
// independent of sample_ce; TX backpressure therefore cannot stop audio.
module v2_uart_link (
    input  logic clk, input logic rst_n,
    input  logic rx_valid, input logic [7:0] rx_byte,
    output logic cmd_valid, input logic cmd_ready,
    output logic [7:0] cmd_op, output logic [7:0] cmd_address,
    output logic [7:0] cmd_sequence, output logic [31:0] cmd_data,
    input logic rsp_valid, output logic rsp_ready,
    input logic [7:0] rsp_sequence, input logic [7:0] rsp_status,
    input logic [7:0] rsp_error, input logic [31:0] rsp_data,
    input logic rsp_terminal,
    output logic tx_valid, input logic tx_ready, output logic [7:0] tx_byte,
    output logic rx_busy, output logic tx_busy,
    output logic [7:0] protocol_error
);
    import v2_contract_pkg::*;

    logic [7:0] frame [0:10];
    logic [3:0] rx_count;
    logic parse_pending;
    logic outstanding;
    logic response_pending;
    logic [4:0] tx_index;
    logic [7:0] response_bytes [0:21];
    logic [7:0] last_frame [0:10];
    logic [7:0] last_response [0:21];
    logic last_valid;
    logic [7:0] outstanding_sequence;
    logic [7:0] outstanding_frame [0:10];
    logic [15:0] crc_tmp;
    integer i;

    function automatic logic [15:0] crc8_step(input logic [15:0] crc_in,
                                               input logic [7:0] byte_in);
        logic [15:0] c;
        integer b;
        begin
            c = crc_in ^ {byte_in,8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc8_step = c;
        end
    endfunction

    function automatic logic [15:0] control_crc(input logic [7:0] b0,
                                                 input logic [7:0] b1,
                                                 input logic [7:0] b2,
                                                 input logic [7:0] b3,
                                                 input logic [7:0] b4,
                                                 input logic [7:0] b5,
                                                 input logic [7:0] b6,
                                                 input logic [7:0] b7,
                                                 input logic [7:0] b8);
        logic [15:0] c;
        begin
            c = 16'hffff;
            c = crc8_step(c,b0); c = crc8_step(c,b1); c = crc8_step(c,b2);
            c = crc8_step(c,b3); c = crc8_step(c,b4); c = crc8_step(c,b5);
            c = crc8_step(c,b6); c = crc8_step(c,b7); control_crc = crc8_step(c,b8);
        end
    endfunction

    function automatic logic frame_equal(input logic [7:0] candidate [0:10],
                                          input logic [7:0] saved [0:10]);
        integer k;
        begin
            frame_equal = 1'b1;
            for (k = 0; k < 11; k = k + 1)
                if (candidate[k] != saved[k]) frame_equal = 1'b0;
        end
    endfunction

    function automatic logic op_access_ok(input logic [7:0] op,
                                          input logic [7:0] address);
        logic [1:0] access;
        begin
            access = v2_csr_access(address);
            if (op == V2_OP_PING)
                op_access_ok = (address == 8'h00);
            else if (op == V2_OP_READ)
                op_access_ok = (access == V2_ACCESS_RO) || (access == V2_ACCESS_RW);
            else if (op == V2_OP_WRITE)
                op_access_ok = (access == V2_ACCESS_RW) || (access == V2_ACCESS_WO);
            else
                op_access_ok = 1'b0;
        end
    endfunction

    function automatic logic op_data_ok(input logic [7:0] op,
                                        input logic [7:0] address,
                                        input logic [31:0] data);
        begin
            if (op == V2_OP_PING)
                op_data_ok = (address == 8'h00) && (data == 32'd0);
            else if (op == V2_OP_READ)
                op_data_ok = (data == 32'd0);
            else if (op == V2_OP_WRITE) begin
                // The selected PATCH bank is owned by the CSR block. The
                // link still enforces the address/access boundary; the CSR
                // validates PATCH_SHADOW_DATA against its live selector.
                if (address == V2_CSR_PATCH_SHADOW_DATA)
                    op_data_ok = 1'b1;
                else
                    op_data_ok = v2_csr_data_valid(address, data);
            end else
                op_data_ok = 1'b0;
        end
    endfunction

    assign rx_busy = (rx_count != 0) || parse_pending;
    assign tx_valid = response_pending;
    assign tx_byte = response_pending ? response_bytes[tx_index] : 8'h00;
    assign tx_busy = response_pending;
    assign rsp_ready = outstanding && !response_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [15:0] expected_crc;
        logic crc_good;
        logic version_good;
        logic op_good;
        logic access_good;
        logic data_good;
        logic duplicate;
        logic [7:0] reject_error;
        if (!rst_n) begin
            rx_count <= 0;
            parse_pending <= 1'b0;
            cmd_valid <= 1'b0;
            cmd_op <= 0; cmd_address <= 0; cmd_sequence <= 0; cmd_data <= 0;
            outstanding <= 1'b0;
            outstanding_sequence <= 0;
            response_pending <= 1'b0;
            tx_index <= 0;
            last_valid <= 1'b0;
            protocol_error <= V2_ERR_NONE;
            for (i = 0; i < 11; i = i + 1) begin
                frame[i] <= 0;
                outstanding_frame[i] <= 0;
                last_frame[i] <= 0;
            end
            for (i = 0; i < 22; i = i + 1) last_response[i] <= 0;
            for (i = 0; i < 22; i = i + 1) response_bytes[i] <= 0;
        end else begin
            if (cmd_valid && cmd_ready) begin
                cmd_valid <= 1'b0;
                outstanding <= 1'b1;
            end
            if (response_pending && tx_ready) begin
                if (tx_index == 21) begin
                    response_pending <= 1'b0;
                    tx_index <= 0;
                end else tx_index <= tx_index + 1'b1;
            end
            if (rsp_valid && rsp_ready) begin
                response_bytes[0] <= V2_TELEMETRY_SOF;
                response_bytes[1] <= V2_VERSION;
                response_bytes[2] <= (rsp_error == V2_ERR_NONE) ? V2_TLM_ACK : V2_TLM_NACK;
                response_bytes[3] <= 8'h00;
                response_bytes[4] <= rsp_sequence;
                response_bytes[5] <= 8'h00; response_bytes[6] <= 8'h00;
                response_bytes[7] <= 8'h00; response_bytes[8] <= 8'h00;
                response_bytes[9] <= 8'h00; response_bytes[10] <= 8'h00;
                response_bytes[11] <= rsp_status;
                response_bytes[12] <= rsp_terminal;
                response_bytes[13] <= 8'h00;
                response_bytes[14] <= rsp_data[31:24]; response_bytes[15] <= rsp_data[23:16];
                response_bytes[16] <= rsp_data[15:8]; response_bytes[17] <= rsp_data[7:0];
                response_bytes[18] <= 8'h00;
                response_bytes[19] <= rsp_error;
                crc_tmp = 16'hffff;
                for (i = 0; i < 20; i = i + 1)
                    crc_tmp = crc8_step(crc_tmp,
                        (i == 0) ? V2_TELEMETRY_SOF :
                        (i == 1) ? V2_VERSION :
                        (i == 2) ? ((rsp_error == V2_ERR_NONE) ? V2_TLM_ACK : V2_TLM_NACK) :
                        (i == 3) ? 8'h00 : (i == 4) ? rsp_sequence :
                        (i == 11) ? rsp_status : (i == 12) ? rsp_terminal :
                        (i >= 14 && i <= 17) ? rsp_data[31 - ((i-14)*8) -: 8] :
                        (i == 19) ? rsp_error : 8'h00);
                response_bytes[20] <= crc_tmp[15:8];
                response_bytes[21] <= crc_tmp[7:0];
                // Cache the just-built reply from inputs and the blocking CRC
                // accumulator. Copying response_bytes here would cache the
                // previous transaction because its assignments are nonblocking.
                last_response[0] <= V2_TELEMETRY_SOF;
                last_response[1] <= V2_VERSION;
                last_response[2] <= (rsp_error == V2_ERR_NONE) ? V2_TLM_ACK : V2_TLM_NACK;
                last_response[3] <= 8'h00;
                last_response[4] <= rsp_sequence;
                last_response[5] <= 8'h00; last_response[6] <= 8'h00;
                last_response[7] <= 8'h00; last_response[8] <= 8'h00;
                last_response[9] <= 8'h00; last_response[10] <= 8'h00;
                last_response[11] <= rsp_status;
                last_response[12] <= rsp_terminal;
                last_response[13] <= 8'h00;
                last_response[14] <= rsp_data[31:24]; last_response[15] <= rsp_data[23:16];
                last_response[16] <= rsp_data[15:8]; last_response[17] <= rsp_data[7:0];
                last_response[18] <= 8'h00;
                last_response[19] <= rsp_error;
                last_response[20] <= crc_tmp[15:8];
                last_response[21] <= crc_tmp[7:0];
                response_pending <= 1'b1;
                tx_index <= 0;
                outstanding <= 1'b0;
            end

            if (rx_valid && !parse_pending) begin
                if (rx_count == 0) begin
                    if (rx_byte == V2_CONTROL_SOF) begin
                        frame[0] <= rx_byte;
                        rx_count <= 1;
                    end else protocol_error <= V2_ERR_BAD_LENGTH;
                end else begin
                    frame[rx_count] <= rx_byte;
                    if (rx_count == 10) begin
                        rx_count <= 0;
                        parse_pending <= 1'b1;
                    end else rx_count <= rx_count + 1'b1;
                end
            end

            if (parse_pending && !cmd_valid && !outstanding && !response_pending) begin
                parse_pending <= 1'b0;
                expected_crc = control_crc(frame[0],frame[1],frame[2],frame[3],frame[4],
                                            frame[5],frame[6],frame[7],frame[8]);
                crc_good = (expected_crc == {frame[9],frame[10]});
                version_good = (frame[1] == V2_VERSION);
                op_good = (frame[2] == V2_OP_READ) || (frame[2] == V2_OP_WRITE) ||
                          (frame[2] == V2_OP_PING);
                access_good = op_access_ok(frame[2], frame[3]);
                data_good = op_data_ok(frame[2], frame[3],
                    {frame[5],frame[6],frame[7],frame[8]});
                duplicate = last_valid && (frame[4] == last_frame[4]);
                if (duplicate && frame_equal(frame,last_frame)) begin
                    for (i = 0; i < 22; i = i + 1) response_bytes[i] <= last_response[i];
                    response_pending <= 1'b1;
                    tx_index <= 0;
                end else if (duplicate) begin
                    protocol_error <= V2_ERR_SEQUENCE;
                    response_bytes[0] <= V2_TELEMETRY_SOF; response_bytes[1] <= V2_VERSION;
                    response_bytes[2] <= V2_TLM_NACK; response_bytes[3] <= 0; response_bytes[4] <= frame[4];
                    for (i = 5; i < 19; i = i + 1) response_bytes[i] <= 0;
                    response_bytes[19] <= V2_ERR_SEQUENCE;
                    crc_tmp = 16'hffff;
                    for (i = 0; i < 20; i = i + 1) crc_tmp = crc8_step(crc_tmp,
                        (i == 0) ? V2_TELEMETRY_SOF : (i == 1) ? V2_VERSION :
                        (i == 2) ? V2_TLM_NACK : (i == 4) ? frame[4] :
                        (i == 19) ? V2_ERR_SEQUENCE : 0);
                    response_bytes[20] <= crc_tmp[15:8]; response_bytes[21] <= crc_tmp[7:0];
                    response_pending <= 1'b1; tx_index <= 0;
                end else if (!crc_good || !version_good || !op_good ||
                             !access_good || !data_good) begin
                    reject_error = !crc_good ? V2_ERR_BAD_CRC :
                                   !version_good ? V2_ERR_BAD_VERSION :
                                   !op_good ? V2_ERR_BAD_OP :
                                   !access_good ? V2_ERR_BAD_ADDRESS : V2_ERR_BAD_DATA;
                    protocol_error <= reject_error;
                    response_bytes[0] <= V2_TELEMETRY_SOF; response_bytes[1] <= V2_VERSION;
                    response_bytes[2] <= V2_TLM_NACK; response_bytes[3] <= 0; response_bytes[4] <= frame[4];
                    for (i = 5; i < 19; i = i + 1) response_bytes[i] <= 0;
                    response_bytes[19] <= reject_error;
                    crc_tmp = 16'hffff;
                    for (i = 0; i < 20; i = i + 1) crc_tmp = crc8_step(crc_tmp,
                        (i == 0) ? V2_TELEMETRY_SOF : (i == 1) ? V2_VERSION :
                        (i == 2) ? V2_TLM_NACK : (i == 4) ? frame[4] :
                        (i == 19) ? reject_error : 0);
                    response_bytes[20] <= crc_tmp[15:8]; response_bytes[21] <= crc_tmp[7:0];
                    response_pending <= 1'b1; tx_index <= 0;
                end else begin
                    cmd_op <= frame[2]; cmd_address <= frame[3]; cmd_sequence <= frame[4];
                    cmd_data <= {frame[5],frame[6],frame[7],frame[8]};
                    for (i = 0; i < 11; i = i + 1) begin
                        outstanding_frame[i] <= frame[i];
                        last_frame[i] <= frame[i];
                    end
                    outstanding_sequence <= frame[4];
                    last_valid <= 1'b1;
                    cmd_valid <= 1'b1;
                end
            end
        end
    end
endmodule
