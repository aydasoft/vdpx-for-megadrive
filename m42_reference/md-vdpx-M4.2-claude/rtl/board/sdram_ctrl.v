// Controller for the SDRAM inside the GW2AR-18 (64 Mbit, 2M x 32, 4 banks,
// 2048 rows x 256 columns). One 16-bit access at a time, ACTIVE + READ/WRITE
// with auto-precharge (close page), periodic AUTO REFRESH.
//
// Clock: the SDRAM clock pin is the inverted system clock (50.4 MHz), so
// commands launched on a rising edge are sampled half a cycle later.
// With CAS latency 2 the SDRAM drives the data ~tAC after its edge N+1 and holds it
// until edge N+2 (N = edge that samples READ = half a cycle after we register it),
// so it is captured 2 rising edges after the READ command was registered.
//
// Word address (16-bit units, 22 bits = 8 MB):
//   a[0]      halfword (0 = DQ[15:0], 1 = DQ[31:16])
//   a[8:1]    column, a[10:9] bank, a[21:11] row
module sdram_ctrl #(
    parameter INIT_CYCLES = 10080,     // 200 us at 50.4 MHz
    parameter REFRESH_INT = 700,       // < 15.6 us (4096 rows / 64 ms)
    parameter RD_CAPTURE  = 2
) (
    input             clk,
    input             rst,

    input             req,             // held until ack (one access per request)
    input             we,
    input      [21:0] addr,
    input      [15:0] wdata,
    output reg        ack,
    output reg [15:0] rdata,
    output reg        ready,           // init done

    output reg        sd_cke,
    output reg        sd_cs_n,
    output reg        sd_ras_n,
    output reg        sd_cas_n,
    output reg        sd_we_n,
    output reg  [1:0] sd_ba,
    output reg [10:0] sd_a,
    output reg  [3:0] sd_dqm,
    output reg [31:0] sd_dq_out,
    output reg        sd_dq_oe,
    input      [31:0] sd_dq_in
);
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    // mode register: burst length 1, sequential, CAS latency 2, programmed-burst writes
    localparam [10:0] MODE = 11'b000_0_00_010_0_000;

    localparam [3:0] S_INIT = 0, S_PALL = 1, S_REF1 = 2, S_REF2 = 3, S_MRS = 4,
                     S_IDLE = 5, S_ACT = 6, S_RW = 7, S_WAIT = 8, S_REF = 9;

    reg  [3:0] st;
    reg [13:0] cnt;                    // general delay counter
    reg  [9:0] rcnt;                   // refresh interval counter
    reg        ref_pend;
    reg  [3:0] wait_n;
    reg        cur_we, cur_hi;
    reg [15:0] cur_wd;
    reg  [2:0] rd_pipe;                // read capture pipeline

    task cmd(input [3:0] c);
        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= c;
    endtask

    always @(posedge clk) begin
        ack <= 1'b0;
        cmd(C_NOP);
        sd_dq_oe <= 1'b0;
        rd_pipe <= {rd_pipe[1:0], 1'b0};
        if (rd_pipe[RD_CAPTURE-1]) begin
            rdata <= cur_hi ? sd_dq_in[31:16] : sd_dq_in[15:0];
        end
        if (rst) begin
            st <= S_INIT; cnt <= 0; ready <= 1'b0; sd_cke <= 1'b0;
            rcnt <= 0; ref_pend <= 1'b0; sd_dqm <= 4'hF; rd_pipe <= 0;
        end else begin
            // refresh timer
            if (ready) begin
                if (rcnt == REFRESH_INT[9:0]) begin rcnt <= 0; ref_pend <= 1'b1; end
                else rcnt <= rcnt + 10'd1;
            end
            case (st)
            S_INIT: begin
                sd_cke <= 1'b1;
                if (cnt == INIT_CYCLES[13:0]) begin cnt <= 0; st <= S_PALL; end
                else cnt <= cnt + 14'd1;
            end
            S_PALL: begin
                if (cnt == 0) begin cmd(C_PRE); sd_a <= 11'h400; end   // A10 = all banks
                cnt <= cnt + 14'd1;
                if (cnt == 14'd3) begin cnt <= 0; st <= S_REF1; end
            end
            S_REF1, S_REF2: begin
                if (cnt == 0) cmd(C_REF);
                cnt <= cnt + 14'd1;
                if (cnt == 14'd6) begin cnt <= 0; st <= (st == S_REF1) ? S_REF2 : S_MRS; end
            end
            S_MRS: begin
                if (cnt == 0) begin cmd(C_MRS); sd_a <= MODE; sd_ba <= 2'b00; end
                cnt <= cnt + 14'd1;
                if (cnt == 14'd3) begin cnt <= 0; st <= S_IDLE; ready <= 1'b1; end
            end
            S_IDLE: begin
                if (ref_pend) begin
                    ref_pend <= 1'b0;
                    cmd(C_REF);
                    wait_n <= 4'd6;                        // tRFC
                    st <= S_WAIT;
                end else if (req) begin
                    cmd(C_ACT);
                    sd_ba <= addr[10:9];
                    sd_a  <= addr[21:11];
                    cur_we <= we; cur_hi <= addr[0]; cur_wd <= wdata;
                    sd_dqm <= 4'h0;
                    cnt <= {6'd0, addr[8:1]};               // keep the column
                    st <= S_ACT;
                end
            end
            S_ACT: st <= S_RW;                               // tRCD = 2 cycles
            S_RW: begin
                cmd(cur_we ? C_WR : C_RD);
                sd_a <= {3'b100, cnt[7:0]};                  // A10 = auto precharge
                if (cur_we) begin
                    sd_dq_oe  <= 1'b1;
                    sd_dq_out <= {cur_wd, cur_wd};
                    sd_dqm    <= cur_hi ? 4'b0011 : 4'b1100;
                    wait_n    <= 4'd4;                       // tWR + tRP
                    ack       <= 1'b1;
                end else begin
                    sd_dqm  <= 4'h0;
                    rd_pipe <= 3'b001;
                    wait_n  <= 4'd4;                         // CL + tRP
                end
                st <= S_WAIT;
            end
            S_WAIT: begin
                if (rd_pipe[RD_CAPTURE-1]) ack <= 1'b1;    // read data valid next cycle with ack
                if (wait_n == 0) st <= S_IDLE;
                else wait_n <= wait_n - 4'd1;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
