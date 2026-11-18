// Simple dual-port RAM (1 write port, 1 read port), single clock,
// 1-cycle read latency. Pattern infers Gowin SDP BSRAM.
module vdpx_sdpram #(
    parameter AW = 15,
    parameter DW = 16
) (
    input               clk,
    input      [AW-1:0] raddr,
    output reg [DW-1:0] rdata,
    input      [AW-1:0] waddr,
    input               we,
    input      [DW-1:0] wdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

`ifndef SYNTHESIS
    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
    end
`endif

    always @(posedge clk) rdata <= mem[raddr];
    always @(posedge clk) if (we) mem[waddr] <= wdata;
endmodule
