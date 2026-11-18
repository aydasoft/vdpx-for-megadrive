// MD-VDPX ECP5-P1 core: everything of the Colorlight i9 build except the PLL and the pads.
// Simulated as is (sim/ecp5/ecp5_board_sim.v) with the clocks driven by the testbench.
//
//   clk_x5  125 MHz : TMDS serializer (ODDRX1F, 2 bits per cycle)
//   clk_sys  50 MHz : VDPX, APU, CN2 adapter + probe, SDRAM controller (CLK50 = 1)
//   clk_pix  25 MHz : HDMI transmitter
//   clk_sd   50 MHz, 288 deg after clk_sys (+16 ns): SDRAM clock pin only (ODDRX1F copy).
//            Commands/data leave on clk_sys and are sampled by the SDRAM 16 ns later; read
//            data (CL2) is captured on the 3rd clk_sys edge after READ (RD_CAPTURE = 3).
//            Budget with the M12L64322A data sheet: SDRAM_32BIT_REPORT.md.
//
// Reset: rst_btn (asynchronous, active high) = PLL not locked or reset button. vdpx_board
// synchronizes its release in clk_sys and clk_pix; here it is synchronized to clk_x5.
module vdpx_ecp5_core #(
    parameter SDRAM_INIT  = 10080,          // 201.6 us at 50 MHz (>= 200 us)
    parameter ST_ROM_FILE = "selftest_dma.hex",   // P2: self-test with the DMA demonstration
    parameter ST_ROM_AW   = 13
) (
    input             clk_x5, clk_sys, clk_pix, clk_sd,
    input             rst_btn,              // async, active high
    input             selftest_btn,         // overlay on/off (tie 0 if no button)

    // CN2 through SN74LVC4245A, all inputs (write-only)
    input             md_fdc_n, md_fdwr_n, md_cas0_n, md_fres,
    input       [3:1] md_a,
    input      [15:0] md_d,

    // SDRAM (CS, CKE and DQM are fixed on the Colorlight i9)
    output            sd_clk,
    output            sd_ras_n, sd_cas_n, sd_we_n,
    output      [1:0] sd_ba,
    output     [10:0] sd_a,
    output     [31:0] sd_dq_out,
    output            sd_dq_oe,
    input      [31:0] sd_dq_in,

    // audio
    output            i2s_bclk, i2s_lrck, i2s_dout, i2s_mclk,
    input             i2s_din,

    // HDMI (to the LVCMOS33D pads)
    output      [3:0] tmds_q,

    output            led_main,
    output      [5:0] leds,

    // verification taps (unused on the board)
    output      [9:0] dbg_tmds0, dbg_tmds1, dbg_tmds2,
    output     [15:0] dbg_aud_l, dbg_aud_r,
    output            dbg_aud_valid,
    output     [15:0] dbg_aud_wr_applied,
    output            dbg_core_ack, dbg_core_we,
    output      [2:0] dbg_core_addr,
    output     [15:0] dbg_core_wdata,
    output            dbg_vblank, dbg_commit, dbg_late_read, dbg_overlay_on,
    output      [2:0] dbg_commit_addr,
    output            dbg_md_d_oe,
    // P2 DMA taps
    output            dbg_vw_we, dbg_vw_dma,
    output     [14:0] dbg_vw_addr,
    output     [15:0] dbg_vw_data,
    output     [99:0] dbg_dma_status,
    output     [28:0] dbg_dma_events
);
    // ------------------------------------------------------------ board core (50 MHz plan, RMW SDRAM)
    wire [15:0] md_d_out_unused;
    wire        md_d_oe;
    wire        sd_cke_u, sd_cs_n_u;
    wire  [3:0] sd_dqm_u;
    wire  [9:0] t0, t1, t2;

    vdpx_board #(.SDRAM_INIT(SDRAM_INIT), .ST_ROM_FILE(ST_ROM_FILE), .ST_ROM_AW(ST_ROM_AW), .CLK50(1), .SDRAM_RMW(1),
                 .SDRAM_RD_CAPTURE(3)) u_board (
        .clk_sys(clk_sys), .clk_pix(clk_pix), .rst_btn(rst_btn), .selftest_btn(selftest_btn),
        .md_fdc_n(md_fdc_n), .md_fdwr_n(md_fdwr_n), .md_cas0_n(md_cas0_n), .md_fres(md_fres),
        .md_a(md_a), .md_d_in(md_d), .md_d_out(md_d_out_unused), .md_d_oe(md_d_oe),
        .sd_cke(sd_cke_u), .sd_cs_n(sd_cs_n_u), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm_u),
        .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .i2s_din(i2s_din),
        .i2s_mclk(i2s_mclk), .pa_en(),
        .tmds0(t0), .tmds1(t1), .tmds2(t2), .leds(leds), .led_main(led_main),
        .dbg_aud_l(dbg_aud_l), .dbg_aud_r(dbg_aud_r), .dbg_aud_valid(dbg_aud_valid),
        .dbg_aud_wr_applied(dbg_aud_wr_applied),
        .dbg_core_ack(dbg_core_ack), .dbg_core_we(dbg_core_we), .dbg_core_addr(dbg_core_addr),
        .dbg_core_wdata(dbg_core_wdata), .dbg_core_rdata(), .dbg_vblank(dbg_vblank),
        .dbg_commit(dbg_commit), .dbg_commit_addr(dbg_commit_addr), .dbg_late_read(dbg_late_read),
        .dbg_overlay_on(dbg_overlay_on), .dbg_fifo_level(),
        .dbg_vw_we(dbg_vw_we), .dbg_vw_dma(dbg_vw_dma), .dbg_vw_addr(dbg_vw_addr), .dbg_vw_data(dbg_vw_data),
        .dbg_dma_status(dbg_dma_status), .dbg_dma_events(dbg_dma_events));

    // M4.2 write-only rule: md_d has no output path. md_d_oe is only observed (must stay 0).
    assign dbg_md_d_oe = md_d_oe;
    assign dbg_tmds0 = t0;
    assign dbg_tmds1 = t1;
    assign dbg_tmds2 = t2;

    // ------------------------------------------------------------ 125 MHz reset
    reg [2:0] rs_x5 = 3'b111;
    always @(posedge clk_x5 or posedge rst_btn)
        if (rst_btn) rs_x5 <= 3'b111; else rs_x5 <= {rs_x5[1:0], 1'b0};

    ecp5_tmds_ser u_ser (
        .clk_pix(clk_pix), .clk_x5(clk_x5), .rst_x5(rs_x5[2]),
        .t0(t0), .t1(t1), .t2(t2), .q(tmds_q));

    // SDRAM clock = clk_sd through an output DDR register (high, then low: a copy of clk_sd)
    ODDRX1F u_sdclk (.SCLK(clk_sd), .RST(1'b0), .D0(1'b1), .D1(1'b0), .Q(sd_clk));
endmodule
