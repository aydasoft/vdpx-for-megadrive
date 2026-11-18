// ECP5-P1 simulation top: vdpx_ecp5_core (the RTL that goes into the bitstream, minus the
// EHXPLLL and the pads) + SDRAM model wired like the Colorlight i9:
//   - SDRAM clock = the ODDRX1F output of the core (inverted clk_sys),
//   - DQM0-3 tied to GND (model with HONOR_DQM = 0: every WRITE stores 32 bits),
//   - CS# low, CKE high (the controller's CS/CKE outputs are not connected).
// The testbench drives clk_x5/clk_sys/clk_pix (125/50/25 MHz, rising edges aligned like the
// PLL outputs), clk_sd (50 MHz, 16 ns after clk_sys) and pll_locked.
// Board delays on the read path: the SDRAM model's data (zero delay, valid from its edge N+1
// to N+2) is exported (mem_dq/mem_drv); the testbench applies the worst-case window of the
// board (start +tOC+tAC+tIN_max, end +tOC+tOH+tIN_min) and drives sd_dq_board back in.
module ecp5_board_sim (
    input         clk_x5, clk_sys, clk_pix, clk_sd,
    input  [31:0] sd_dq_board,           // DQ as seen by the FPGA flip-flops (TB board model)
    output [31:0] mem_dq,
    output        mem_drv,
    input         pll_locked,
    input         sdram_ref_relaxed,     // lock-loss test only (see sdram_model.v)
    input         md_fdc_n, md_fdwr_n, md_cas0_n, md_fres,
    input   [3:1] md_a,
    input  [15:0] md_d,
    output        i2s_bclk, i2s_lrck, i2s_dout, i2s_mclk,
    input         i2s_din,
    output  [3:0] tmds_q,
    output  [9:0] dbg_tmds0, dbg_tmds1, dbg_tmds2,
    output  [5:0] leds,
    output        led_main,
    output [15:0] dbg_aud_l, dbg_aud_r,
    output        dbg_aud_valid,
    output [15:0] dbg_aud_wr_applied,
    output        dbg_core_ack, dbg_core_we,
    output  [2:0] dbg_core_addr,
    output [15:0] dbg_core_wdata,
    output        dbg_vblank, dbg_commit, dbg_late_read, dbg_overlay_on,
    output  [2:0] dbg_commit_addr,
    output        dbg_md_d_oe,
    output        sd_dq_oe_o,
    output [31:0] sdram_errors,
    output [31:0] sdram_writes
);
    wire        sd_clk, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire  [1:0] sd_ba;
    wire [10:0] sd_a;
    wire [31:0] sd_dq_out, sd_dq_from_mem;

    vdpx_ecp5_core #(.SDRAM_INIT(200), .ST_ROM_FILE("selftest.hex")) u_core (
        .clk_x5(clk_x5), .clk_sys(clk_sys), .clk_pix(clk_pix), .clk_sd(clk_sd),
        .rst_btn(~pll_locked), .selftest_btn(1'b0),
        .md_fdc_n(md_fdc_n), .md_fdwr_n(md_fdwr_n), .md_cas0_n(md_cas0_n), .md_fres(md_fres),
        .md_a(md_a), .md_d(md_d),
        .sd_clk(sd_clk), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_a(sd_a), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_board),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .i2s_mclk(i2s_mclk), .i2s_din(i2s_din),
        .tmds_q(tmds_q), .led_main(led_main), .leds(leds),
        .dbg_tmds0(dbg_tmds0), .dbg_tmds1(dbg_tmds1), .dbg_tmds2(dbg_tmds2),
        .dbg_aud_l(dbg_aud_l), .dbg_aud_r(dbg_aud_r), .dbg_aud_valid(dbg_aud_valid),
        .dbg_aud_wr_applied(dbg_aud_wr_applied),
        .dbg_core_ack(dbg_core_ack), .dbg_core_we(dbg_core_we), .dbg_core_addr(dbg_core_addr),
        .dbg_core_wdata(dbg_core_wdata), .dbg_vblank(dbg_vblank), .dbg_commit(dbg_commit),
        .dbg_late_read(dbg_late_read), .dbg_overlay_on(dbg_overlay_on), .dbg_commit_addr(dbg_commit_addr),
        .dbg_md_d_oe(dbg_md_d_oe));

    assign sd_dq_oe_o = sd_dq_oe;

    sdram_model #(.INIT_MIN(100), .HONOR_DQM(0)) u_mem (
        .sd_clk(sd_clk), .cke(1'b1), .cs_n(1'b0), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq_in(sd_dq_oe ? sd_dq_out : 32'hZZZZ_ZZZZ),
        .dq_out(sd_dq_from_mem), .ctrl_oe(sd_dq_oe), .ref_relaxed(sdram_ref_relaxed), .errors(sdram_errors), .dq_drv(mem_drv));
    assign mem_dq = sd_dq_from_mem;
    assign sdram_writes = u_mem.n_wr;
endmodule
