// 640x480@60 timing (800x525 total), negative syncs.
// Counters advance on 'ce' (pixel clock enable; system clock = 2x pixel clock).
module vdpx_timing (
    input            clk,
    input            rst,
    input            ce,
    output reg [9:0] hc,
    output reg [9:0] vc,
    output           de,
    output           hsync_n,
    output           vsync_n
);
    localparam H_ACT = 640, H_FP = 16, H_SYNC = 96, H_TOT = 800;
    localparam V_ACT = 480, V_FP = 10, V_SYNC = 2,  V_TOT = 525;

    always @(posedge clk) begin
        if (rst) begin
            hc <= 0; vc <= 0;
        end else if (ce) begin
            if (hc == H_TOT-1) begin
                hc <= 0;
                vc <= (vc == V_TOT-1) ? 10'd0 : vc + 10'd1;
            end else begin
                hc <= hc + 10'd1;
            end
        end
    end

    assign de      = (hc < H_ACT) && (vc < V_ACT);
    assign hsync_n = ~((hc >= H_ACT+H_FP) && (hc < H_ACT+H_FP+H_SYNC));
    assign vsync_n = ~((vc >= V_ACT+V_FP) && (vc < V_ACT+V_FP+V_SYNC));
endmodule
