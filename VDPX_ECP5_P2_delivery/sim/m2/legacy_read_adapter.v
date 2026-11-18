// Historical FIFO/read heuristic intentionally retained ONLY for M2 baseline.
// Unsafe for physical CN2; excluded when SYNTHESIS is defined.
`ifndef SYNTHESIS
// SIMULATION ONLY: historical M4.1 assumed read protocol, NOT CN2 evidence.
module legacy_read_adapter #(
    parameter USE_CAS0  = 1,
    parameter RD_DETECT = 8
) (
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

    output reg        late_read,      // sticky: a read was answered too late / not at all
    output reg        activity        // pulse on every access
);
    // ---- synchronizers
    reg [1:0] fdc_s, fdwr_s, cas0_s;
    always @(posedge clk) begin
        fdc_s  <= {fdc_s[0],  fdc_n};
        fdwr_s <= {fdwr_s[0], fdwr_n};
        cas0_s <= {cas0_s[0], cas0_n};
    end
    wire fdc  = ~fdc_s[1];
    wire fdwr = ~fdwr_s[1];
    wire cas0 = ~cas0_s[1];

    // ---- write FIFO (16 x 19 bits)
    reg [18:0] wf [0:15];
    reg  [4:0] wf_wr, wf_rd;
    wire       wf_empty = (wf_wr == wf_rd);
    always @(posedge clk) begin
        if (rst) begin
            wf_rd <= 0; core_cs <= 1'b0;
        end else if (!core_cs) begin
            if (!wf_empty) begin
                core_cs <= 1'b1; core_we <= 1'b1;
                {core_addr, core_wdata} <= wf[wf_rd[3:0]];
            end
        end else if (core_ack) begin
            core_cs <= 1'b0;
            wf_rd <= wf_rd + 5'd1;
        end
    end

    // ---- bus cycle tracking
    localparam [2:0] S_IDLE = 0, S_CYC = 1, S_WR = 2, S_WEND = 3, S_RD = 4;
    reg [2:0] st;
    reg [4:0] cnt;
    wire is_read = USE_CAS0 ? cas0 : (cnt >= RD_DETECT[4:0]);

    always @(posedge clk) begin
        rd_commit <= 1'b0;
        activity  <= 1'b0;
        if (rst) begin
            st <= S_IDLE; d_oe <= 1'b0; wf_wr <= 0; late_read <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                d_oe <= 1'b0;
                if (fdc) begin
                    peek_addr <= a;              // the address is stable before /FDC
                    cnt <= 0;
                    activity <= 1'b1;
                    st <= S_CYC;
                end
            end
            S_CYC: begin
                if (cnt != 5'd31) cnt <= cnt + 5'd1;
                if (!fdc) begin
                    late_read <= 1'b1;          // the cycle ended before we answered
                    st <= S_IDLE;
                end else if (fdwr) begin
                    st <= S_WR;
                end else if (is_read && cnt != 0 && wf_empty && !core_cs && peek_valid) begin
                    d_out <= peek_data;
                    d_oe  <= 1'b1;
                    st <= S_RD;
                end
            end
            S_WR: begin                          // /FDWR low for 2+ cycles: data is stable
                wf[wf_wr[3:0]] <= {peek_addr, d_in};
                wf_wr <= wf_wr + 5'd1;
                st <= S_WEND;
            end
            S_WEND: if (!fdc) st <= S_IDLE;
            S_RD: begin
                if (!fdc) begin
                    d_oe <= 1'b0;
                    rd_commit <= 1'b1;
                    rd_commit_addr <= peek_addr;
                    st <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`endif
