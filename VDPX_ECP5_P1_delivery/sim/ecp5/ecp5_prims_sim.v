// Behavioral simulation model of the ECP5 ODDRX1F (Yosys ships only a black box).
// Lattice FPGA-TN-02035 table 8.12: "D0, D1: parallel data input to ODDR (D0 is sent out
// first then D1)", "Q: DDR data output on both edges of SCLK".
// Model: D0/D1 captured on the rising SCLK edge; Q = D0 while SCLK is high, D1 while low.
// The real primitive adds a fixed pipeline delay; the testbenches never rely on the
// absolute latency (symbols are aligned with the TMDS clock lane, which goes through an
// identical ODDRX1F), only on the order D0 -> D1 and on equal latency for every lane.
module ODDRX1F (
    input  SCLK,
    input  RST,
    input  D0,
    input  D1,
    output Q
);
    parameter GSR = "ENABLED";
    reg qp = 1'b0, d1r = 1'b0, qn = 1'b0;
    always @(posedge SCLK) begin
        qp  <= RST ? 1'b0 : D0;
        d1r <= RST ? 1'b0 : D1;
    end
    always @(negedge SCLK) qn <= d1r;
    assign Q = SCLK ? qp : qn;
endmodule
