// ECP5-P1 variant of sim/vdpx_sim.v (same module name and ports, so sim/tb_main.cpp runs
// unchanged): the sample memory is the real SDRAM path of the Colorlight i9 build -
// sdram_ctrl with RMW = 1 (no DQM) + sdram_model with HONOR_DQM = 0 (DQM tied to GND),
// SDRAM clock = inverted system clock. Every scene therefore exercises the APU/CPU
// arbitration of vdpx_apu.v on top of read-modify-write, refresh and close-page timing.
// Built with -DVDPX_CLK50 (50 MHz plan: 48 kHz frame = 3125/3 clocks).
module vdpx_sim (
    input             clk,
    input             rst,
    input             bus_cs,
    input             bus_we,
    input       [2:0] bus_addr,
    input      [15:0] bus_wdata,
    output     [15:0] bus_rdata,
    output            bus_ack,
    output      [7:0] vid_r, vid_g, vid_b,
    output            vid_hs_n, vid_vs_n, vid_de, vid_ce,
    output            vblank,
    output            i2s_bclk, i2s_lrck, i2s_dout,
    input             i2s_din,
    output     [15:0] aud_l, aud_r,
    output            aud_valid, aud_tick,
    output     [15:0] aud_wr_applied
);
    localparam AW = 20;
`ifdef VDPX_CLK50
    localparam I2S_NUM = 3, I2S_DEN = 3125;
`else
    localparam I2S_NUM = 1, I2S_DEN = 1050;
`endif
    wire          sm_req, sm_we, sm_ack;
    wire [AW-1:0] sm_addr;
    wire   [15:0] sm_wdata, sm_rdata;

    vdpx_top #(.SMEM_AW(AW), .I2S_NUM(I2S_NUM), .I2S_DEN(I2S_DEN)) u_vdpx (
        .clk(clk), .rst(rst),
        .bus_cs(bus_cs), .bus_we(bus_we), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack),
        .peek_addr(3'd0), .peek_data(), .peek_valid(), .rd_commit(1'b0), .rd_commit_addr(3'd0),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_hs_n(vid_hs_n), .vid_vs_n(vid_vs_n), .vid_de(vid_de), .vid_ce(vid_ce),
        .vblank(vblank),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .i2s_din(i2s_din),
        .aud_l(aud_l), .aud_r(aud_r), .aud_valid(aud_valid), .aud_tick(aud_tick),
        .aud_wr_applied(aud_wr_applied),
        .sm_req(sm_req), .sm_we(sm_we), .sm_addr(sm_addr), .sm_wdata(sm_wdata),
        .sm_ack(sm_ack), .sm_rdata(sm_rdata));

    // ---- SDRAM path of the i9 (the tb_main reset lasts a few cycles: short power-up wait)
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe, sd_ready;
    wire  [1:0] sd_ba;
    wire [10:0] sd_a;
    wire  [3:0] sd_dqm;
    wire [31:0] sd_dq_out, sd_dq_from_mem;
    wire [31:0] sd_errors;
    sdram_ctrl #(.INIT_CYCLES(200), .RMW(1)) u_sdram (
        .clk(clk), .rst(rst),
        .req(sm_req), .we(sm_we), .addr({2'b00, sm_addr}), .wdata(sm_wdata),
        .ack(sm_ack), .rdata(sm_rdata), .ready(sd_ready),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm),
        .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_from_mem));
    sdram_model #(.INIT_MIN(100), .HONOR_DQM(0)) u_mem (
        .sd_clk(~clk), .cke(1'b1), .cs_n(1'b0), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq_in(sd_dq_oe ? sd_dq_out : 32'hZZZZ_ZZZZ),
        .dq_out(sd_dq_from_mem), .ctrl_oe(sd_dq_oe), .ref_relaxed(1'b0), .errors(sd_errors), .dq_drv());

    reg [31:0] r_cnt = 0, r_max = 0, r_lines = 0;
    always @(posedge clk) begin
        if (u_vdpx.rbusy) r_cnt <= r_cnt + 1;
        else if (r_cnt != 0) begin
            if (r_cnt > r_max) r_max <= r_cnt;
            r_lines <= r_lines + 1;
            r_cnt <= 0;
        end
    end
    final begin
        $display("RENDER_BUDGET: %0d linhas, maior tempo de renderizacao %0d ciclos de 3200", r_lines, r_max);
        $display("SDRAM_RMW: %0d escritas de 32 bits no modelo, %0d erros de protocolo/timing", u_mem.n_wr, sd_errors);
        if (sd_errors != 0) $fatal(1, "SDRAM com erros");
    end
endmodule
