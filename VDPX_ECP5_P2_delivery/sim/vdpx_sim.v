// Simulation wrapper for tb_main: VDPX core + behavioral sample memory.
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
    output     [15:0] aud_wr_applied,
    // P2 verification taps
    output            dbg_vw_we, dbg_vw_dma,
    output     [14:0] dbg_vw_addr,
    output     [15:0] dbg_vw_data,
    output     [99:0] dma_status,
    output     [28:0] dma_events,
    output            dbg_rbusy          // P2: renderer busy (tb counts DMA writes during rendering)
);
    assign dbg_rbusy = u_vdpx.rbusy;
    localparam AW = 20;
    wire          sm_req, sm_we, sm_ack;
    wire [AW-1:0] sm_addr;
    wire   [15:0] sm_wdata, sm_rdata, sm_rdata_hi;
    wire          sm_pair;

`ifdef VDPX_CLK50
    // ECP5-P1 clock plan: 50.0 MHz system clock, 48 kHz frame = 3125/3 clocks
    localparam I2S_NUM = 3, I2S_DEN = 3125;
`else
    localparam I2S_NUM = 1, I2S_DEN = 1050;
`endif
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
        .sm_pair(sm_pair), .sm_ack(sm_ack), .sm_rdata(sm_rdata), .sm_rdata_hi(sm_rdata_hi),
        .dbg_vw_we(dbg_vw_we), .dbg_vw_dma(dbg_vw_dma), .dbg_vw_addr(dbg_vw_addr), .dbg_vw_data(dbg_vw_data),
        .dma_status(dma_status), .dma_events(dma_events));

    vdpx_sim_smem #(.AW(AW)) u_smem (
        .clk(clk), .req(sm_req), .we(sm_we), .addr(sm_addr), .wdata(sm_wdata),
        .ack(sm_ack), .rdata(sm_rdata), .rdata_hi(sm_rdata_hi));

    // ECP5-P1: line render budget monitor (busy cycles per line, limit 3200 = 2 HDMI lines).
    // Printed at the end of the run; RENDER_OVERFLOW (STATUS bit 2) stays the pass/fail check.

    // P2: APU deadline: cycles from the 48 kHz tick to the mixed sample (must stay < one frame)
    reg [31:0] a_cnt = 0, a_max = 0; reg a_on = 0;
    always @(posedge clk) begin
        if (aud_tick) begin a_on <= 1; a_cnt <= 0; end
        else if (a_on) a_cnt <= a_cnt + 1;
        if (aud_valid && a_on) begin a_on <= 0; if (a_cnt + 1 > a_max) a_max <= a_cnt + 1; end
    end
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
        $display("APU_DEADLINE: maior tempo tick->amostra %0d ciclos (quadro de %0d)", a_max, I2S_DEN / I2S_NUM);
    end
endmodule
