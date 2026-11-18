// M4 simulation top: board core + SDRAM model (SDRAM clock = inverted system clock).
module board_sim (
    input         clk_sys,
    input         clk_pix,
    input         rst_btn,
    input         selftest_btn,
    input         md_fdc_n, md_fdwr_n, md_cas0_n, md_fres,
    input   [3:1] md_a,
    input  [15:0] md_d_in,
    output [15:0] md_d_out,
    output        md_d_oe, led_main,
    output        i2s_bclk, i2s_lrck, i2s_dout, i2s_mclk,
    input         i2s_din,
    output  [9:0] tmds0, tmds1, tmds2,
    output  [5:0] leds,
    output [15:0] dbg_aud_l, dbg_aud_r,
    output        dbg_aud_valid,
    output [15:0] dbg_aud_wr_applied,
    output        dbg_core_ack, dbg_core_we,
    output  [2:0] dbg_core_addr,
    output [15:0] dbg_core_wdata, dbg_core_rdata,
    output        dbg_vblank,
    output        dbg_commit,
    output  [2:0] dbg_commit_addr,
    output        dbg_late_read,
    output        dbg_overlay_on,
    output  [4:0] dbg_fifo_level,
    output [31:0] sdram_errors
);
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire  [1:0] sd_ba;
    wire [10:0] sd_a;
    wire  [3:0] sd_dqm;
    wire [31:0] sd_dq_out, sd_dq_from_mem;

    vdpx_board #(.SDRAM_INIT(200), .ST_ROM_FILE("selftest.hex")) u_board (
        .clk_sys(clk_sys), .clk_pix(clk_pix), .rst_btn(rst_btn), .selftest_btn(selftest_btn),
        .md_fdc_n(md_fdc_n), .md_fdwr_n(md_fdwr_n), .md_cas0_n(md_cas0_n), .md_fres(md_fres),
        .md_a(md_a), .md_d_in(md_d_in), .md_d_out(md_d_out), .md_d_oe(md_d_oe), .led_main(led_main),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe),
        .sd_dq_in(sd_dq_from_mem),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .i2s_din(i2s_din),
        .i2s_mclk(i2s_mclk), .pa_en(),
        .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2), .leds(leds),
        .dbg_aud_l(dbg_aud_l), .dbg_aud_r(dbg_aud_r), .dbg_aud_valid(dbg_aud_valid),
        .dbg_aud_wr_applied(dbg_aud_wr_applied),
        .dbg_core_ack(dbg_core_ack), .dbg_core_we(dbg_core_we), .dbg_core_addr(dbg_core_addr),
        .dbg_core_wdata(dbg_core_wdata), .dbg_core_rdata(dbg_core_rdata), .dbg_vblank(dbg_vblank),
        .dbg_commit(dbg_commit), .dbg_commit_addr(dbg_commit_addr), .dbg_late_read(dbg_late_read),
        .dbg_overlay_on(dbg_overlay_on), .dbg_fifo_level(dbg_fifo_level));

    sdram_model #(.INIT_MIN(100)) u_mem (
        .sd_clk(~clk_sys), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq_in(sd_dq_oe ? sd_dq_out : 32'hZZZZ_ZZZZ),
        .dq_out(sd_dq_from_mem), .ctrl_oe(sd_dq_oe), .ref_relaxed(1'b0), .errors(sdram_errors), .dq_drv());
endmodule
