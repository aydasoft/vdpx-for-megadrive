// MD-VDPX ECP5-P2: DMA / blitter engine (clk_sys).
//
// Programming (write-only, through the DATA port with ACC_TGT = 6, index = ACC_ADDR[2:0];
// see DMA_REGISTER_MAP.md):
//   0 SRC_LO  1 SRC_HI  2 DST  3 LEN  4 VALUE0  5 VALUE1  6 (reserved, ignored)  7 COMMAND
// Parameters are staging registers. A write to COMMAND validates them and, if valid, copies
// all of them at once into a command queue entry (atomic commit): later writes to the
// staging registers never affect a queued or running command.
//   COMMAND[2:0]  op: 1 FILL (VALUE0), 2 COPY (sample memory -> VRAM), 3 PATTERN (VALUE0,
//                 VALUE1, VALUE0, ...), 4 CANCEL (stop the running command at a safe point and
//                 flush the queue; never queued). Any other value is rejected.
//   COMMAND[3]    VSYNC: the command starts at the next rising edge of vblank.
//   COMMAND[15:8] tag (diagnostics only).
// Rejection codes (command dropped, nothing written, n_rejected++, last_err = code):
//   1 ZERO_LEN  2 DST_RANGE (DST[15] set or DST+LEN > 32768)  3 SRC_RANGE (COPY: SRC+LEN beyond
//   the sample memory)  4 QUEUE_FULL  5 INCOMPLETE (a parameter the op needs was never written
//   since reset)  6 BAD_OP. Checked in this order. No address ever wraps.
//
// Ports:
//   VRAM write: vw_req/vw_addr/vw_data stay valid until vw_gnt; the write happens in the
//               cycle vw_gnt is high (top-level arbiter, CPU writes first).
//   Sample memory read: sm_req held until sm_ack (one access per request); sm_pair = two words
//               (sm_addr even, +1) from one 32-bit SDRAM access, returned in sm_rdata/_hi.
// Cancel: a sample-memory read already issued always completes (data discarded); no VRAM write
// is issued once the cancel is seen; the end event reports the VRAM writes actually done.
module vdpx_dma #(
    parameter SMEM_AW = 22,
    parameter QD_LOG  = 2                 // queue depth 4
) (
    input                    clk,
    input                    rst,
    input                    vblank,

    input                    cfg_we,
    input              [2:0] cfg_idx,
    input             [15:0] cfg_data,

    output                   vw_req,
    output            [14:0] vw_addr,
    output            [15:0] vw_data,
    input                    vw_gnt,

    output reg               sm_req,
    output reg [SMEM_AW-1:0] sm_addr,
    output reg               sm_pair,
    input                    sm_ack,
    input             [15:0] sm_rdata,
    input             [15:0] sm_rdata_hi,
    input                    sm_wait,     // our request waits behind another SDRAM owner

    // status (HDMI panel, simulation reads of target 6)
    output                   busy,
    output reg         [1:0] disp_state,  // 0 IDLE 1 BUSY 2 DONE 3 ERROR (last command rejected)
    output reg         [1:0] disp_op,     // 0 none 1 FILL 2 COPY 3 PATTERN (running or last)
    output       [QD_LOG:0]  q_level,
    output reg        [15:0] words_cur,   // words written by the running / last command
    output reg        [23:0] cycles_last, // run cycles of the last command (VSYNC wait excluded)
    output reg        [15:0] stalls_last, // cycles without VRAM grant or behind another SDRAM owner
    output reg        [15:0] n_accepted, n_rejected, n_done, n_cancelled,
    output reg         [3:0] last_err,
    output reg        [15:0] rate_bcd,    // last command: words*1000/cycles, 4 BCD digits
    output reg         [7:0] last_tag,

    // events (one-cycle pulses) for the testbench scoreboards
    output reg               ev_accept,
    output reg               ev_reject,
    output reg         [3:0] ev_code,
    output reg               ev_start,    // head of queue starts (before any VSYNC wait)
    output reg               ev_end,      // running command ended (done or cancelled)
    output reg               ev_end_cancelled,
    output reg        [15:0] ev_words,    // VRAM writes of the ended command
    output reg               ev_cancel_cmd,
    output reg         [2:0] ev_flushed   // queued (not started) commands removed by CANCEL
);
    localparam QD = 1 << QD_LOG;
    localparam [2:0] OP_FILL = 3'd1, OP_COPY = 3'd2, OP_PATT = 3'd3, OP_CANCEL = 3'd4;
    localparam [3:0] E_OK = 4'd0, E_ZERO = 4'd1, E_DST = 4'd2, E_SRC = 4'd3, E_QFULL = 4'd4,
                     E_INCOMPLETE = 4'd5, E_BADOP = 4'd6;

    // ------------------------------------------------------------ staging registers
    reg [15:0] s_src_lo, s_src_hi, s_dst, s_len, s_v0, s_v1;
    reg  [5:0] s_valid;

    // ------------------------------------------------------------ validation (at commit)
    wire [2:0]  c_opc    = cfg_data[2:0];
    wire        commit   = cfg_we && cfg_idx == 3'd7;
    wire        do_cancel = commit && c_opc == OP_CANCEL;
    wire [31:0] src      = {s_src_hi, s_src_lo};
    wire [16:0] dst_end  = {1'b0, s_dst} + {1'b0, s_len};
    wire [32:0] src_end  = {1'b0, src} + {17'd0, s_len};
    wire        need_src = (c_opc == OP_COPY);
    wire        need_v0  = (c_opc == OP_FILL) || (c_opc == OP_PATT);
    wire        need_v1  = (c_opc == OP_PATT);
    wire        complete = s_valid[2] && s_valid[3] && (!need_src || (s_valid[0] && s_valid[1])) &&
                           (!need_v0 || s_valid[4]) && (!need_v1 || s_valid[5]);
    reg  [QD_LOG:0] q_cnt;
    reg   [3:0] v_code;
    always @(*) begin
        if (!(c_opc == OP_FILL || c_opc == OP_COPY || c_opc == OP_PATT)) v_code = E_BADOP;
        else if (!complete)                                 v_code = E_INCOMPLETE;
        else if (s_len == 16'd0)                            v_code = E_ZERO;
        else if (s_dst[15] || dst_end > 17'd32768)          v_code = E_DST;
        else if (need_src && src_end > (33'd1 << SMEM_AW))  v_code = E_SRC;
        else if (q_cnt == QD)                               v_code = E_QFULL;
        else                                                v_code = E_OK;
    end
    wire push = commit && !do_cancel && v_code == E_OK;

    // ------------------------------------------------------------ command queue
    localparam SW = SMEM_AW;
    localparam P_SRC = 0, P_DST = SW, P_LEN = SW + 15, P_V0 = SW + 31, P_V1 = SW + 47,
               P_OP = SW + 63, P_VS = SW + 65, P_TAG = SW + 66, EW = SW + 74;
    reg [EW-1:0]     q_mem [0:QD-1];
    reg [QD_LOG-1:0] q_wr, q_rd;
    wire [EW-1:0]    head = q_mem[q_rd];
    assign q_level = q_cnt;

    // ------------------------------------------------------------ engine state
    localparam [2:0] S_IDLE = 0, S_VWAIT = 1, S_FILL = 2, S_RD = 3, S_WR = 4;
    reg  [2:0] st;
    reg  [1:0] c_op;
    reg [SW-1:0] c_src;
    reg [14:0] c_dst;
    reg [15:0] c_rem, c_v0, c_v1, buf0, buf1;
    reg        c_ph, b_idx, b_two, cancel_pend, vb_d;
    reg [23:0] c_cyc;
    reg [15:0] c_stall;

    wire running = (st == S_FILL) || (st == S_WR) || (st == S_RD);
    assign busy    = (st != S_IDLE) || (q_cnt != 0);
    assign vw_req  = (st == S_FILL) || (st == S_WR);
    assign vw_addr = c_dst;
    assign vw_data = (st == S_WR) ? (b_idx ? buf1 : buf0) : ((c_op == 2'd3 && c_ph) ? c_v1 : c_v0);
    wire   wrote   = vw_req && vw_gnt;
    wire   last_wr = wrote && c_rem == 16'd1;
    // the running command ends this cycle (normally, or by a cancel at a safe point)
    wire   end_norm = (st == S_FILL || st == S_WR) && last_wr;
    wire   end_canc = !end_norm && cancel_pend &&
                      ((st == S_FILL || st == S_WR) || (st == S_RD && (!sm_req || sm_ack)) || st == S_VWAIT);
    wire   pop      = st == S_IDLE && q_cnt != 0 && !do_cancel;

    // ------------------------------------------------------------ rate: words*1000/cycles
    reg        r_run, r_fin;
    reg  [4:0] r_i;
    reg [25:0] r_num, r_rem;
    reg [24:0] r_den;
    reg [10:0] r_q;
    // quotient -> 4 BCD digits (double dabble, combinational, registered once per command)
    reg [26:0] bw;
    integer bi;
    always @(*) begin
        bw = {16'd0, r_q};
        for (bi = 0; bi < 11; bi = bi + 1) begin
            if (bw[14:11] >= 4'd5) bw[14:11] = bw[14:11] + 4'd3;
            if (bw[18:15] >= 4'd5) bw[18:15] = bw[18:15] + 4'd3;
            if (bw[22:19] >= 4'd5) bw[22:19] = bw[22:19] + 4'd3;
            if (bw[26:23] >= 4'd5) bw[26:23] = bw[26:23] + 4'd3;
            bw = bw << 1;
        end
    end
    wire [26:0] r_t = {r_rem, r_num[r_i]};

    always @(posedge clk) begin
        ev_accept <= 1'b0; ev_reject <= 1'b0; ev_start <= 1'b0; ev_end <= 1'b0;
        ev_end_cancelled <= 1'b0; ev_cancel_cmd <= 1'b0; r_fin <= 1'b0;
        vb_d <= vblank;
        if (rst) begin
            s_valid <= 6'd0; q_cnt <= 0; q_wr <= 0; q_rd <= 0;
            st <= S_IDLE; sm_req <= 1'b0; sm_pair <= 1'b0; cancel_pend <= 1'b0;
            disp_state <= 2'd0; disp_op <= 2'd0; words_cur <= 16'd0; cycles_last <= 24'd0;
            stalls_last <= 16'd0; n_accepted <= 16'd0; n_rejected <= 16'd0; n_done <= 16'd0;
            n_cancelled <= 16'd0; last_err <= 4'd0; rate_bcd <= 16'd0; last_tag <= 8'd0;
            ev_code <= 4'd0; ev_words <= 16'd0; ev_flushed <= 3'd0; r_run <= 1'b0;
        end else begin
            // ---------------- staging registers
            if (cfg_we) begin
                case (cfg_idx)
                    3'd0: begin s_src_lo <= cfg_data; s_valid[0] <= 1'b1; end
                    3'd1: begin s_src_hi <= cfg_data; s_valid[1] <= 1'b1; end
                    3'd2: begin s_dst    <= cfg_data; s_valid[2] <= 1'b1; end
                    3'd3: begin s_len    <= cfg_data; s_valid[3] <= 1'b1; end
                    3'd4: begin s_v0     <= cfg_data; s_valid[4] <= 1'b1; end
                    3'd5: begin s_v1     <= cfg_data; s_valid[5] <= 1'b1; end
                    default: ;
                endcase
            end
            // ---------------- commit / cancel
            if (do_cancel) begin
                ev_cancel_cmd <= 1'b1;
                ev_flushed <= q_cnt[2:0];
                n_cancelled <= n_cancelled + {13'd0, q_cnt[2:0]};
                if (st != S_IDLE) cancel_pend <= 1'b1;
            end else if (commit) begin
                ev_code <= v_code;
                if (v_code == E_OK) begin
                    ev_accept <= 1'b1; n_accepted <= n_accepted + 16'd1;
                end else begin
                    ev_reject <= 1'b1; n_rejected <= n_rejected + 16'd1; last_err <= v_code;
                    if (st == S_IDLE && q_cnt == 0) disp_state <= 2'd3;
                end
            end
            // ---------------- queue
            if (push) begin
                q_mem[q_wr] <= {cfg_data[15:8], cfg_data[3], c_opc[1:0], s_v1, s_v0, s_len,
                                s_dst[14:0], src[SW-1:0]};
                q_wr <= q_wr + 1'b1;
            end
            if (do_cancel) begin
                q_rd <= q_wr; q_cnt <= 0;
            end else begin
                if (pop) q_rd <= q_rd + 1'b1;
                q_cnt <= q_cnt + {{QD_LOG{1'b0}}, push} - {{QD_LOG{1'b0}}, pop};
            end

            // ---------------- engine
            if (running) begin
                c_cyc <= c_cyc + 24'd1;
                if ((vw_req && !vw_gnt) || (sm_req && sm_wait))
                    c_stall <= (c_stall == 16'hFFFF) ? c_stall : c_stall + 16'd1;
            end
            if (wrote) begin
                c_dst <= c_dst + 15'd1; c_rem <= c_rem - 16'd1; c_ph <= ~c_ph;
                words_cur <= words_cur + 16'd1;
            end
            if (end_norm || end_canc) begin
                st <= S_IDLE;
                cancel_pend <= 1'b0;
                ev_end <= 1'b1;
                ev_end_cancelled <= end_canc;
                ev_words <= words_cur + (wrote ? 16'd1 : 16'd0);
                if (st != S_VWAIT) begin
                    cycles_last <= c_cyc + 24'd1;
                    stalls_last <= c_stall;
                    r_run <= 1'b1; r_i <= 5'd25; r_rem <= 26'd0; r_q <= 11'd0;
                    r_num <= ({10'd0, words_cur} + (wrote ? 26'd1 : 26'd0)) * 26'd1000;
                    r_den <= {1'b0, c_cyc} + 25'd1;
                end
                if (end_canc) n_cancelled <= n_cancelled + 16'd1 + (do_cancel ? {13'd0, q_cnt[2:0]} : 16'd0);
                else          n_done <= n_done + 16'd1;
                disp_state <= 2'd2;
                if (st == S_RD && sm_req) sm_req <= 1'b0;   // (only reached with sm_ack)
            end else begin
                case (st)
                S_IDLE: if (pop) begin
                    c_src <= head[P_SRC +: SW]; c_dst <= head[P_DST +: 15];
                    c_rem <= head[P_LEN +: 16]; c_v0 <= head[P_V0 +: 16]; c_v1 <= head[P_V1 +: 16];
                    c_op <= head[P_OP +: 2]; last_tag <= head[P_TAG +: 8];
                    c_ph <= 1'b0; c_cyc <= 24'd0; c_stall <= 16'd0; words_cur <= 16'd0;
                    disp_state <= 2'd1; disp_op <= head[P_OP +: 2];
                    ev_start <= 1'b1;
                    st <= head[P_VS] ? S_VWAIT : (head[P_OP +: 2] == 2'd2 ? S_RD : S_FILL);
                end
                S_VWAIT: if (vblank && !vb_d) st <= (c_op == 2'd2) ? S_RD : S_FILL;
                S_WR: if (wrote) begin
                    b_idx <= 1'b1;
                    if (b_idx || !b_two) st <= S_RD;
                end
                S_RD: begin
                    if (!sm_req) begin
                        sm_req <= 1'b1; sm_addr <= c_src;
                        sm_pair <= !c_src[0] && (c_rem >= 16'd2);
                    end else if (sm_ack) begin
                        sm_req <= 1'b0;
                        buf0 <= sm_rdata; buf1 <= sm_rdata_hi;
                        b_two <= sm_pair; b_idx <= 1'b0;
                        c_src <= c_src + {{(SW-2){1'b0}}, sm_pair, !sm_pair};
                        st <= S_WR;
                    end
                end
                default: ;
                endcase
            end

            // ---------------- rate divider: one quotient bit per cycle, then BCD
            if (r_run && !(end_norm || end_canc)) begin
                if (r_t >= {2'b00, r_den}) begin r_rem <= r_t[25:0] - {1'b0, r_den}; r_q <= {r_q[9:0], 1'b1}; end
                else                       begin r_rem <= r_t[25:0];                 r_q <= {r_q[9:0], 1'b0}; end
                r_i <= r_i - 5'd1;
                if (r_i == 5'd0) begin r_run <= 1'b0; r_fin <= 1'b1; end
            end
            if (r_fin) rate_bcd <= bw[26:11];
        end
    end
endmodule
