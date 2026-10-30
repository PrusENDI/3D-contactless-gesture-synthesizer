module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output wire       busy
);
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    reg [15:0] baud_count;
    reg [3:0]  bit_count;
    reg [9:0]  shift_reg;
    reg        active;

    assign busy = active;

    always @(posedge clk) begin
        if (rst) begin
            baud_count <= 16'd0;
            bit_count  <= 4'd0;
            shift_reg  <= 10'b11_1111_1111;
            active     <= 1'b0;
            tx         <= 1'b1;
        end else if (!active) begin
            tx <= 1'b1;
            if (start) begin
                // 8-N-1, LSB first: start, 8 data bits, stop.
                shift_reg  <= {1'b1, data, 1'b0};
                baud_count <= 16'd0;
                bit_count  <= 4'd0;
                active     <= 1'b1;
                tx         <= 1'b0;
            end
        end else if (baud_count == CLKS_PER_BIT - 1) begin
            baud_count <= 16'd0;
            if (bit_count == 4'd9) begin
                active <= 1'b0;
                tx     <= 1'b1;
            end else begin
                bit_count <= bit_count + 1'b1;
                shift_reg <= {1'b1, shift_reg[9:1]};
                tx        <= shift_reg[1];
            end
        end else begin
            baud_count <= baud_count + 1'b1;
        end
    end
endmodule
