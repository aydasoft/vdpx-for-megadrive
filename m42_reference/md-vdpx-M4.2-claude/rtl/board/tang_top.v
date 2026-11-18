// MD-VDPX hardware top for the Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7).
// Gowin primitives: 2 x rPLL, CLKDIV, 4 x OSER10, 4 x TLVDS_OBUF, IOBUF.
//
// Clocks (27 MHz crystal):
//   PLL A: 27 x 14 / 3 = 126 MHz  (TMDS 5x clock, DDR serializer)  -> CLKDIV /5 = 25.2 MHz pixel
//   PLL B: 27 x 28 / 5 = 151.2 MHz -> CLKOUTD3 = 50.4 MHz system (VDPX, APU, SDRAM, 68000 bus)
module tang_top (
    input         clk27,
    input         btn_s1,              // reset (active high on the Tang Nano 20K)
    input         btn_s2,              // self-test on/off

    // HDMI
    output        tmds_clk_p, tmds_clk_n,
    output  [2:0] tmds_d_p, tmds_d_n,

    // Mega Drive expansion port CN2 (through 74LVC245, 5 V -> 3,3 V)
    input         md_fdc_n,            // A24  /FDC  ($A12000-$A120FF)
    input         md_fdwr_n,           // B24  /FDWR
    input         md_cas0_n,           // A3   /CAS0 (observation only, unproven)
    input         md_fres,             // A25  FRES  (console reset, active high)
    input   [3:1] md_a,                // B3-B5 VA1-VA3
    input  [15:0] md_d,                // A4-A11, A13-A20  VD0-VD15

    // audio: MAX98357A on board (BCK/WS/DIN) and external ADC (PCM1808)
    output        hp_bck, hp_ws, hp_din, pa_en,
    input         adc_dout,
    output        adc_mclk,

    output        led_n,               // LED 6 da placa (pino 20): firme = MD ativo, lento = autoteste, rápido = erro

    // SDRAM inside the GW2AR (fixed names required by the Gowin tools)
    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,
    output        O_sdram_cas_n,
    output        O_sdram_ras_n,
    output        O_sdram_wen_n,
    output  [3:0] O_sdram_dqm,
    output [10:0] O_sdram_addr,
    output  [1:0] O_sdram_ba,
    inout  [31:0] IO_sdram_dq
);
    // ------------------------------------------------------------ clocks
    wire clk126, clk_pix, clk_sys, lock_a, lock_b;

    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(2), .FBDIV_SEL(13), .ODIV_SEL(8),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) u_pll_a (
        .CLKOUT(clk126), .LOCK(lock_a), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0));

    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_div5 (
        .CLKOUT(clk_pix), .HCLKIN(clk126), .RESETN(lock_a), .CALIB(1'b0));

    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(4), .FBDIV_SEL(27), .ODIV_SEL(4),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) u_pll_b (
        .CLKOUT(), .LOCK(lock_b), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(clk_sys),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0));

    wire rst_any = btn_s1 | ~lock_a | ~lock_b;

    // ------------------------------------------------------------ board core
    wire [15:0] md_d_out;
    wire        md_d_oe;
    wire        sd_dq_oe;
    wire [31:0] sd_dq_out;
    wire  [9:0] t0, t1, t2;
    wire  [5:0] leds;
    wire        led_main;

    vdpx_board #(.ST_ROM_FILE("selftest.hex")) u_board (
        .clk_sys(clk_sys), .clk_pix(clk_pix), .rst_btn(rst_any), .selftest_btn(btn_s2),
        .md_fdc_n(md_fdc_n), .md_fdwr_n(md_fdwr_n), .md_cas0_n(md_cas0_n), .md_fres(md_fres),
        .md_a(md_a), .md_d_in(md_d), .md_d_out(md_d_out), .md_d_oe(md_d_oe),
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n), .sd_cas_n(O_sdram_cas_n),
        .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba), .sd_a(O_sdram_addr), .sd_dqm(O_sdram_dqm),
        .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(IO_sdram_dq),
        .i2s_bclk(hp_bck), .i2s_lrck(hp_ws), .i2s_dout(hp_din), .i2s_din(adc_dout),
        .i2s_mclk(adc_mclk), .pa_en(pa_en),
        .tmds0(t0), .tmds1(t1), .tmds2(t2), .leds(leds), .led_main(led_main),
        .dbg_aud_l(), .dbg_aud_r(), .dbg_aud_valid(), .dbg_aud_wr_applied(),
        .dbg_core_ack(), .dbg_core_we(), .dbg_core_addr(), .dbg_core_wdata(), .dbg_core_rdata(),
        .dbg_vblank(), .dbg_commit(), .dbg_commit_addr(), .dbg_late_read(),
        .dbg_overlay_on(), .dbg_fifo_level());

    assign O_sdram_clk = ~clk_sys;
    assign IO_sdram_dq = sd_dq_oe ? sd_dq_out : 32'hZZZZ_ZZZZ;
    // M4.2: input-only pad; no output driver exists on md_d.
    assign led_n       = ~led_main;

    // ------------------------------------------------------------ TMDS serializers
    wire [3:0] ser;
    OSER10 #(.GSREN("false"), .LSREN("true")) u_s0 (.Q(ser[0]), .D0(t0[0]), .D1(t0[1]), .D2(t0[2]), .D3(t0[3]), .D4(t0[4]),
        .D5(t0[5]), .D6(t0[6]), .D7(t0[7]), .D8(t0[8]), .D9(t0[9]), .PCLK(clk_pix), .FCLK(clk126), .RESET(rst_any));
    OSER10 #(.GSREN("false"), .LSREN("true")) u_s1 (.Q(ser[1]), .D0(t1[0]), .D1(t1[1]), .D2(t1[2]), .D3(t1[3]), .D4(t1[4]),
        .D5(t1[5]), .D6(t1[6]), .D7(t1[7]), .D8(t1[8]), .D9(t1[9]), .PCLK(clk_pix), .FCLK(clk126), .RESET(rst_any));
    OSER10 #(.GSREN("false"), .LSREN("true")) u_s2 (.Q(ser[2]), .D0(t2[0]), .D1(t2[1]), .D2(t2[2]), .D3(t2[3]), .D4(t2[4]),
        .D5(t2[5]), .D6(t2[6]), .D7(t2[7]), .D8(t2[8]), .D9(t2[9]), .PCLK(clk_pix), .FCLK(clk126), .RESET(rst_any));
    // TMDS clock channel: 1111100000
    OSER10 #(.GSREN("false"), .LSREN("true")) u_sc (.Q(ser[3]), .D0(1'b1), .D1(1'b1), .D2(1'b1), .D3(1'b1), .D4(1'b1),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0), .D9(1'b0), .PCLK(clk_pix), .FCLK(clk126), .RESET(rst_any));

    TLVDS_OBUF u_o0 (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF u_o1 (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF u_o2 (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF u_oc (.I(ser[3]), .O(tmds_clk_p), .OB(tmds_clk_n));
endmodule
