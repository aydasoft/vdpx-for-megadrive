// MD-VDPX APU (M3): 8 PCM voices + 8 wavetable/noise voices + mixer.
// Spec: docs/M0_especificacao.md section 10. Bit-exact model: sim/apumodel.h.
//
// Register file (256 words, written through the DATA port, target 4):
//   PCM c (0..7), base c*8:  +0 CTRL [0]=KEY [1]=LOOP   +1 START_L  +2 START_H[6:0]
//                            +3 LEN  +4 LOOPST  +5 PITCH (4.12)  +6 VOL ([15:8]L [7:0]R)
//   WAV c (8..15), base c*8: +0 CTRL [0]=EN [1]=NOISE  +1 FREQ  +2 VOL
//   128 + w*8 + i : wave w (0..7), word i holds samples 4i..4i+3 (nibbles, MSB first)
//   192 MASTER ([15:8]L [7:0]R)   193 EXTVOL (MD audio in, 0x80 = unity)   194 STATUS (R)
//
// CPU writes go to a FIFO and are applied at the start of the next 48 kHz tick,
// so register changes are always sample-aligned.
module vdpx_apu #(
    parameter SMEM_AW = 22           // sample memory word address bits
) (
    input             clk,
    input             rst,
    input             tick,           // 48 kHz, from vdpx_i2s

    // CPU side
    input             wr_req,         // register write request (held until wr_ack)
    input       [7:0] wr_addr,
    input      [15:0] wr_data,
    output            wr_ack,
    input       [7:0] rd_addr,        // register read (asynchronous)
    output reg [15:0] rd_data,

    input             cm_req,         // CPU sample-memory access (held until cm_ack)
    input             cm_we,
    input [SMEM_AW-1:0] cm_addr,
    input      [15:0] cm_wdata,
    output reg        cm_ack,
    output reg [15:0] cm_rdata,

    // sample memory (SDRAM controller on hardware, behavioral model in sim)
    output reg        sm_req,
    output reg        sm_we,
    output reg [SMEM_AW-1:0] sm_addr,
    output reg [15:0] sm_wdata,
    input             sm_ack,
    input      [15:0] sm_rdata,

    // external audio (Mega Drive FM+PSG through the ADC)
    input      [15:0] ext_l,
    input      [15:0] ext_r,

    // mixed output, valid when out_valid pulses (once per tick)
    output reg [15:0] out_l,
    output reg [15:0] out_r,
    output reg        out_valid,
    output reg [15:0] wr_applied      // number of register writes applied (debug/verification)
);
    // ------------------------------------------------------------ register file
    reg [15:0] areg [0:255];
    integer i;
