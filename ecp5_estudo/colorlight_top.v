// MD-VDPX top for Colorlight i9 v7.2 (LFE5U-45F-6BG381C) - ESTUDO DE PORTE (nao validado em placa)
// 25 MHz -> PLL (VCO 500 MHz): 125 MHz (TMDS DDR, 5 bits por ciclo de pixel... 2 por ciclo),
// 50 MHz sistema, 25 MHz pixel. (Tang: 50,4/25,2; aqui 640x480 a 59,5 Hz, ACR CTS=25000.)
module colorlight_top (
    input         clk25,
    input         btn_rst,             // ativo alto (na placa de extensao/adaptadora)
    input         btn_s2,
    output  [3:0] gpdi_dp,             // HDMI pseudo-diferencial (LVCMOS33D): 0..2 dados, 3 clock

    // CN2 via SN74LVC4245A (A=5 V console, B=3,3 V FPGA), direcao fixa A->B
    input         md_fdc_n, md_fdwr_n, md_cas0_n, md_fres,
    input   [3:1] md_a,
    input  [15:0] md_d,

    output        i2s_bck, i2s_ws, i2s_dout,
    input         adc_dout,
    output        adc_mclk,
    output        led,

    // SDRAM M12L64322A (CS/CKE/DQM fixos na placa)
    output        sdram_clk,
    output        sdram_ras_n, sdram_cas_n, sdram_we_n,
    output  [1:0] sdram_ba,
    output [10:0] sdram_a,
    inout  [31:0] sdram_dq
);
    wire clk125, clk_sys, clk_pix, locked;
    (* FREQUENCY_PIN_CLKI="25" *) (* FREQUENCY_PIN_CLKOP="125" *)
    (* FREQUENCY_PIN_CLKOS="50" *) (* FREQUENCY_PIN_CLKOS2="25" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"), .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"), .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1), .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(5),
        .CLKOP_ENABLE("ENABLED"),  .CLKOP_DIV(4),   .CLKOP_CPHASE(3),   .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"),  .CLKOS_DIV(10),  .CLKOS_CPHASE(9),   .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("ENABLED"), .CLKOS2_DIV(20), .CLKOS2_CPHASE(19), .CLKOS2_FPHASE(0)
    ) u_pll (
        .RST(1'b0), .STDBY(1'b0), .CLKI(clk25), .CLKOP(clk125), .CLKOS(clk_sys), .CLKOS2(clk_pix),
        .CLKFB(clk125), .CLKINTFB(), .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1),
        .PHASESTEP(1'b1), .PHASELOADREG(1'b1), .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0), .LOCK(locked));

    wire rst_any = btn_rst | ~locked;

    wire        sd_dq_oe;
    wire [31:0] sd_dq_out;
    wire  [3:0] sd_dqm_unused;           // DQM fixo em GND na i9: escrita de 16 bits exige leitura-modifica-escrita
    wire        sd_cke_u, sd_cs_u;
    wire  [9:0] t0, t1, t2;
    wire        led_main;

    vdpx_board #(.ST_ROM_FILE("selftest.hex")) u_board (
        .clk_sys(clk_sys), .clk_pix(clk_pix), .rst_btn(rst_any), .selftest_btn(btn_s2),
        .md_fdc_n(md_fdc_n), .md_fdwr_n(md_fdwr_n), .md_cas0_n(md_cas0_n), .md_fres(md_fres),
        .md_a(md_a), .md_d_in(md_d), .md_d_out(), .md_d_oe(),
        .sd_cke(sd_cke_u), .sd_cs_n(sd_cs_u), .sd_ras_n(sdram_ras_n), .sd_cas_n(sdram_cas_n),
        .sd_we_n(sdram_we_n), .sd_ba(sdram_ba), .sd_a(sdram_a), .sd_dqm(sd_dqm_unused),
        .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sdram_dq),
        .i2s_bclk(i2s_bck), .i2s_lrck(i2s_ws), .i2s_dout(i2s_dout), .i2s_din(adc_dout),
        .i2s_mclk(adc_mclk), .pa_en(),
        .tmds0(t0), .tmds1(t1), .tmds2(t2), .leds(), .led_main(led_main),
        .dbg_aud_l(), .dbg_aud_r(), .dbg_aud_valid(), .dbg_aud_wr_applied(),
        .dbg_core_ack(), .dbg_core_we(), .dbg_core_addr(), .dbg_core_wdata(), .dbg_core_rdata(),
        .dbg_vblank(), .dbg_commit(), .dbg_commit_addr(), .dbg_late_read(),
        .dbg_overlay_on(), .dbg_fifo_level());

    assign sdram_dq = sd_dq_oe ? sd_dq_out : 32'hZZZZ_ZZZZ;
    assign led = ~led_main;

    // SDRAM clock = clk_sys invertido, por ODDR (como O_sdram_clk = ~clk_sys na Tang)
    ODDRX1F u_sdclk (.D0(1'b0), .D1(1'b1), .SCLK(clk_sys), .RST(1'b0), .Q(sdram_clk));

    // ------------------------------------------------ TMDS: 10 bits/pixel, 2 bits por ciclo de 125 MHz
    // carga sincronizada com clk_pix (clk_pix e clk125 vem do mesmo VCO; 125 = 5 x 25)
    reg [9:0] h0, h1, h2;                 // estabilizados no dominio de pixel
    always @(posedge clk_pix) begin h0 <= t0; h1 <= t1; h2 <= t2; end
    reg [2:0] ph = 0;
    reg [9:0] s0, s1, s2, sc;
    always @(posedge clk125) begin
        ph <= (ph == 3'd4) ? 3'd0 : ph + 3'd1;
        if (ph == 3'd4) begin s0 <= h0; s1 <= h1; s2 <= h2; sc <= 10'b0000011111; end
        else begin s0 <= s0 >> 2; s1 <= s1 >> 2; s2 <= s2 >> 2; sc <= sc >> 2; end
    end
    ODDRX1F u_o0 (.D0(s0[0]), .D1(s0[1]), .SCLK(clk125), .RST(1'b0), .Q(gpdi_dp[0]));
    ODDRX1F u_o1 (.D0(s1[0]), .D1(s1[1]), .SCLK(clk125), .RST(1'b0), .Q(gpdi_dp[1]));
    ODDRX1F u_o2 (.D0(s2[0]), .D1(s2[1]), .SCLK(clk125), .RST(1'b0), .Q(gpdi_dp[2]));
    ODDRX1F u_oc (.D0(sc[0]), .D1(sc[1]), .SCLK(clk125), .RST(1'b0), .Q(gpdi_dp[3]));
endmodule
