// M4.2 WRITE ONLY. CAS0 and peek inputs intentionally have no effect.
// Bundled data/address must remain stable through the synchronized capture:
// >= 4 clk periods after both strobes assert. No physical backpressure.
// FIFO capacity includes the outstanding core request; full drops NEWEST.
module md_fdc_adapter (
    input             clk,
    input             rst,

    input             fdc_n,
    input             fdwr_n,
    input             cas0_n,
    input       [3:1] a,
    input      [15:0] d_in,
    output reg [15:0] d_out,
    output reg        d_oe,          // FPGA drives its side of the data buffer

    // VDPX write bus
    output reg        core_cs,
    output reg        core_we,
    output reg  [2:0] core_addr,
    output reg [15:0] core_wdata,
    input             core_ack,
    // VDPX immediate reads
    output reg  [2:0] peek_addr,
    input      [15:0] peek_data,
    input             peek_valid,
    output reg        rd_commit,
    output reg  [2:0] rd_commit_addr,

    output reg        late_read,      // retained interface: always zero (no reads)
    output reg        activity,       // pulse on accepted write
    output reg        overflow,       // sticky until reset; newest write rejected
    output reg        drop,           // pulse: one write rejected (FIFO full)
    output      [4:0] fifo_level
);
    reg [1:0] fdc_s, fdwr_s;
    reg armed, seen;
    reg [18:0] wf [0:15];
    reg [4:0] wr, rd;
    assign fifo_level = wr - rd;
    wire empty = wr == rd;
    wire full = fifo_level == 5'd16;
    wire pop = core_cs && core_ack;
    wire capture = armed && !seen && !fdc_s[1] && !fdwr_s[1];
    always @(posedge clk) begin
        if (rst) begin
            fdc_s <= 2'b11; fdwr_s <= 2'b11;
            armed <= 0; seen <= 0; wr <= 0; rd <= 0;
            core_cs <= 0; core_we <= 1; core_addr <= 0; core_wdata <= 0;
            d_out <= 0; d_oe <= 0; peek_addr <= 0;
            rd_commit <= 0; rd_commit_addr <= 0; late_read <= 0;
            activity <= 0; overflow <= 0; drop <= 0;
        end else begin
            fdc_s <= {fdc_s[0], fdc_n};
            fdwr_s <= {fdwr_s[0], fdwr_n};
            activity <= 0;
            drop <= 0;
            // Re-arm only after actual idle traverses both synchronizers.
            // Raw high qualification prevents accepting a held-low reset cycle.
            if (fdc_s == 2'b11 && fdwr_s == 2'b11 && fdc_n && fdwr_n) begin
                armed <= 1; seen <= 0;
            end
            if (capture) begin
                seen <= 1;
                if (!full || pop) begin
                    wf[wr[3:0]] <= {a, d_in}; wr <= wr + 5'd1;
                    activity <= 1;
                end else begin overflow <= 1; drop <= 1; end
            end
            if (!core_cs && !empty) begin
                {core_addr, core_wdata} <= wf[rd[3:0]];
                core_cs <= 1;
            end else if (pop) begin
                core_cs <= 0; rd <= rd + 5'd1;
            end
        end
    end
endmodule