`ifndef SYNTHESIS
    initial for (i = 0; i < 256; i = i + 1) areg[i] = 16'd0;
`endif

    // ------------------------------------------------------------ write FIFO (32 entries)
    reg [23:0] fifo [0:31];
    reg  [5:0] f_wr, f_rd;            // 6-bit pointers
    wire [5:0] f_cnt  = f_wr - f_rd;
    wire       f_full = (f_cnt == 6'd32);
    reg        wr_taken;
    assign wr_ack = wr_taken;
    always @(posedge clk) begin
        wr_taken <= 1'b0;
        if (rst) begin
            f_wr <= 0;
        end else if (wr_req && !wr_taken && !f_full) begin
            fifo[f_wr[4:0]] <= {wr_addr, wr_data};
            f_wr <= f_wr + 6'd1;
            wr_taken <= 1'b1;
        end
    end

    // ------------------------------------------------------------ voice state
    // Voice state lives in small distributed RAMs indexed only by the channel being
    // processed (one write port). Key-on / wave restart requested by register writes
    // are recorded as flags and applied when the channel is processed in that tick.
    reg [28:0] pos   [0:7];           // 17.12
    reg  [7:0] playing;
    reg  [7:0] restart_p, restart_w;
    reg [19:0] phase [0:7];
    reg [14:0] lfsr  [0:7];

    always @(*) rd_data = (rd_addr == 8'd194) ? {8'd0, playing} : areg[rd_addr];

    // ------------------------------------------------------------ FSM
    localparam [4:0]
        S_IDLE = 0, S_DRAIN = 1, S_CH = 2,
        P_R1 = 3, P_R2 = 4, P_R3 = 5, P_R4 = 6, P_R5 = 7, P_R6 = 8, P_BOUND = 9, P_WAIT = 10,
        W_R1 = 11, W_R2 = 12, W_R3 = 13, S_MIX = 14, S_NEXT = 15, S_G0 = 16, S_G1 = 17,
        S_MIXR = 18, S_O1 = 19, S_O2 = 20, S_O3 = 21, S_O4 = 22;

    reg  [4:0] st;
    reg  [3:0] ch;
    reg  [5:0] drain_n;
    reg [15:0] t_ctrl, t_sl, t_sh, t_len, t_loop, t_pitch, t_vol, t_wave;
    reg signed [7:0]  s;
    reg signed [20:0] acc_l, acc_r;
    reg [15:0] t_master;
    reg        mem_busy_apu;          // APU owns the sample memory port

    // register file address for the current step
    reg [7:0] ra;
    always @(*) begin
        case (st)
            S_CH:  ra = {1'b0, ch, 3'd0};
            P_R1:  ra = {1'b0, ch, 3'd1};
            P_R2:  ra = {1'b0, ch, 3'd2};
            P_R3:  ra = {1'b0, ch, 3'd3};
            P_R4:  ra = {1'b0, ch, 3'd4};
            P_R5:  ra = {1'b0, ch, 3'd5};
            P_R6:  ra = {1'b0, ch, 3'd6};
            W_R1:  ra = {1'b0, ch, 3'd1};
            W_R2:  ra = {1'b0, ch, 3'd2};
            W_R3:  ra = {2'b10, ch[2:0], w_ph[19:17]};
            S_G0:  ra = 8'd192;
            S_G1:  ra = 8'd193;
            default: ra = 8'd0;
        endcase
    end
    wire [15:0] rv = areg[ra];

    // ---- PCM boundary / address (state P_BOUND)
    wire  [2:0] pc      = ch[2:0];
    wire [28:0] p_pos   = restart_p[pc] ? 29'd0 : pos[pc];
    wire [16:0] p_int   = p_pos[28:12];
    wire        p_over  = playing[pc] && (p_int >= {1'b0, t_len});
    wire        p_loopok= t_ctrl[1] && (t_len > t_loop);
    wire [16:0] p_span  = {1'b0, t_len} - {1'b0, t_loop};
    wire [28:0] p_wrap1 = p_pos - {p_span, 12'd0};
    wire [28:0] p_wrapd = (p_wrap1[28:12] >= {1'b0, t_len}) ? {1'b0, t_loop, 12'd0} : p_wrap1;
    wire [28:0] np      = p_over ? (p_loopok ? p_wrapd : p_pos) : p_pos;
    wire        npl     = p_over ? p_loopok : playing[pc];
    wire [22:0] p_start = {t_sh[6:0], t_sl};
    wire [22:0] p_baddr = p_start + {6'd0, np[28:12]};

    // ---- wave sample (state W_R3: rv = wave word)
    wire  [2:0] wc      = ch[2:0];
    wire [19:0] w_ph    = restart_w[wc] ? 20'd0 : phase[wc];
    wire [14:0] w_lfsr  = restart_w[wc] ? 15'h4000 : lfsr[wc];
    wire  [1:0] wnib_i  = w_ph[16:15];
    reg   [3:0] wnib;
    always @(*) begin
        case (wnib_i)
            2'd0: wnib = rv[15:12];
            2'd1: wnib = rv[11:8];
            2'd2: wnib = rv[7:4];
            default: wnib = rv[3:0];
        endcase
    end
    wire signed [7:0] w_s = t_ctrl[1] ? (w_lfsr[0] ? 8'sd96 : -8'sd96)
                                      : $signed({wnib, 4'd0} ^ 8'h80);   // (nib-8)*16

    wire [20:0] w_sum = {1'b0, w_ph} + {5'd0, t_pitch};

    // ---- one shared multiplier: signed 21 x unsigned 8 (maps to one DSP on Gowin EDA)
    reg  signed [20:0] mul_a;
    reg          [7:0] mul_b;
    always @(*) begin
        case (st)
            S_MIX:  begin mul_a = {{13{s[7]}}, s};                mul_b = t_vol[15:8];    end
            S_MIXR: begin mul_a = {{13{s[7]}}, s};                mul_b = t_vol[7:0];     end
            S_O1:   begin mul_a = acc_l;                          mul_b = t_master[15:8]; end
            S_O2:   begin mul_a = acc_r;                          mul_b = t_master[7:0];  end
            S_O3:   begin mul_a = {{5{ext_l[15]}}, ext_l};        mul_b = t_ext[15:8];    end
            default:begin mul_a = {{5{ext_r[15]}}, ext_r};        mul_b = t_ext[7:0];     end
        endcase
    end
    // ECP5-P1: the multiplier is pipelined (registered inputs and product). Every state
    // that consumes the product waits two cycles (mwait) with its operands selected, so
    // the arithmetic and the order of operations are unchanged; only the cycle count of
    // a 48 kHz tick grows by 2 cycles per product (16 channels x 2 + 4 outputs = +72).
    reg  signed [20:0] mul_a_r;
    reg          [7:0] mul_b_r;
    reg  signed [29:0] mul_p;
    reg          [1:0] mwait;
    wire               mul_rdy = (mwait == 2'd2);
    always @(posedge clk) begin
        mul_a_r <= mul_a;
        mul_b_r <= mul_b;
        mul_p   <= mul_a_r * $signed({1'b0, mul_b_r});
    end
    reg  signed [21:0] o_ml_s, o_mr_s;
    wire signed [29:0] mul_p_10 = mul_p >>> 10;
    wire signed [29:0] mul_p_7  = mul_p >>> 7;
    wire signed [21:0] o_sl = o_ml_s + mul_p_7[21:0];       // valid in S_O4 for R, S_O3 for L
    reg  [15:0] t_ext;
    function [15:0] clip16(input signed [21:0] v);
        clip16 = (v > 22'sd32767) ? 16'h7FFF : (v < -22'sd32768) ? 16'h8000 : v[15:0];
    endfunction

    // ---- drain: apply one FIFO entry
    wire [23:0] fe   = fifo[f_rd[4:0]];
    wire  [7:0] fe_a = fe[23:16];
    wire [15:0] fe_d = fe[15:0];

    // ---- sample memory arbitration (APU has priority)
    reg        cm_busy;
    always @(posedge clk) begin
        out_valid <= 1'b0;
        cm_ack <= 1'b0;
        if (rst) begin
            st <= S_IDLE; f_rd <= 0; playing <= 0; wr_applied <= 0; mwait <= 2'd0;
            restart_p <= 8'hFF; restart_w <= 8'hFF;
            sm_req <= 0; cm_busy <= 0; mem_busy_apu <= 0;
            out_l <= 0; out_r <= 0;
            areg[193] <= 16'h8080;
        end else begin
            // CPU sample-memory accesses when the APU is not using the port
            if (!sm_req && cm_req && !cm_busy && !cm_ack && !mem_busy_apu && st != P_BOUND) begin
                sm_req <= 1'b1; sm_we <= cm_we; sm_addr <= cm_addr; sm_wdata <= cm_wdata;
                cm_busy <= 1'b1;
            end else if (sm_req && sm_ack && cm_busy) begin
                sm_req <= 1'b0; cm_busy <= 1'b0;
                cm_rdata <= sm_rdata; cm_ack <= 1'b1;
            end

            case (st)
            S_IDLE: if (tick) begin
                drain_n <= f_cnt;             // writes accepted before this tick
                st <= S_DRAIN;
            end
            S_DRAIN: begin
                if (drain_n == 6'd0) begin
                    ch <= 4'd0; acc_l <= 0; acc_r <= 0; st <= S_CH;
                end else begin
                    if (fe_a != 8'd194) areg[fe_a] <= fe_d;
                    if (fe_a[7] == 1'b0 && fe_a[2:0] == 3'd0) begin
                        if (fe_a[6] == 1'b0) begin                     // PCM CTRL: key on/off
                            playing[fe_a[5:3]] <= fe_d[0];
                            if (fe_d[0]) restart_p[fe_a[5:3]] <= 1'b1;
                        end else begin                                 // WAV CTRL: restart
                            restart_w[fe_a[5:3]] <= 1'b1;
                        end
                    end
                    f_rd <= f_rd + 6'd1;
                    drain_n <= drain_n - 6'd1;
                    wr_applied <= wr_applied + 16'd1;
                end
            end
            S_CH: begin
                t_ctrl <= rv;
                st <= ch[3] ? W_R1 : P_R1;
            end
            // ---------------- PCM
            P_R1: begin t_sl    <= rv; st <= P_R2; end
            P_R2: begin t_sh    <= rv; st <= P_R3; end
            P_R3: begin t_len   <= rv; st <= P_R4; end
            P_R4: begin t_loop  <= rv; st <= P_R5; end
            P_R5: begin t_pitch <= rv; st <= P_R6; end
            P_R6: begin t_vol   <= rv; st <= P_BOUND; end
            P_BOUND: begin
                pos[pc] <= np;
                restart_p[pc] <= 1'b0;
                playing[pc] <= npl;
                if (npl) begin
                    if (!sm_req) begin           // port free (a CPU access may be finishing)
                        sm_req <= 1'b1; sm_we <= 1'b0;
                        sm_addr <= p_baddr[SMEM_AW:1];
                        t_wave <= {15'd0, p_baddr[0]};   // byte select
                        mem_busy_apu <= 1'b1;
                        st <= P_WAIT;
                    end
                end else begin
                    s <= 8'sd0; st <= S_MIX;
                end
            end
            P_WAIT: if (sm_ack && mem_busy_apu) begin
                sm_req <= 1'b0; mem_busy_apu <= 1'b0;
                s <= t_wave[0] ? $signed(sm_rdata[7:0]) : $signed(sm_rdata[15:8]);
                st <= S_MIX;
            end
            // ---------------- WAV
            W_R1: begin t_pitch <= rv; st <= W_R2; end              // FREQ
            W_R2: begin t_vol   <= rv; st <= W_R3; end
            W_R3: begin
                s <= t_ctrl[0] ? w_s : 8'sd0;
                st <= S_MIX;
            end
            // ---------------- mix + advance
            S_MIX: if (!mul_rdy) mwait <= mwait + 2'd1; else begin
                mwait <= 2'd0;
                acc_l <= acc_l + mul_p[20:0];
                st <= S_MIXR;
            end
            S_MIXR: if (!mul_rdy) mwait <= mwait + 2'd1; else begin
                mwait <= 2'd0;
                acc_r <= acc_r + mul_p[20:0];
                if (!ch[3]) begin
                    if (playing[pc]) pos[pc] <= pos[pc] + {13'd0, t_pitch};
                end else if (t_ctrl[0]) begin
                    phase[wc] <= w_sum[19:0];
                    restart_w[wc] <= 1'b0;
                    lfsr[wc] <= (t_ctrl[1] && w_sum[20])   // noise: clock the LFSR on phase overflow
                              ? {w_lfsr[0] ^ w_lfsr[1], w_lfsr[14:1]} : w_lfsr;
                end
                st <= S_NEXT;
            end
            S_NEXT: begin
                if (ch == 4'd15) st <= S_G0;
                else begin ch <= ch + 4'd1; st <= S_CH; end
            end
            S_G0: begin t_master <= rv; st <= S_G1; end
            S_G1: begin t_ext <= rv; st <= S_O1; end
            S_O1: if (!mul_rdy) mwait <= mwait + 2'd1; else begin mwait <= 2'd0; o_ml_s <= mul_p_10[21:0]; st <= S_O2; end
            S_O2: if (!mul_rdy) mwait <= mwait + 2'd1; else begin mwait <= 2'd0; o_mr_s <= mul_p_10[21:0]; st <= S_O3; end
            S_O3: if (!mul_rdy) mwait <= mwait + 2'd1; else begin mwait <= 2'd0; out_l <= clip16(o_sl); o_ml_s <= o_mr_s; st <= S_O4; end
            S_O4: if (!mul_rdy) mwait <= mwait + 2'd1; else begin
                mwait <= 2'd0;
                out_r <= clip16(o_sl);
                out_valid <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
