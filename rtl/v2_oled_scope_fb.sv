// 128x64 mono framebuffer for the scope picture: one BSRAM, two ports.
//
// Port A is the plotter (read-modify-write of one bit), port B is the refresh
// stream (read a column byte, hand it to the SPI shifter, write back a decayed
// copy).  Same clock, so this is a plain dual-port block RAM.
module v2_oled_scope_fb (
    input  logic       clk,
    // port A: plotter
    input  logic [9:0] a_addr,
    input  logic [7:0] a_wdata,
    input  logic       a_we,
    output logic [7:0] a_rdata,
    // port B: refresh stream
    input  logic [9:0] b_addr,
    input  logic [7:0] b_wdata,
    input  logic       b_we,
    output logic [7:0] b_rdata
);
    (* ram_style = "block" *) logic [7:0] mem [0:1023];

    // Write-through reads: Gowin rejects the read-before-write DPB mode
    // (PA2122).  Both users therefore read in a cycle where their own write
    // enable is low, so the priority mux never changes what they see.
    always_ff @(posedge clk) begin
        a_rdata <= a_we ? a_wdata : mem[a_addr];
        if (a_we) mem[a_addr] <= a_wdata;
        b_rdata <= b_we ? b_wdata : mem[b_addr];
        if (b_we) mem[b_addr] <= b_wdata;
    end
endmodule
