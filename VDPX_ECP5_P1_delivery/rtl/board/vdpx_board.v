// MD-VDPX board core (technology independent): everything that goes on the
// Tang Nano 20K except clock generation and I/O primitives (see tang_top.v).
//
//   clk_sys 50.4 MHz : VDPX core, APU, 68000 bus adapter, SDRAM controller
//   clk_pix 25.2 MHz : HDMI transmitter (TMDS symbols to the serializers)
//
// Mega Drive side: expansion port CN2 through 74LVC245 buffers (no other glue):
//   /FDC (A24), /FDWR (B24), /CAS0 (A3), FRES (A25), VA1-VA3 (B3-B5), VD0-VD15.
//   The console decodes $A12000-$A120FF and generates /DTACK itself.
module vdpx_board #(
    parameter SDRAM_INIT  = 10080,
    parameter ST_ROM_FILE = "selftest.hex",
    // ECP5-P1 clock plan. CLK50 = 0: clk_sys 50.4 MHz / clk_pix 25.2 MHz (Tang Nano 20K,
    // M4.2, default). CLK50 = 1: clk_sys 50.0 MHz / clk_pix 25.0 MHz (Colorlight i9, 25 MHz
    // crystal). Only the audio frame divider, the ADC MCLK divider, the HDMI ACR CTS and
    // the probe's time unit depend on it; video timing is in pixel clocks (800 x 525).
    parameter CLK50       = 0,
    // SDRAM_RMW = 1: SDRAM without usable DQM (Colorlight i9: DQM0-3 tied to GND);
    // 16-bit writes become read-modify-write of the 32-bit word (sdram_ctrl.v).
    parameter SDRAM_RMW   = 0,
    // read capture edge of sdram_ctrl (2 = M4.2; 3 = Colorlight i9 with a 288 deg SDRAM clock)
    parameter SDRAM_RD_CAPTURE = 2
) (
    input             clk_sys,
    input             clk_pix,
    input             rst_btn,          // active high, asynchronous
    input             selftest_btn,     // S2: shows/hides the diagnostic overlay (M4.2)

    // Mega Drive expansion port (CN2)
    input             md_fdc_n,
    input             md_fdwr_n,
    input             md_cas0_n,
    input             md_fres,          // console reset (active high)
    input       [3:1] md_a,
    input      [15:0] md_d_in,
    output     [15:0] md_d_out,
    output            md_d_oe,

    // SDRAM (inside the GW2AR)
    output            sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output      [1:0] sd_ba,
    output     [10:0] sd_a,
    output      [3:0] sd_dqm,
    output     [31:0] sd_dq_out,
    output            sd_dq_oe,
    input      [31:0] sd_dq_in,

    // audio
    output            i2s_bclk, i2s_lrck, i2s_dout,
    input             i2s_din,          // ADC (Mega Drive FM/PSG)
    output reg        i2s_mclk,         // 256 fs for the ADC
    output            pa_en,

    // HDMI (pixel clock domain)
    output      [9:0] tmds0, tmds1, tmds2,

    output      [5:0] leds,             // active high status
    output            led_main,         // single board LED: steady = MD active, slow blink = self-test, fast = error
    // debug/verification (system domain)
    output     [15:0] dbg_aud_l, dbg_aud_r,
    output            dbg_aud_valid,
    output     [15:0] dbg_aud_wr_applied,
    output            dbg_core_ack, dbg_core_we,
    output      [2:0] dbg_core_addr,
    output     [15:0] dbg_core_wdata, dbg_core_rdata,
    output            dbg_vblank,
    output            dbg_commit,
    output      [2:0] dbg_commit_addr,
    output            dbg_late_read,
    output            dbg_overlay_on,
    output      [4:0] dbg_fifo_level
);
    // ------------------------------------------------------------ resets
    // console reset (FRES) also resets the VDPX, so a game restarts cleanly
    reg [1:0] fres_s;
    always @(posedge clk_sys) fres_s <= {fres_s[0], md_fres};
    reg [2:0] rs_sys = 3'b111, rs_pix = 3'b111;
    always @(posedge clk_sys or posedge rst_btn)
        if (rst_btn) rs_sys <= 3'b111; else rs_sys <= {rs_sys[1:0], 1'b0};
    always @(posedge clk_pix or posedge rst_btn)
        if (rst_btn) rs_pix <= 3'b111; else rs_pix <= {rs_pix[1:0], 1'b0};
    wire rst  = rs_sys[2] | fres_s[1];
    wire prst = rs_pix[2];

    // ------------------------------------------------------------ bus sources
    wire        a_cs, a_we, a_ack;
    wire  [2:0] a_addr;
    wire [15:0] a_wdata;
    wire        t_cs, t_we;
    wire  [2:0] t_addr;
    wire [15:0] t_wdata;
    wire        core_ack;
    wire [15:0] core_rdata;
    wire        vblank;

    wire [15:0] peek_data;
    wire  [2:0] peek_addr, rd_commit_addr;
    wire        peek_valid_core, rd_commit, late_read, md_act, md_overflow, md_drop;
    wire  [4:0] md_level;
    wire        peek_valid = peek_valid_core & ~st_on;

    md_fdc_adapter u_adp (
        .clk(clk_sys), .rst(rst),
        .fdc_n(md_fdc_n), .fdwr_n(md_fdwr_n), .cas0_n(md_cas0_n), .a(md_a),
        .d_in(md_d_in), .d_out(md_d_out), .d_oe(md_d_oe),
        .core_cs(a_cs), .core_we(a_we), .core_addr(a_addr), .core_wdata(a_wdata), .core_ack(a_ack),
        .peek_addr(peek_addr), .peek_data(peek_data), .peek_valid(peek_valid),
        .rd_commit(rd_commit), .rd_commit_addr(rd_commit_addr),
        .late_read(late_read), .activity(md_act), .overflow(md_overflow), .drop(md_drop),
        .fifo_level(md_level));

    // self-test active after reset; the first 68000 access (or the button) turns it off
    reg st_active, md_seen, btn_d1, btn_d2;
    reg [2:0] st_hist;
    wire st_on = st_active;
    always @(posedge clk_sys) begin
        if (rst) begin
            st_active <= 1'b1; md_seen <= 1'b0;
        end else begin
            if (md_act) begin md_seen <= 1'b1; st_active <= 1'b0; end
        end
    end

    vdpx_selftest #(.ROM_FILE(ST_ROM_FILE)) u_st (
        .clk(clk_sys), .rst(rst), .enable(st_on), .vblank(vblank),
        .bus_cs(t_cs), .bus_we(t_we), .bus_addr(t_addr), .bus_wdata(t_wdata),
        .bus_ack(st_on ? core_ack : 1'b0));

    // a few idle cycles when switching sources, so the core sees /cs drop
    always @(posedge clk_sys) st_hist <= {st_hist[1:0], st_active};
    wire        md_gate = !st_on && (st_hist == 3'b000);
    wire        c_cs    = st_on ? (t_cs && st_hist == 3'b111) : (a_cs && md_gate);
    wire        c_we    = st_on ? t_we    : a_we;
    wire  [2:0] c_addr  = st_on ? t_addr  : a_addr;
    wire [15:0] c_wdata = st_on ? t_wdata : a_wdata;
    assign a_ack = md_gate ? core_ack : 1'b0;

    // ------------------------------------------------------------ VDPX core
    wire  [7:0] vr, vg, vb;
    wire        vhs, vvs, vde, vce;
    wire        sm_req, sm_we, sm_ack, sd_ready;
    wire [21:0] sm_addr;
    wire [15:0] sm_wdata, sm_rdata;
    wire [15:0] aud_l, aud_r;
    wire        aud_valid;

    localparam I2S_NUM = CLK50 ? 3    : 1;      // 48 kHz frame = I2S_DEN/I2S_NUM clocks
    localparam I2S_DEN = CLK50 ? 3125 : 1050;
    localparam ACR_CTS = CLK50 ? 25000 : 25200; // f_TMDS * 6144 / (128 * 48000)
    vdpx_top #(.SMEM_AW(22), .PREFETCH(0), .I2S_NUM(I2S_NUM), .I2S_DEN(I2S_DEN)) u_vdpx (   // write-only board: no read prefetch
        .clk(clk_sys), .rst(rst),
        .bus_cs(c_cs), .bus_we(c_we), .bus_addr(c_addr), .bus_wdata(c_wdata),
        .bus_rdata(core_rdata), .bus_ack(core_ack),
        .peek_addr(peek_addr), .peek_data(peek_data), .peek_valid(peek_valid_core),
        .rd_commit(rd_commit & ~st_on), .rd_commit_addr(rd_commit_addr),
        .vid_r(vr), .vid_g(vg), .vid_b(vb), .vid_hs_n(vhs), .vid_vs_n(vvs), .vid_de(vde), .vid_ce(vce),
        .vblank(vblank),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .i2s_din(i2s_din),
        .aud_l(aud_l), .aud_r(aud_r), .aud_valid(aud_valid), .aud_tick(),
        .aud_wr_applied(dbg_aud_wr_applied),
        .sm_req(sm_req), .sm_we(sm_we), .sm_addr(sm_addr), .sm_wdata(sm_wdata),
        .sm_ack(sm_ack), .sm_rdata(sm_rdata));

    sdram_ctrl #(.INIT_CYCLES(SDRAM_INIT), .RMW(SDRAM_RMW), .RD_CAPTURE(SDRAM_RD_CAPTURE)) u_sdram (
        .clk(clk_sys), .rst(rst),
        .req(sm_req), .we(sm_we), .addr(sm_addr), .wdata(sm_wdata),
        .ack(sm_ack), .rdata(sm_rdata), .ready(sd_ready),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm),
        .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in));

    // EXPERIMENTAL ADC clock: fractional jitter; physical ADC qualification BLOCKED.
    // Average 256 fs = 12.288 MHz: 512 toggles per I2S frame (I2S_DEN/I2S_NUM clocks).
    // 50.4 MHz: step 512, modulus 1050 (M4.2); 50.0 MHz: step 1536, modulus 3125.
    localparam [12:0] MC_STEP = 13'd512 * I2S_NUM;
    localparam [12:0] MC_DEN  = I2S_DEN;
    reg [12:0] mclk_acc;
    always @(posedge clk_sys) begin
        if (rst) begin mclk_acc <= 0; i2s_mclk <= 1'b0; end
        else if (mclk_acc + MC_STEP >= MC_DEN) begin
            mclk_acc <= mclk_acc + MC_STEP - MC_DEN; i2s_mclk <= ~i2s_mclk;
        end else mclk_acc <= mclk_acc + MC_STEP;
    end
    assign pa_en = 1'b1;

    // ------------------------------------------------------------ video: system -> pixel domain
    wire [26:0] vf_q;
    wire        vf_empty, vf_full;
    wire  [4:0] vf_level;
    reg         vf_run;
    // ------------------------------------------------------------ CN2 probe + diagnostic overlay
    // S2 toggles the overlay (debounced: sampled every 2.6 ms). Visible by default.
    reg [16:0] db_cnt;
    reg        btn_s1, btn_s2, ov_on;
    always @(posedge clk_sys) begin
        db_cnt <= db_cnt + 17'd1;
        if (db_cnt == 0) begin btn_s1 <= selftest_btn; btn_s2 <= btn_s1; end
        if (rst) ov_on <= 1'b1;
        else if (db_cnt == 0 && btn_s1 && !btn_s2) ov_on <= ~ov_on;
    end

    wire [31:0] p_acc, p_wr, p_wrc, p_rd, p_rdc, p_cout;
    wire [15:0] p_drop, p_lastd, p_fres;
    wire  [4:0] p_hw;
    wire  [2:0] p_lasta;
    wire  [7:0] p_fwmin, p_fwmax, p_frmin, p_frmax, p_f2wmin, p_f2wmax, p_wwmin, p_wwmax, p_f2cmin, p_f2cmax;
    wire        p_fresnow;
    cn2_probe u_probe (
        .clk(clk_sys), .rst(rst),
        .fdc_n(md_fdc_n), .fdwr_n(md_fdwr_n), .cas0_n(md_cas0_n), .fres(md_fres),
        .a(md_a), .d(md_d_in), .acc_pulse(md_act), .drop_pulse(md_drop), .fifo_level(md_level),
        .n_acc(p_acc), .n_drop(p_drop), .fifo_hw(p_hw), .last_a(p_lasta), .last_d(p_lastd),
        .n_wr(p_wr), .n_wr_cas0(p_wrc), .n_rd(p_rd), .n_rd_cas0(p_rdc), .n_cas_out(p_cout),
        .fdcw_min(p_fwmin), .fdcw_max(p_fwmax), .fdcr_min(p_frmin), .fdcr_max(p_frmax),
        .f2w_min(p_f2wmin), .f2w_max(p_f2wmax), .ww_min(p_wwmin), .ww_max(p_wwmax),
        .f2c_min(p_f2cmin), .f2c_max(p_f2cmax), .n_fres(p_fres), .fres_now(p_fresnow));

    wire [7:0] or_, og, ob;
    wire       ohs, ovs, ode, oce;
    vdpx_overlay u_ovl (
        .clk(clk_sys), .rst(rst), .enable(ov_on),
        .in_r(vr), .in_g(vg), .in_b(vb), .in_hs_n(vhs), .in_vs_n(vvs), .in_de(vde), .in_ce(vce),
        .out_r(or_), .out_g(og), .out_b(ob), .out_hs_n(ohs), .out_vs_n(ovs), .out_de(ode), .out_ce(oce),
        .f_st(st_on), .f_md(md_seen), .f_n_acc(p_acc), .f_n_drop(p_drop), .f_fifo_hw(p_hw),
        .f_last_off(p_lasta), .f_last_d(p_lastd), .f_n_wr(p_wr), .f_n_wr_cas0(p_wrc),
        .f_n_rd(p_rd), .f_n_rd_cas0(p_rdc), .f_fdcw_min(p_fwmin), .f_fdcw_max(p_fwmax),
        .f_fdcr_min(p_frmin), .f_fdcr_max(p_frmax), .f_f2w_min(p_f2wmin), .f_f2w_max(p_f2wmax),
        .f_ww_min(p_wwmin), .f_ww_max(p_wwmax), .f_f2c_min(p_f2cmin), .f_f2c_max(p_f2cmax),
        .f_fres_now(p_fresnow), .f_n_fres(p_fres), .f_n_cas_out(p_cout),
        .f_unit_i(CLK50 ? 5'd20 : 5'd19), .f_unit_f(CLK50 ? 4'd0 : 4'd8));   // 1 tick = 20.0 / 19.8 ns

    async_fifo #(.DW(27), .AW(4)) u_vfifo (
        .wclk(clk_sys), .wrst(rst), .we(oce), .wdata({or_, og, ob, ohs, ovs, ode}), .wfull(vf_full),
        .rclk(clk_pix), .rrst(prst), .re(vf_run), .rdata(vf_q), .rempty(vf_empty), .rlevel(vf_level));
    reg vf_err;
    always @(posedge clk_pix) begin
        if (prst) begin vf_run <= 1'b0; vf_err <= 1'b0; end
        else begin
            if (!vf_run && vf_level >= 5'd8) vf_run <= 1'b1;
            if (vf_run && vf_empty) vf_err <= 1'b1;
        end
    end

    // ------------------------------------------------------------ audio: system -> pixel domain
    reg [31:0] a_hold;
    reg        a_tog;
    always @(posedge clk_sys) begin
        if (rst) a_tog <= 1'b0;
        else if (aud_valid) begin a_hold <= {aud_l, aud_r}; a_tog <= ~a_tog; end
    end
    reg [2:0] a_sync;
    reg       a_we_p;
    reg [31:0] a_dat_p;
    always @(posedge clk_pix) begin
        a_sync <= {a_sync[1:0], a_tog};
        a_we_p <= a_sync[2] ^ a_sync[1];
        if (a_sync[2] ^ a_sync[1]) a_dat_p <= a_hold;   // stable for ~1000 cycles
    end

    // ------------------------------------------------------------ HDMI
    wire hdmi_locked, aud_ovf;
    hdmi_tx #(.ACR_CTS_VAL(ACR_CTS)) u_hdmi (
        .clk(clk_pix), .rst(prst),
        .r(vf_q[26:19]), .g(vf_q[18:11]), .b(vf_q[10:3]),
        .hs_n(vf_q[2]), .vs_n(vf_q[1]), .de(vf_q[0]),
        .aud_we(a_we_p), .aud_l(a_dat_p[31:16]), .aud_r(a_dat_p[15:0]),
        .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2),
        .locked(hdmi_locked), .aud_overflow(aud_ovf));

    assign leds = {aud_ovf, hdmi_locked, vf_err, sd_ready, md_seen, st_on};
    reg [24:0] blink;
    always @(posedge clk_sys) blink <= blink + 25'd1;
    wire err_any = vf_err | aud_ovf | late_read | md_overflow | ~sd_ready;
    assign led_main = err_any ? blink[21] : st_on ? blink[24] : (md_seen & hdmi_locked);

    assign dbg_aud_l = aud_l;
    assign dbg_aud_r = aud_r;
    assign dbg_aud_valid = aud_valid;
    assign dbg_core_ack = core_ack;
    assign dbg_core_we = c_we;
    assign dbg_core_addr = c_addr;
    assign dbg_core_wdata = c_wdata;
    assign dbg_core_rdata = core_rdata;
    assign dbg_vblank = vblank;
    assign dbg_commit = rd_commit & ~st_on;
    assign dbg_commit_addr = rd_commit_addr;
    assign dbg_late_read = late_read;
    assign dbg_overlay_on = ov_on;
    assign dbg_fifo_level = md_level;
endmodule
