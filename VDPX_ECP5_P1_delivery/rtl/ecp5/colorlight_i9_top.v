// MD-VDPX ECP5-P1 top: Colorlight i9 v7.2 (LFE5U-45F-6BG381C) on the i5/i9 Ext-Board.
// Pin constraints: board/colorlight_i9_v72_extboard.lpf
//
// Clocks: 25 MHz crystal (P3) -> EHXPLLL, VCO 500 MHz (CLKI_DIV 1, CLKFB_DIV 5 from CLKOP):
//   CLKOP  /4  = 125 MHz  TMDS serializer (DDR, 250 Mbit/s per lane)
//   CLKOS  /10 =  50 MHz  system
//   CLKOS2 /20 =  25 MHz  pixel (640x480, 800x525 -> 59.52 Hz)
//   CLKOS3 /10 =  50 MHz  SDRAM clock pin, 288 deg (16 ns = 8 VCO cycles) after CLKOS:
//                         CPHASE = 8 + 2 (ecppll convention below), FPHASE 0. Tuning knob for
//                         hardware bring-up: 1 CPHASE step = 2 ns, 1 FPHASE step = 0.25 ns.
// All three outputs come from the same VCO. Phase settings follow Project Trellis
// "ecppll" (libtrellis/tools/ecppll.cpp): primary CPHASE = half a CLKOP period in VCO
// cycles (500/125/2 = 2), secondaries at 0 degrees get the same CPHASE (0 + 2), FPHASE 0.
// Equal CPHASE on every divider -> the dividers start together and the rising edges of
// 125/50/25 MHz coincide every 40 ns (the serializer also tolerates a fixed offset).
// Reset: held while the PLL is not locked; released by synchronizers in each domain.
module colorlight_i9_top (
    input         clk25,

    // HDMI on the Ext-Board (LVCMOS33D pseudo-differential, N pins implied by the pair)
    output  [3:0] gpdi_dp,             // [0] D0, [1] D1, [2] D2, [3] clock

    // CN2 (future SN74LVC4245A adapter, B side 3.3 V): inputs only - PROVISIONAL pins
    input         md_fdc_n, md_fdwr_n, md_cas0_n, md_fres,
    input   [3:1] md_a,
    input  [15:0] md_d,

    // audio (I2S DAC + PCM1808 ADC) - PROVISIONAL pins
    output        i2s_bck, i2s_ws, i2s_dout, adc_mclk,
    input         adc_dout,

    output        led_n,               // L2, active low (shared with SODIMM pin 41)

    // SDRAM M12L64322A (CS# = GND, CKE = 3V3, DQM0-3 = GND on the module)
    output        sdram_clk,
    output        sdram_ras_n, sdram_cas_n, sdram_we_n,
    output  [1:0] sdram_ba,
    output [10:0] sdram_a,
    inout  [31:0] sdram_dq
);
    wire clk_x5, clk_sys, clk_pix, clk_sd, locked;

    (* FREQUENCY_PIN_CLKI = "25" *)
    (* FREQUENCY_PIN_CLKOP = "125" *)
    (* FREQUENCY_PIN_CLKOS = "50" *)
    (* FREQUENCY_PIN_CLKOS2 = "25" *)
    (* FREQUENCY_PIN_CLKOS3 = "50" *)
    (* ICP_CURRENT = "12" *) (* LPF_RESISTOR = "8" *) (* MFG_ENABLE_FILTEROPAMP = "1" *) (* MFG_GMCREF_SEL = "2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"), .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1), .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(5),
        .CLKOP_ENABLE("ENABLED"),  .CLKOP_DIV(4),   .CLKOP_CPHASE(2),   .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"),  .CLKOS_DIV(10),  .CLKOS_CPHASE(2),   .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("ENABLED"), .CLKOS2_DIV(20), .CLKOS2_CPHASE(2), .CLKOS2_FPHASE(0),
        .CLKOS3_ENABLE("ENABLED"), .CLKOS3_DIV(10), .CLKOS3_CPHASE(10), .CLKOS3_FPHASE(0)
    ) u_pll (
        .RST(1'b0), .STDBY(1'b0), .CLKI(clk25),
        .CLKOP(clk_x5), .CLKOS(clk_sys), .CLKOS2(clk_pix), .CLKOS3(clk_sd),
        .CLKFB(clk_x5), .CLKINTFB(),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0), .ENCLKOS(1'b0), .ENCLKOS2(1'b0), .ENCLKOS3(1'b0),
        .LOCK(locked), .INTLOCK(), .REFCLK());

    wire        sd_dq_oe;
    wire [31:0] sd_dq_out;
    wire        led_main;

    vdpx_ecp5_core #(.ST_ROM_FILE("selftest.hex")) u_core (
        .clk_x5(clk_x5), .clk_sys(clk_sys), .clk_pix(clk_pix), .clk_sd(clk_sd),
        .rst_btn(~locked), .selftest_btn(1'b0),          // no button: overlay on (M4.2 default)
        .md_fdc_n(md_fdc_n), .md_fdwr_n(md_fdwr_n), .md_cas0_n(md_cas0_n), .md_fres(md_fres),
        .md_a(md_a), .md_d(md_d),
        .sd_clk(sdram_clk), .sd_ras_n(sdram_ras_n), .sd_cas_n(sdram_cas_n), .sd_we_n(sdram_we_n),
        .sd_ba(sdram_ba), .sd_a(sdram_a), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sdram_dq),
        .i2s_bclk(i2s_bck), .i2s_lrck(i2s_ws), .i2s_dout(i2s_dout), .i2s_mclk(adc_mclk), .i2s_din(adc_dout),
        .tmds_q(gpdi_dp), .led_main(led_main), .leds(),
        .dbg_tmds0(), .dbg_tmds1(), .dbg_tmds2(), .dbg_aud_l(), .dbg_aud_r(), .dbg_aud_valid(),
        .dbg_aud_wr_applied(), .dbg_core_ack(), .dbg_core_we(), .dbg_core_addr(), .dbg_core_wdata(),
        .dbg_vblank(), .dbg_commit(), .dbg_late_read(), .dbg_overlay_on(), .dbg_commit_addr(),
        .dbg_md_d_oe());

    assign sdram_dq = sd_dq_oe ? sd_dq_out : 32'hZZZZ_ZZZZ;
    assign led_n    = ~led_main;
endmodule
