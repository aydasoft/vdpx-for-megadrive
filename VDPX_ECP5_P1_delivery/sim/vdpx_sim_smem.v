// Behavioral sample memory for simulation (stands in for the Tang SDRAM).
// Fixed latency, one access at a time, ack is a one-cycle pulse.
module vdpx_sim_smem #(
    parameter AW  = 20,
    parameter LAT = 6
) (
    input               clk,
    input               req,
    input               we,
    input      [AW-1:0] addr,
    input        [15:0] wdata,
    output reg          ack,
    output reg   [15:0] rdata
);
    reg [15:0] mem [0:(1<<AW)-1];
    reg  [3:0] cnt;
    reg        busy;
    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = 16'd0;
        busy = 0; ack = 0; cnt = 0;
    end
    always @(posedge clk) begin
        ack <= 1'b0;
        if (!busy) begin
            if (req && !ack) begin busy <= 1'b1; cnt <= LAT[3:0]; end
        end else if (cnt != 0) begin
            cnt <= cnt - 4'd1;
        end else begin
            if (we) mem[addr] <= wdata;
            rdata <= mem[addr];
            ack <= 1'b1;
            busy <= 1'b0;
        end
    end
endmodule
