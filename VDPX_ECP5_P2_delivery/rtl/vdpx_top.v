// MD-VDPX top (M1.5): bus interface, registers, VRAM/CRAM/VSRAM/SAT,
// renderer (planes + sprites), compositor.
//
// clk = system clock = 2 x pixel clock (50.4 MHz). Video timing advances on an
// internal clock enable; video outputs change once per pixel and 'vid_ce'
// marks the cycle right after each change.
module vdpx_top #(
    parameter I2S_NUM  = 1,         // I2S frame = I2S_DEN/I2S_NUM clocks (1/1050 at 50.4 MHz,
    parameter I2S_DEN  = 1050,      // 3/3125 at 50.0 MHz): see vdpx_i2s.v
    parameter SMEM_AW  = 22,        // sample memory word address bits (8 MB on the Tang SDRAM)
    parameter PREFETCH = 1          // 0 = no DATA-read prefetch (write-only builds: shorter
                                    //     and bounded service time for 68000 writes)
) (
    input             clk,
    input             rst,

    // synchronous internal bus (spec section 6)
    input             bus_cs,
    input             bus_we,
    input       [2:0] bus_addr,     // word offset (68000 A3..A1)
    input      [15:0] bus_wdata,
    output reg [15:0] bus_rdata,
    output reg        bus_ack,

    // immediate-read interface (68000 expansion port adapter)
    input       [2:0] peek_addr,
    output reg [15:0] peek_data,      // value of port peek_addr, 1 cycle later
    output reg        peek_valid,
    input             rd_commit,      // pulse: a read of rd_commit_addr happened
    input       [2:0] rd_commit_addr,

    // video out
    output reg  [7:0] vid_r,
    output reg  [7:0] vid_g,
    output reg  [7:0] vid_b,
    output reg        vid_hs_n,
    output reg        vid_vs_n,
    output reg        vid_de,
    output reg        vid_ce,

    output            vblank,

    // audio: I2S master (DAC/amp out, ADC in = Mega Drive audio from SL2/SR2)
    output            i2s_bclk,
    output            i2s_lrck,
    output            i2s_dout,
    input             i2s_din,
    output     [15:0] aud_l,          // mixed output (also goes to HDMI audio in M4)
    output     [15:0] aud_r,
    output            aud_valid,
    output            aud_tick,       // debug: 48 kHz frame start
    output     [15:0] aud_wr_applied, // debug: APU register writes applied

    // sample memory (SDRAM controller on hardware)
    output              sm_req,
    output              sm_we,
    output [SMEM_AW-1:0] sm_addr,
    output       [15:0] sm_wdata,
    output              sm_pair,       // P2: read two words (addr even, +1) in one access (DMA)
    input               sm_ack,
    input        [15:0] sm_rdata,
    input        [15:0] sm_rdata_hi,    // P2: word at addr+1 of a pair read

    // P2: DMA status and verification taps
    output              dbg_vw_we,      // VRAM write port: a write happens this cycle
    output              dbg_vw_dma,     //   ... issued by the DMA (else by the CPU bus)
    output       [14:0] dbg_vw_addr,
    output       [15:0] dbg_vw_data,
    output       [99:0] dma_status,     // see the assignment below
    output       [28:0] dma_events
);
    // ------------------------------------------------------------ pixel clock enable
    reg ce;
    always @(posedge clk) ce <= rst ? 1'b0 : ~ce;

    // ------------------------------------------------------------ registers
    reg [15:0] r_mode, r_bg, r_abase, r_bbase, r_psize;
    reg [15:0] r_ax, r_ay, r_bx, r_by, r_tbase;
    reg [15:0] r_smode, r_hsbase;
    reg [15:0] r_tgt, r_addr, r_inc, r_ahi;
    reg  [3:0] reg_sel;
    reg        st_overflow, st_sprovf;

    // ------------------------------------------------------------ timing
    wire [9:0] hc, vc;
    wire de, hs_n, vs_n;
    vdpx_timing u_tim (.clk(clk), .rst(rst), .ce(ce), .hc(hc), .vc(vc), .de(de),
                       .hsync_n(hs_n), .vsync_n(vs_n));

    assign vblank = (vc < 10'd16) || (vc >= 10'd464);
    wire hblank   = (hc >= 10'd640);

    // ------------------------------------------------------------ memories
    reg  [14:0] cpu_maddr;
    reg  [15:0] cpu_mdin;
    reg         vram_we, cram_we, vsram_we, sat_we;

    // VRAM: one read port shared by renderer (priority) and CPU reads
    wire [14:0] r_vaddr;
    wire        r_vreq;
    wire [15:0] vram_q;
    // P2: the write port has two masters. A CPU write (vram_we, registered, from the bus FSM)
    // always wins; the DMA write request is granted only in cycles without a CPU write and
    // simply waits otherwise. The read port is unchanged (renderer first, then CPU reads).
    wire        dma_vw_req;
    wire [14:0] dma_vw_addr;
    wire [15:0] dma_vw_data;
    wire        dma_vw_gnt = dma_vw_req && !vram_we;
    wire        vw_we      = vram_we || dma_vw_gnt;
    wire [14:0] vw_addr    = vram_we ? cpu_maddr : dma_vw_addr;
    wire [15:0] vw_data    = vram_we ? cpu_mdin  : dma_vw_data;
    vdpx_sdpram #(.AW(15), .DW(16)) u_vram (
        .clk(clk), .raddr(r_vreq ? r_vaddr : cpu_maddr), .rdata(vram_q),
        .waddr(vw_addr), .we(vw_we), .wdata(vw_data));
    assign dbg_vw_we = vw_we, dbg_vw_dma = dma_vw_gnt, dbg_vw_addr = vw_addr, dbg_vw_data = vw_data;

    // SAT: 128 sprites x 4 words, read port shared like VRAM
    wire  [8:0] r_saddr;
    wire        r_sreq;
    wire [15:0] sat_q;
    vdpx_sdpram #(.AW(9), .DW(16)) u_sat (
        .clk(clk), .raddr(r_sreq ? r_saddr : cpu_maddr[8:0]), .rdata(sat_q),
        .waddr(cpu_maddr[8:0]), .we(sat_we), .wdata(cpu_mdin));

    // CRAM: display copy + CPU read-back copy
    wire  [7:0] cram_raddr;
    wire [15:0] cram_rdata, cram_cpu_q;
    vdpx_sdpram #(.AW(8), .DW(16)) u_cram (
        .clk(clk), .raddr(cram_raddr), .rdata(cram_rdata),
        .waddr(cpu_maddr[7:0]), .we(cram_we), .wdata(cpu_mdin));
    vdpx_sdpram #(.AW(8), .DW(16)) u_cram_cpu (
        .clk(clk), .raddr(cpu_maddr[7:0]), .rdata(cram_cpu_q),
        .waddr(cpu_maddr[7:0]), .we(cram_we), .wdata(cpu_mdin));

    // VSRAM: 64 words, asynchronous read (distributed RAM)
    reg  [15:0] vsram [0:63];
    wire  [5:0] r_vsaddr;
    integer vi;
    initial for (vi = 0; vi < 64; vi = vi + 1) vsram[vi] = 16'd0;
    always @(posedge clk) if (vsram_we) vsram[cpu_maddr[5:0]] <= cpu_mdin;
    wire [15:0] r_vsdata = vsram[r_vsaddr];
    wire [15:0] vsram_cpu_q = vsram[cpu_maddr[5:0]];

    // ------------------------------------------------------------ line buffers
    wire       lbA_we, lbB_we, lbS_we;
    wire [9:0] lb_waddr, lbs_waddr;
    wire [8:0] lb_wdata, lbs_wdata;
    wire [9:0] lb_raddr;
    wire [8:0] lbA_q, lbB_q, lbS_q;

    vdpx_sdpram #(.AW(10), .DW(9)) u_lbA (
        .clk(clk), .raddr(lb_raddr), .rdata(lbA_q),
        .waddr(lb_waddr), .we(lbA_we), .wdata(lb_wdata));
    vdpx_sdpram #(.AW(10), .DW(9)) u_lbB (
        .clk(clk), .raddr(lb_raddr), .rdata(lbB_q),
        .waddr(lb_waddr), .we(lbB_we), .wdata(lb_wdata));
    vdpx_sdpram #(.AW(10), .DW(9)) u_lbS (
        .clk(clk), .raddr(lb_raddr), .rdata(lbS_q),
        .waddr(lbs_waddr), .we(lbS_we), .wdata(lbs_wdata));

    // ------------------------------------------------------------ renderer
    // Line y is rendered during HDMI lines 2y+14 and 2y+15, displayed on 2y+16, 2y+17.
    wire [9:0] vr     = vc - 10'd14;
    wire       rstart = ce && (hc == 10'd0) && (vc >= 10'd14) && (vc <= 10'd460) && (vc[0] == 1'b0);
    wire [7:0] rline  = vr[8:1];
    wire       rbusy, rsprovf;

    vdpx_render u_ren (
        .clk(clk), .rst(rst), .start(rstart), .line(rline), .set(rline[0]),
        .busy(rbusy), .spr_ovf(rsprovf),
        .r_abase(r_abase), .r_bbase(r_bbase), .r_psize(r_psize),
        .r_ax(r_ax), .r_ay(r_ay), .r_bx(r_bx), .r_by(r_by), .r_tbase(r_tbase),
        .r_smode(r_smode), .r_hsbase(r_hsbase),
        .vaddr(r_vaddr), .vreq(r_vreq), .vdata(vram_q),
        .sat_addr(r_saddr), .sreq(r_sreq), .sat_data(sat_q),
        .vs_addr(r_vsaddr), .vs_data(r_vsdata),
        .lbA_we(lbA_we), .lbB_we(lbB_we), .lbS_we(lbS_we),
        .lb_addr(lb_waddr), .lb_data(lb_wdata),
        .lbs_addr(lbs_waddr), .lbs_data(lbs_wdata));

    // ------------------------------------------------------------ compositor
    // ce edge n: counters=P. ce edge n+1: d1 <= line buffers(P). ce edge n+2: outputs <= CRAM(P).
    wire       in_area = (vc >= 10'd16) && (vc < 10'd464);
    wire [9:0] vd      = vc - 10'd16;
    assign lb_raddr    = {vd[1], hc[9:1]};

    reg       d1_de, d1_hs, d1_vs, d1_show;
    reg [8:0] d1_a, d1_b, d1_s;

    wire a_op = d1_a[3:0] != 4'd0, a_hi = d1_a[8];
    wire b_op = d1_b[3:0] != 4'd0, b_hi = d1_b[8];
    wire s_op = d1_s[3:0] != 4'd0, s_hi = d1_s[8];
    reg  [7:0] comp_idx;
    always @(*) begin
        if (!d1_show)          comp_idx = r_bg[7:0];
        else if (s_op && s_hi) comp_idx = d1_s[7:0];
        else if (a_op && a_hi) comp_idx = d1_a[7:0];
        else if (b_op && b_hi) comp_idx = d1_b[7:0];
        else if (s_op)         comp_idx = d1_s[7:0];
        else if (a_op)         comp_idx = d1_a[7:0];
        else if (b_op)         comp_idx = d1_b[7:0];
        else                   comp_idx = r_bg[7:0];
    end
    assign cram_raddr = comp_idx;

    always @(posedge clk) begin
        vid_ce <= ce;
        if (ce) begin
            d1_de <= de; d1_hs <= hs_n; d1_vs <= vs_n;
            d1_show <= in_area && r_mode[0];
            d1_a <= lbA_q; d1_b <= lbB_q; d1_s <= lbS_q;
            // CRAM output for the pixel held in d1 is valid at this edge
            vid_de   <= d1_de;
            vid_hs_n <= d1_hs;
            vid_vs_n <= d1_vs;
            if (d1_de) begin
                vid_r <= {cram_rdata[14:10], cram_rdata[14:12]};
                vid_g <= {cram_rdata[9:5],   cram_rdata[9:7]};
                vid_b <= {cram_rdata[4:0],   cram_rdata[4:2]};
            end else begin
                vid_r <= 8'd0; vid_g <= 8'd0; vid_b <= 8'd0;
            end
        end
    end

    // ------------------------------------------------------------ audio
    wire        a_tick;
    wire [15:0] ext_l, ext_r;
    reg         apu_wr_req;
    reg   [7:0] apu_wr_addr;
    reg  [15:0] apu_wr_data;
    wire        apu_wr_ack;
    wire [15:0] apu_rd;
    reg         cm_req, cm_we;
    reg [SMEM_AW-1:0] cm_addr;
    reg  [15:0] cm_wdata;
    wire        cm_ack;
    wire [15:0] cm_rdata;

    // ---- P2: sample-memory arbiter. Two masters: the APU port (APU first, CPU target-5
    // accesses interleaved by vdpx_apu.v exactly as in P1) and the DMA (background reads).
    // Non-preemptive: the owner keeps the port until its ack; with both requesting, the APU
    // port wins. An APU request therefore waits at most one DMA access.
    wire               a_sm_req, a_sm_we;
    wire [SMEM_AW-1:0] a_sm_addr;
    wire        [15:0] a_sm_wdata;
    wire               d_sm_req, d_sm_pair;
    wire [SMEM_AW-1:0] d_sm_addr;
    reg          [1:0] sm_own;          // 0 none, 1 APU port, 2 DMA
    always @(posedge clk) begin
        if (rst) sm_own <= 2'd0;
        else case (sm_own)
            2'd0: if (a_sm_req) sm_own <= 2'd1; else if (d_sm_req) sm_own <= 2'd2;
            default: if (sm_ack) sm_own <= 2'd0;
        endcase
    end
    assign sm_req   = (sm_own == 2'd1) ? a_sm_req : (sm_own == 2'd2) ? d_sm_req : 1'b0;
    assign sm_we    = (sm_own == 2'd1) && a_sm_we;
    assign sm_addr  = (sm_own == 2'd2) ? d_sm_addr : a_sm_addr;
    assign sm_wdata = a_sm_wdata;
    assign sm_pair  = (sm_own == 2'd2) && d_sm_pair;
    wire   a_sm_ack = (sm_own == 2'd1) && sm_ack;
    wire   d_sm_ack = (sm_own == 2'd2) && sm_ack;
    wire   d_sm_wait = d_sm_req && sm_own != 2'd2;

    // ---- P2: DMA engine (target 6)
    reg         dma_cfg_we;
    reg   [2:0] dma_cfg_idx;
    reg  [15:0] dma_cfg_data;
    wire        dma_busy;
    wire  [1:0] dma_disp, dma_op;
    wire  [2:0] dma_q;
    wire [15:0] dma_words, dma_stalls, dma_nacc, dma_nrej, dma_ndone, dma_ncanc, dma_rate;
    wire [23:0] dma_cycles;
    wire  [3:0] dma_lerr;
    wire  [7:0] dma_tag;
    vdpx_dma #(.SMEM_AW(SMEM_AW)) u_dma (
        .clk(clk), .rst(rst), .vblank(vblank),
        .cfg_we(dma_cfg_we), .cfg_idx(dma_cfg_idx), .cfg_data(dma_cfg_data),
        .vw_req(dma_vw_req), .vw_addr(dma_vw_addr), .vw_data(dma_vw_data), .vw_gnt(dma_vw_gnt),
        .sm_req(d_sm_req), .sm_addr(d_sm_addr), .sm_pair(d_sm_pair), .sm_ack(d_sm_ack),
        .sm_rdata(sm_rdata), .sm_rdata_hi(sm_rdata_hi), .sm_wait(d_sm_wait),
        .busy(dma_busy), .disp_state(dma_disp), .disp_op(dma_op), .q_level(dma_q),
        .words_cur(dma_words), .cycles_last(dma_cycles), .stalls_last(dma_stalls),
        .n_accepted(dma_nacc), .n_rejected(dma_nrej), .n_done(dma_ndone), .n_cancelled(dma_ncanc),
        .last_err(dma_lerr), .rate_bcd(dma_rate), .last_tag(dma_tag),
        .ev_accept(dma_events[28]), .ev_reject(dma_events[27]), .ev_code(dma_events[26:23]),
        .ev_start(dma_events[22]), .ev_end(dma_events[21]), .ev_end_cancelled(dma_events[20]),
        .ev_words(dma_events[19:4]), .ev_cancel_cmd(dma_events[3]), .ev_flushed(dma_events[2:0]));
    // dma_status [99:0] = {busy[99], disp[98:97], op[96:95], queue[94:92], last_err[91:88],
    //   rejected[87:72], words[71:56], cycles[55:32], stalls[31:16], rate_bcd[15:0]}
    assign dma_status = {dma_busy, dma_disp, dma_op, dma_q, dma_lerr, dma_nrej,
                         dma_words, dma_cycles, dma_stalls, dma_rate};
    reg  [15:0] dma_rd;
    always @(*) begin
        case (r_addr[3:0])                 // target-6 reads: diagnostics (testbenches only)
            4'd8:  dma_rd = {dma_busy, 4'd0, dma_q, dma_disp, dma_op, dma_lerr};
            4'd9:  dma_rd = dma_words;
            4'd10: dma_rd = dma_cycles[15:0];
            4'd11: dma_rd = {8'd0, dma_cycles[23:16]};
            4'd12: dma_rd = dma_nacc;
            4'd13: dma_rd = dma_nrej;
            4'd14: dma_rd = dma_ndone;
            4'd15: dma_rd = dma_ncanc;
            default: dma_rd = 16'd0;
        endcase
    end

    vdpx_i2s #(.FR_NUM(I2S_NUM), .FR_DEN(I2S_DEN)) u_i2s (
        .clk(clk), .rst(rst), .tick(a_tick),
        .bclk(i2s_bclk), .lrck(i2s_lrck), .dout(i2s_dout), .din(i2s_din),
        .tx_l(aud_l), .tx_r(aud_r), .rx_l(ext_l), .rx_r(ext_r));

    vdpx_apu #(.SMEM_AW(SMEM_AW)) u_apu (
        .clk(clk), .rst(rst), .tick(a_tick),
        .wr_req(apu_wr_req), .wr_addr(apu_wr_addr), .wr_data(apu_wr_data), .wr_ack(apu_wr_ack),
        .rd_addr(cpu_maddr[7:0]), .rd_data(apu_rd),
        .cm_req(cm_req), .cm_we(cm_we), .cm_addr(cm_addr), .cm_wdata(cm_wdata),
        .cm_ack(cm_ack), .cm_rdata(cm_rdata),
        .sm_req(a_sm_req), .sm_we(a_sm_we), .sm_addr(a_sm_addr), .sm_wdata(a_sm_wdata),
        .sm_ack(a_sm_ack), .sm_rdata(sm_rdata),
        .ext_l(ext_l), .ext_r(ext_r),
        .out_l(aud_l), .out_r(aud_r), .out_valid(aud_valid), .wr_applied(aud_wr_applied));
    assign aud_tick = a_tick;

    // ------------------------------------------------------------ bus interface
    // The 68000 cannot be stalled through the expansion port (the console
    // generates /DTACK itself), so reads must be answered immediately:
    //  - DATA reads come from a prefetch register, refilled after every
    //    access that changes the DATA address or the memory (like the MD VDP);
    //  - the "peek" port gives the value of any register one cycle after
    //    peek_addr is set, and rd_commit applies the read side effects
    //    (DATA: address += INC and refetch; STATUS: clear sticky flags).
    // The classic request/ack bus (bus_cs ... bus_ack) is kept for the self-test
    // and the testbenches; its DATA reads also use the prefetch register.
    reg        hold;
    wire [2:0] tgt = r_tgt[2:0];
    wire [16:0] addr_next = {1'b0, r_addr} + {1'b0, r_inc};
    wire [31:0] smem_full = {r_ahi, r_addr};
    wire [SMEM_AW-1:0] smem_addr = smem_full[SMEM_AW-1:0];

    wire [15:0] status = {12'd0, st_sprovf, st_overflow, hblank, vblank};
    reg  [15:0] apu_rd_q;
    always @(posedge clk) apu_rd_q <= apu_rd;
    reg  [15:0] mem_rd;
    always @(*) begin
        case (tgt)
            3'd0: mem_rd = vram_q;
            3'd1: mem_rd = cram_cpu_q;
            3'd2: mem_rd = vsram_cpu_q;
            3'd3: mem_rd = sat_q;
            3'd4: mem_rd = apu_rd_q;
            3'd6: mem_rd = dma_rd;
            default: mem_rd = 16'd0;
        endcase
    end
    wire port_busy = (tgt == 3'd0) ? r_vreq : (tgt == 3'd3) ? r_sreq : 1'b0;

    // register file read (shared by bus reads and peek)
    function [15:0] reg_val(input [3:0] n);
        case (n)
            4'd0:  reg_val = r_mode;   4'd1:  reg_val = r_bg;
            4'd2:  reg_val = r_abase;  4'd3:  reg_val = r_bbase;
            4'd4:  reg_val = r_psize;  4'd5:  reg_val = r_ax;
            4'd6:  reg_val = r_ay;     4'd7:  reg_val = r_bx;
            4'd8:  reg_val = r_by;     4'd9:  reg_val = r_tbase;
            4'd10: reg_val = r_smode;  4'd11: reg_val = r_hsbase;
            4'd12: reg_val = r_tgt;    4'd13: reg_val = r_addr;
            4'd14: reg_val = r_inc;    default: reg_val = r_ahi;
        endcase
    endfunction
    reg [15:0] pf_data;
    reg        pf_valid, pf_need;
    function [15:0] port_val(input [2:0] a);
        case (a)
            3'd0: port_val = pf_data;
            3'd1: port_val = status;
            3'd2: port_val = {12'd0, reg_sel};
            3'd3: port_val = reg_val(reg_sel);
            3'd4: port_val = {6'd0, vc};
            3'd5: port_val = {6'd0, hc};
            3'd6: port_val = 16'h5658;
            default: port_val = 16'd0;
        endcase
    endfunction

    always @(posedge clk) begin
        peek_data  <= port_val(peek_addr);
        peek_valid <= !cpend && ((peek_addr != 3'd0) || (pf_valid && !pf_need));
    end

    localparam [2:0] M_IDLE = 0, M_APU = 1, M_PF0 = 2, M_PF1 = 3, M_PF2 = 4, M_PFAPU = 5;
    reg        cpend;              // read side effects waiting for M_IDLE
    reg  [2:0] caddr;
    reg  [2:0] mst;
    wire       bus_new = bus_cs && !hold;

    always @(posedge clk) begin
        bus_ack  <= 1'b0;
        vram_we  <= 1'b0; cram_we <= 1'b0; vsram_we <= 1'b0; sat_we <= 1'b0;
        dma_cfg_we <= 1'b0;
        if (rstart && rbusy) st_overflow <= 1'b1;
        if (rsprovf) st_sprovf <= 1'b1;
        if (!bus_cs) hold <= 1'b0;
        if (rd_commit) begin cpend <= 1'b1; caddr <= rd_commit_addr; end

        if (rst) begin
            mst <= M_IDLE; apu_wr_req <= 1'b0; cm_req <= 1'b0; r_ahi <= 0;
            hold <= 1'b0; st_overflow <= 1'b0; st_sprovf <= 1'b0;
            r_mode <= 0; r_bg <= 0; r_abase <= 0; r_bbase <= 0; r_psize <= 0;
            r_ax <= 0; r_ay <= 0; r_bx <= 0; r_by <= 0; r_tbase <= 0;
            r_smode <= 0; r_hsbase <= 0;
            r_tgt <= 0; r_addr <= 0; r_inc <= 16'd1; reg_sel <= 0;
            bus_rdata <= 0; pf_valid <= 1'b0; pf_need <= 1'b1; pf_data <= 0; cpend <= 1'b0;
        end else begin
            case (mst)
            M_IDLE: begin
                if (cpend && !rd_commit) begin
                    // read side effects (peek path)
                    cpend <= 1'b0;
                    if (caddr == 3'd0) begin
                        r_addr <= addr_next[15:0];
                        r_ahi  <= r_ahi + {15'd0, addr_next[16]};
                        pf_valid <= 1'b0; pf_need <= 1'b1;
                    end else if (caddr == 3'd1) begin
                        st_overflow <= 1'b0; st_sprovf <= 1'b0;
                    end
                end else if (bus_new && bus_we) begin
                    case (bus_addr)
                    3'd0: begin
                        cpu_maddr <= r_addr[14:0];
                        cpu_mdin  <= bus_wdata;
                        r_addr <= addr_next[15:0];
                        r_ahi  <= r_ahi + {15'd0, addr_next[16]};
                        pf_valid <= 1'b0; pf_need <= 1'b1;
                        case (tgt)
                            3'd0: vram_we  <= 1'b1;
                            3'd1: cram_we  <= 1'b1;
                            3'd2: vsram_we <= 1'b1;
                            3'd3: sat_we   <= 1'b1;
                            3'd4: begin apu_wr_req <= 1'b1; apu_wr_addr <= r_addr[7:0]; apu_wr_data <= bus_wdata; end
                            3'd5: begin cm_req <= 1'b1; cm_we <= 1'b1; cm_addr <= smem_addr; cm_wdata <= bus_wdata; end
                            3'd6: if (r_addr[15:3] == 13'd0) begin       // P2: DMA registers 0..7
                                dma_cfg_we <= 1'b1; dma_cfg_idx <= r_addr[2:0]; dma_cfg_data <= bus_wdata;
                            end
                            default: ;
                        endcase
                        if (tgt == 3'd4 || tgt == 3'd5) mst <= M_APU;
                        else begin bus_ack <= 1'b1; hold <= 1'b1; end
                    end
                    3'd2: begin reg_sel <= bus_wdata[3:0]; bus_ack <= 1'b1; hold <= 1'b1; end
                    3'd3: begin
                        case (reg_sel)
                            4'd0:  r_mode   <= bus_wdata;
                            4'd1:  r_bg     <= bus_wdata;
                            4'd2:  r_abase  <= bus_wdata;
                            4'd3:  r_bbase  <= bus_wdata;
                            4'd4:  r_psize  <= bus_wdata;
                            4'd5:  r_ax     <= bus_wdata;
                            4'd6:  r_ay     <= bus_wdata;
                            4'd7:  r_bx     <= bus_wdata;
                            4'd8:  r_by     <= bus_wdata;
                            4'd9:  r_tbase  <= bus_wdata;
                            4'd10: r_smode  <= bus_wdata;
                            4'd11: r_hsbase <= bus_wdata;
                            4'd12: r_tgt    <= bus_wdata;
                            4'd13: r_addr   <= bus_wdata;
                            4'd14: r_inc    <= bus_wdata;
                            default: r_ahi  <= bus_wdata;
                        endcase
                        if (reg_sel == 4'd12 || reg_sel == 4'd13 || reg_sel == 4'd15) begin
                            pf_valid <= 1'b0; pf_need <= 1'b1;
                        end
                        bus_ack <= 1'b1; hold <= 1'b1;
                    end
                    default: begin bus_ack <= 1'b1; hold <= 1'b1; end
                    endcase
                end else if (bus_new && !bus_we && !(bus_addr == 3'd0 && !pf_valid)) begin
                    bus_rdata <= port_val(bus_addr);
                    bus_ack <= 1'b1; hold <= 1'b1;
                    if (bus_addr == 3'd0) begin
                        r_addr <= addr_next[15:0];
                        r_ahi  <= r_ahi + {15'd0, addr_next[16]};
                        pf_valid <= 1'b0; pf_need <= 1'b1;
                    end else if (bus_addr == 3'd1) begin
                        st_overflow <= 1'b0; st_sprovf <= 1'b0;
                    end
                end else if (pf_need && PREFETCH == 0) begin
                    pf_need <= 1'b0;                     // write-only build: no prefetch
                end else if (pf_need) begin
                    // prefetch the word at the current DATA address
                    pf_need <= 1'b0;
                    cpu_maddr <= r_addr[14:0];
                    if (tgt == 3'd5) begin
                        cm_req <= 1'b1; cm_we <= 1'b0; cm_addr <= smem_addr;
                        mst <= M_PFAPU;
                    end else begin
                        mst <= M_PF0;
                    end
                end
            end
            M_APU: begin
                if ((apu_wr_req && apu_wr_ack) || (cm_req && cm_ack)) begin
                    apu_wr_req <= 1'b0; cm_req <= 1'b0;
                    bus_ack <= 1'b1; hold <= 1'b1;
                    mst <= M_IDLE;
                end
            end
            M_PF0: mst <= M_PF1;                                // cpu_maddr settles
            M_PF1: if (!port_busy) mst <= M_PF2;                // address reaches the RAM
            M_PF2: begin
                if (!pf_need) begin pf_data <= mem_rd; pf_valid <= 1'b1; end
                mst <= M_IDLE;
            end
            M_PFAPU: begin
                if (cm_ack) begin
                    cm_req <= 1'b0;
                    if (!pf_need) begin pf_data <= cm_rdata; pf_valid <= 1'b1; end
                    mst <= M_IDLE;
                end
            end
            default: mst <= M_IDLE;
            endcase
        end
    end
endmodule
