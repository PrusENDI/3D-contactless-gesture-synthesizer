// 8N1 UART receiver.
//
// Sampling follows the board vendor's Tang Primer 25K example: a falling edge
// starts the frame, the first data bit is sampled 1.5 bit times later, the rest
// one bit apart, and the stop bit half a bit after the eighth sample.
//
// The eight data bits are collected into eight named registers with an explicit
// case on the bit index, then concatenated into the output.  Both alternatives
// failed on this tool: shift[bit_index] made GowinSynthesis drop bits 7:1 of the
// output (netlist data port one bit wide, upper output buffers tied to GND), and
// a plain shift register made the full design inflate to 34k LUTs (RP0006).
module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg        valid,
    input  wire       ready,
    output reg  [7:0] data,
    output reg        framing_error
);
    localparam integer CLKS_PER_BIT = (CLK_HZ / BAUD) < 4 ? 4 : (CLK_HZ / BAUD);
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;
    localparam [15:0] CLKS_PER_BIT_M1 = CLKS_PER_BIT - 1;
    localparam [15:0] HALF_BIT_M1     = HALF_BIT - 1;

    reg [15:0] count;
    reg [3:0]  bit_index;
    reg        active;
    reg        rx_meta, rx_sync;

    reg b0, b1, b2, b3, b4, b5, b6, b7;

    always @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1'b1; rx_sync <= 1'b1;
            valid <= 1'b0; data <= 8'd0; framing_error <= 1'b0;
            count <= 16'd0; bit_index <= 4'd0; active <= 1'b0;
            b0 <= 1'b0; b1 <= 1'b0; b2 <= 1'b0; b3 <= 1'b0;
            b4 <= 1'b0; b5 <= 1'b0; b6 <= 1'b0; b7 <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            if (valid && ready) begin
                valid <= 1'b0;
                framing_error <= 1'b0;
            end
            if (!active && !valid && !rx_sync) begin
                active    <= 1'b1;
                count     <= CLKS_PER_BIT + HALF_BIT_M1;   // centre of d0
                bit_index <= 4'd0;
            end else if (active) begin
                if (count != 0) begin
                    count <= count - 1'b1;
                end else begin
                    count <= CLKS_PER_BIT_M1;
                    case (bit_index)
                        4'd0: b0 <= rx;
                        4'd1: b1 <= rx;
                        4'd2: b2 <= rx;
                        4'd3: b3 <= rx;
                        4'd4: b4 <= rx;
                        4'd5: b5 <= rx;
                        4'd6: b6 <= rx;
                        4'd7: b7 <= rx;
                        default: ;
                    endcase
                    if (bit_index <= 4'd7) begin
                        bit_index <= bit_index + 1'b1;
                    end else begin
                        active <= 1'b0;
                        data   <= {b7, b6, b5, b4, b3, b2, b1, b0};
                        valid  <= 1'b1;
                        framing_error <= !rx;
                    end
                end
            end
        end
    end
endmodule
