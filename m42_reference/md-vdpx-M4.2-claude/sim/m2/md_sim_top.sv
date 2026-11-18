// M2 co-simulation: a minimal "Mega Drive" (fx68k 68000 + ROM + 64 KB RAM)
// with MD-VDPX attached through md_fdc_adapter, as on the expansion port (CN2).
// Hypothetical console model (not validated against VA6): it decodes $A12000-$A120FF
// into /FDC, /FDWR and /CAS0 and generates /DTACK itself, with no wait states.
//
// Memory map (simulation; the real VDPX window is still to be defined):
//   $000000-$3FFFFF  ROM (64 KB, mirrored)       -- the cartridge
//   $A12000-$A120FF  VDPX registers (expansion port /FDC window)
//   $600000          debug port (simulation only, write)
//   $FF0000-$FFFFFF  RAM 64 KB
module md_sim_top (
    input             clk,          // 50.4 MHz system clock (VDPX)
    input             rst,

    // video
    output      [7:0] vid_r, vid_g, vid_b,
    output            vid_hs_n, vid_vs_n, vid_de, vid_ce,
    output            vblank,

    // snoop of the VDPX internal bus (for the reference model)
    output            snp_ack,
    output            snp_we,
    output      [2:0] snp_addr,
    output     [15:0] snp_wdata,
    output     [15:0] snp_rdata,
    output            snp_late,       // adapter could not answer a read in time
    output            snp_commit,     // a read was completed
    output            wo_overflow,    // M2WO: write FIFO overflow (sticky)
    output            wo_drop,        // M2WO: one write rejected
    output      [4:0] wo_level,       // M2WO: write FIFO occupancy

    // debug port
    output reg        dbg_we,
    output reg [15:0] dbg_data,

    // 68000 activity (for statistics)
    output            cpu_as_n,
    output     [23:1] cpu_addr,
    output            cpu_rw,
    // audio
    output            i2s_bclk, i2s_lrck, i2s_dout,
    input             i2s_din,
    output     [15:0] aud_l, aud_r,
    output            aud_valid,
    output     [15:0] aud_wr_applied,
    output     [15:0] cpu_wdata,
    output     [15:0] cpu_rdata
);
    // ------------------------------------------------------------ 68000 clock enables (~7.67 MHz)
    // Fractional divider: 2 phases per 68000 clock -> 15.34 M phases/s out of 50.4 M cycles/s.
    reg [15:0] acc;
    reg        ph;
    reg        phi1, phi2;
    always @(posedge clk) begin
        phi1 <= 1'b0; phi2 <= 1'b0;
        if (rst) begin
            acc <= 0; ph <= 0;
        end else if (acc + 16'd1534 >= 16'd5040) begin
            acc <= acc + 16'd1534 - 16'd5040;
            ph  <= ~ph;
            if (ph) phi2 <= 1'b1; else phi1 <= 1'b1;
        end else begin
            acc <= acc + 16'd1534;
        end
    end

    // ------------------------------------------------------------ 68000
    wire        rw_n, as_n, lds_n, uds_n;
    wire [23:1] eab;
    wire [15:0] cpu_dout;
    reg  [15:0] cpu_din;
    wire        dtack_n;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(phi1), .enPhi2(phi2),
        .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
        .E(), .VMAn(),
        .FC0(), .FC1(), .FC2(),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(dtack_n), .VPAn(1'b1), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
        .iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab));

    assign cpu_as_n  = as_n;
    assign cpu_addr  = eab;
    assign cpu_rw    = rw_n;
    assign cpu_wdata = cpu_dout;

    // ------------------------------------------------------------ address decode
    wire sel_rom  = (eab[23:22] == 2'b00);
    wire sel_vdpx = (eab[23:8] == 16'hA120);            // decoded by the console (/FDC)
    wire sel_dbg  = (eab[23:16] == 8'h60);
    wire sel_ram  = (eab[23:16] == 8'hFF);

    // ------------------------------------------------------------ ROM / RAM
    reg [15:0] rom [0:32767];
    reg [15:0] ram [0:32767];
    initial $readmemh("rom.hex", rom);
    integer i;
    initial for (i = 0; i < 32768; i = i + 1) ram[i] = 16'd0;

    // RAM write: once per bus cycle, when the data strobes are asserted
    reg ram_written, dbg_written;
    always @(posedge clk) begin
        dbg_we <= 1'b0;
        if (as_n) begin
            ram_written <= 1'b0;
            dbg_written <= 1'b0;
        end else if (!rw_n && !(uds_n && lds_n)) begin
            if (sel_ram && !ram_written) begin
                if (!uds_n) ram[eab[15:1]][15:8] <= cpu_dout[15:8];
                if (!lds_n) ram[eab[15:1]][7:0]  <= cpu_dout[7:0];
                ram_written <= 1'b1;
            end
            if (sel_dbg && !dbg_written) begin
                dbg_we <= 1'b1;
                dbg_data <= cpu_dout;
                dbg_written <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ VDPX + adapter
    wire        core_cs, core_we, core_ack;
    wire  [2:0] core_addr;
    wire [15:0] core_wdata, core_rdata;
    wire [15:0] ad_dout, peek_data;
    wire        ad_doe, peek_valid, rd_commit, late_read, md_act;
    wire  [2:0] peek_addr, rd_commit_addr;

    // HYPOTHETICAL simulation strobes, not a measured CN2 model
    wire fdc_n  = ~(!as_n && sel_vdpx);
    wire fdwr_n = ~(!fdc_n && !rw_n && !(uds_n && lds_n));
    wire cas0_n = ~(!as_n && rw_n && sel_vdpx && !(uds_n && lds_n));

`ifdef M2WO
    // M4.2: the synthesizable write-only adapter (the one that goes into the Tang)
    md_fdc_adapter u_adp (
        .clk(clk), .rst(rst),
        .fdc_n(fdc_n), .fdwr_n(fdwr_n), .cas0_n(cas0_n), .a(eab[3:1]),
        .d_in(cpu_dout), .d_out(ad_dout), .d_oe(ad_doe),
        .core_cs(core_cs), .core_we(core_we), .core_addr(core_addr), .core_wdata(core_wdata),
        .core_ack(core_ack),
        .peek_addr(peek_addr), .peek_data(peek_data), .peek_valid(peek_valid),
        .rd_commit(rd_commit), .rd_commit_addr(rd_commit_addr),
        .late_read(late_read), .activity(md_act), .overflow(wo_overflow), .drop(wo_drop),
        .fifo_level(wo_level));
`else
    legacy_read_adapter u_adp (
        .clk(clk), .rst(rst),
        .fdc_n(fdc_n), .fdwr_n(fdwr_n), .cas0_n(cas0_n), .a(eab[3:1]),
        .d_in(cpu_dout), .d_out(ad_dout), .d_oe(ad_doe),
        .core_cs(core_cs), .core_we(core_we), .core_addr(core_addr), .core_wdata(core_wdata),
        .core_ack(core_ack),
        .peek_addr(peek_addr), .peek_data(peek_data), .peek_valid(peek_valid),
        .rd_commit(rd_commit), .rd_commit_addr(rd_commit_addr),
        .late_read(late_read), .activity(md_act));
    assign wo_overflow = 1'b0; assign wo_drop = 1'b0; assign wo_level = 5'd0;
`endif
    assign snp_late = late_read;
    assign snp_commit = rd_commit;

`ifndef M2_PREFETCH
`define M2_PREFETCH 1
`endif
    vdpx_top #(.SMEM_AW(20), .PREFETCH(`M2_PREFETCH)) u_vdpx (
        .clk(clk), .rst(rst),
        .bus_cs(core_cs), .bus_we(core_we), .bus_addr(core_addr), .bus_wdata(core_wdata),
        .bus_rdata(core_rdata), .bus_ack(core_ack),
        .peek_addr(peek_addr), .peek_data(peek_data), .peek_valid(peek_valid),
        .rd_commit(rd_commit), .rd_commit_addr(rd_commit_addr),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_hs_n(vid_hs_n), .vid_vs_n(vid_vs_n), .vid_de(vid_de), .vid_ce(vid_ce),
        .vblank(vblank),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_dout(i2s_dout), .i2s_din(i2s_din),
        .aud_l(aud_l), .aud_r(aud_r), .aud_valid(aud_valid), .aud_tick(),
        .aud_wr_applied(aud_wr_applied),
        .sm_req(sm_req), .sm_we(sm_we), .sm_addr(sm_addr), .sm_wdata(sm_wdata),
        .sm_ack(sm_ack), .sm_rdata(sm_rdata));

    // sample memory (SDRAM on the Tang)
    wire        sm_req, sm_we, sm_ack;
    wire [19:0] sm_addr;
    wire [15:0] sm_wdata, sm_rdata;
    vdpx_sim_smem #(.AW(20)) u_smem (
        .clk(clk), .req(sm_req), .we(sm_we), .addr(sm_addr), .wdata(sm_wdata),
        .ack(sm_ack), .rdata(sm_rdata));

    assign snp_ack   = core_ack;
    assign snp_we    = core_we;
    assign snp_addr  = core_addr;
    assign snp_wdata = core_wdata;
    assign snp_rdata = core_rdata;

    // ------------------------------------------------------------ 68000 data in / DTACK
    always @(*) begin
        if (sel_vdpx)     cpu_din = ad_doe ? ad_dout : 16'hFFFF;
        else if (sel_ram) cpu_din = ram[eab[15:1]];
        else if (sel_rom) cpu_din = rom[eab[15:1]];
        else              cpu_din = 16'hFFFF;
    end
    assign cpu_rdata = cpu_din;
    // Simulation assumption: zero wait states. Physical timing remains BLOCKED.
    assign dtack_n = as_n ? 1'b1 : 1'b0;           // the console never waits for the expansion port
endmodule
