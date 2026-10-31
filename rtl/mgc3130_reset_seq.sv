module mgc3130_reset_seq #(
    // The working reference design held MCLR low for 250 ms and then waited 2 s
    // before the first I2C access; without that pulse the sensor never reports.
    parameter integer CLK_HZ = 80_000_000,
    parameter integer RESET_LOW_MS = 250,
    parameter integer STARTUP_WAIT_MS = 2000
) (
    input  wire clk,
    output wire mclr_drive_low,
    output wire ready
);
    localparam integer LOW_TICKS  = (CLK_HZ / 1000) * RESET_LOW_MS;
    localparam integer WAIT_TICKS = (CLK_HZ / 1000) * STARTUP_WAIT_MS;
    reg [31:0] count;
    reg [1:0] state;
    localparam [1:0] ST_LOW = 2'd0, ST_WAIT = 2'd1, ST_READY = 2'd2;
    assign mclr_drive_low = (state == ST_LOW);
    assign ready = (state == ST_READY);
    always @(posedge clk) begin
        case (state)
            ST_LOW: begin
                if (count >= LOW_TICKS-1) begin count <= 0; state <= ST_WAIT; end
                else count <= count + 1'b1;
            end
            ST_WAIT: begin
                if (count >= WAIT_TICKS-1) begin count <= 0; state <= ST_READY; end
                else count <= count + 1'b1;
            end
            default: begin count <= 0; state <= ST_READY; end
        endcase
    end
    initial begin count = 0; state = ST_LOW; end
endmodule
