// MD-VDPX ECP5-P1: TMDS serializer for the LFE5U (replaces the Gowin OSER10 + TLVDS_OBUF).
//
// clk_pix (25 MHz) and clk_x5 (125 MHz) come from the same EHXPLLL VCO (500 MHz), rising
// edges aligned. Each 10-bit TMDS symbol is sent LSB first as 5 x 2 bits through an
// ODDRX1F per lane (D0 first, then D1: Lattice FPGA-TN-02035, table 8.12), i.e.
// 250 Mbit/s per lane = 10 x 25 MHz.
//
// Load timing (no handshake on the fast side, related clocks):
//   pix edge E      : h* <= symbol, ptog flips
//   x5 edges E+1..2 : ptog sampled twice (ts[0], ts[1])
//   x5 edge  E+3    : ts[2]^ts[1] = 1 -> shift registers load h* (h* stable since E,
//                     next change at E+5): load exactly once every 5 fast cycles.
// The clock lane carries 1111100000 (5 bits high, 5 low), loaded together with the data,
// so the TMDS clock edge marks the symbol boundary on every lane.
//
// Own implementation (no code copied). Reference for the technique: ECP5 GPDI/HDMI
// projects (e.g. ULX3S, danodus/ecp5_hdmi_audio_video) use the same ODDRX1F + 5:1 scheme.
module ecp5_tmds_ser (
    input        clk_pix,
    input        clk_x5,
    input        rst_x5,           // synchronous to clk_x5
    input  [9:0] t0, t1, t2,       // TMDS symbols (pixel domain): blue, green, red
    output [3:0] q                 // to the pads: [0..2] data lanes, [3] clock lane
);
    // ---- pixel domain
    reg [9:0] h0 = 10'd0, h1 = 10'd0, h2 = 10'd0;
    reg       ptog = 1'b0;
    always @(posedge clk_pix) begin
        h0 <= t0; h1 <= t1; h2 <= t2;
        ptog <= ~ptog;
    end

    // ---- 125 MHz domain
    reg [2:0] ts = 3'd0;
    wire      load = ts[2] ^ ts[1];
    reg [9:0] s0 = 10'd0, s1 = 10'd0, s2 = 10'd0, sc = 10'd0;
    always @(posedge clk_x5) begin
        ts <= {ts[1:0], ptog};
        if (rst_x5) begin
            s0 <= 10'd0; s1 <= 10'd0; s2 <= 10'd0; sc <= 10'd0;
        end else if (load) begin
            s0 <= h0; s1 <= h1; s2 <= h2; sc <= 10'b0000011111;
        end else begin
            s0 <= s0 >> 2; s1 <= s1 >> 2; s2 <= s2 >> 2; sc <= sc >> 2;
        end
    end

    ODDRX1F u_d0 (.SCLK(clk_x5), .RST(1'b0), .D0(s0[0]), .D1(s0[1]), .Q(q[0]));
    ODDRX1F u_d1 (.SCLK(clk_x5), .RST(1'b0), .D0(s1[0]), .D1(s1[1]), .Q(q[1]));
    ODDRX1F u_d2 (.SCLK(clk_x5), .RST(1'b0), .D0(s2[0]), .D1(s2[1]), .Q(q[2]));
    ODDRX1F u_ck (.SCLK(clk_x5), .RST(1'b0), .D0(sc[0]), .D1(sc[1]), .Q(q[3]));
endmodule
