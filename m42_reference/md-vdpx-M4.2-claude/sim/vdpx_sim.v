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
    output     [15:0] aud_wr_applied
);
    localparam AW = 20;
    wire          sm_req, sm_we, sm_ack;
    wire [AW-1:0] sm_addr;
    wire   [15:0] sm_wdata, sm_rdata;

    vdpx_top #(.SMEM_AW(AW)) u_vdpx (
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

    vdpx_sim_smem #(.AW(AW)) u_smem (
        .clk(clk), .req(sm_req), .we(sm_we), .addr(sm_addr), .wdata(sm_wdata),
        .ack(sm_ack), .rdata(sm_rdata));
endmodule
