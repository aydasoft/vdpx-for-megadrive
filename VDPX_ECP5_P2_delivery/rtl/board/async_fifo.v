// Small asynchronous FIFO (Gray-code pointers, 2-FF synchronizers).
module async_fifo #(
    parameter DW = 27,
    parameter AW = 4
) (
    input           wclk,
    input           wrst,
    input           we,
    input  [DW-1:0] wdata,
    output          wfull,
    input           rclk,
    input           rrst,
    input           re,
    output [DW-1:0] rdata,
    output          rempty,
    output [AW:0]   rlevel          // approximate fill level seen by the reader
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] wq1, wq2, rq1, rq2;   // synchronized pointers (gray)

    function [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    wire [AW:0] wbin_n = wbin + {{AW{1'b0}}, (we && !wfull)};
    always @(posedge wclk) begin
        if (wrst) begin
            wbin <= 0; wgray <= 0; rq1 <= 0; rq2 <= 0;
        end else begin
            if (we && !wfull) mem[wbin[AW-1:0]] <= wdata;
            wbin <= wbin_n;
            wgray <= wbin_n ^ (wbin_n >> 1);
            rq1 <= rgray; rq2 <= rq1;
        end
    end
    assign wfull = (wgray == {~rq2[AW:AW-1], rq2[AW-2:0]});

    wire [AW:0] rbin_n = rbin + {{AW{1'b0}}, (re && !rempty)};
    always @(posedge rclk) begin
        if (rrst) begin
            rbin <= 0; rgray <= 0; wq1 <= 0; wq2 <= 0;
        end else begin
            rbin <= rbin_n;
            rgray <= rbin_n ^ (rbin_n >> 1);
            wq1 <= wgray; wq2 <= wq1;
        end
    end
    assign rempty = (rgray == wq2);
    assign rdata  = mem[rbin[AW-1:0]];
    assign rlevel = g2b(wq2) - rbin;
endmodule
