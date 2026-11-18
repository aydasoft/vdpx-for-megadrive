// HDMI transmitter for 640x480@60 (VIC 1) with 48 kHz stereo audio.
// Runs in the pixel clock domain (25.2 MHz). Input is the VDPX video stream
// (one pixel per clock); line/frame position is recovered from the syncs
// (HSYNC falls at x=656, VSYNC falls at y=490, x=0).
//
// Every line carries one data island in the horizontal blanking with 2 packets:
//   slot 0: Audio Sample Packet (up to 4 stereo samples from the FIFO) or Null
//   slot 1: AVI InfoFrame (y=480), Audio InfoFrame (y=481), Audio Clock
//           Regeneration (every 4th line, N=6144, CTS=25200) or Null.
// Island layout (x): preamble 644-651, guard 652-653, packets 654-717, guard 718-719.
// Video preamble 790-797 + guard 798-799 before every active line.
module hdmi_tx (
    input            clk,              // pixel clock
    input            rst,
    input      [7:0] r, g, b,
    input            hs_n, vs_n, de,
    input            aud_we,           // one stereo sample (pixel clock domain)
    input     [15:0] aud_l, aud_r,
    output     [9:0] tmds0, tmds1, tmds2,
    output reg       locked,           // position counters agree with the syncs
    output reg       aud_overflow
);
    // ------------------------------------------------------------ position recovery
    reg  [9:0] hc, vc;                // position of the current input pixel
    reg        hs_d = 1'b1, vs_d = 1'b1;
    wire       hs_fall = hs_d & ~hs_n;
    wire       vs_fall = vs_d & ~vs_n;
    wire [9:0] hc_now = hs_fall ? 10'd656 : hc;
    wire [9:0] vc_now = vs_fall ? 10'd490 : vc;

    always @(posedge clk) begin
        hs_d <= hs_n; vs_d <= vs_n;
        if (rst) begin
            hc <= 0; vc <= 0; locked <= 1'b0;
        end else begin
            if (hc_now == 10'd799) begin
                hc <= 0;
                vc <= (vc_now == 10'd524) ? 10'd0 : vc_now + 10'd1;
            end else begin
                hc <= hc_now + 10'd1;
                vc <= vc_now;
            end
            if (hs_fall) locked <= (hc == 10'd656);
        end
    end

    wire next_line_active = (vc_now == 10'd524) || (vc_now < 10'd479);
    wire video   = (hc_now < 10'd640) && (vc_now < 10'd480);
    wire v_pre   = (hc_now >= 10'd790) && (hc_now < 10'd798) && next_line_active;
    wire v_guard = (hc_now >= 10'd798) && next_line_active;
    wire d_pre   = (hc_now >= 10'd644) && (hc_now < 10'd652);
    wire d_guard = (hc_now == 10'd652) || (hc_now == 10'd653) || (hc_now == 10'd718) || (hc_now == 10'd719);
    wire d_data  = (hc_now >= 10'd654) && (hc_now < 10'd718);
    wire [4:0] pix  = hc_now[4:0] - 5'd14;          // 0..31 inside a packet (654 = 0 mod 32 + 14)
    wire       slot = (hc_now >= 10'd686);
    wire       load = (hc_now == 10'd653) || (hc_now == 10'd685);   // load next packet

    // ------------------------------------------------------------ audio FIFO (16 x 32 bits)
    reg [31:0] afifo [0:15];
    reg  [4:0] a_wr, a_rd;
    wire [4:0] a_cnt = a_wr - a_rd;
    always @(posedge clk) begin
        if (rst) begin
            a_wr <= 0; aud_overflow <= 1'b0;
        end else if (aud_we) begin
            if (a_cnt == 5'd16) aud_overflow <= 1'b1;
            else begin
                afifo[a_wr[3:0]] <= {aud_l, aud_r};
                a_wr <= a_wr + 5'd1;
            end
        end
    end

    // ------------------------------------------------------------ packet contents
    // IEC 60958 channel status (192 frames): bit 2 = copyright not asserted,
    // bits 20-23 channel number (L=1, R=2), bits 24-27 = 0010 (48 kHz).
    reg  [7:0] iec_frame;
    function cs_bit(input [7:0] f, input right);
        cs_bit = (f == 8'd2) || (f == 8'd25) || (!right && f == 8'd20) || (right && f == 8'd21);
    endfunction
    function [7:0] fr_add(input [7:0] f, input [2:0] k);
        fr_add = ({1'b0, f} + k >= 9'd192) ? f + k - 8'd192 : f + k;
    endfunction

    wire [2:0] n_take = (a_cnt >= 5'd4) ? 3'd4 : a_cnt[2:0];
    reg [23:0] p_hdr;
    reg [55:0] p_sp0, p_sp1, p_sp2, p_sp3;

    // audio sample subpacket for sample k
    function [55:0] asp(input [31:0] smp, input [7:0] fr);
        reg [23:0] l24, r24;
        reg cl, cr, pl, pr;
        begin
            l24 = {smp[31:16], 8'd0};
            r24 = {smp[15:0], 8'd0};
            cl = cs_bit(fr, 1'b0); cr = cs_bit(fr, 1'b1);
            pl = ^{l24, cl};       // even parity over sample, V=0, U=0, C
            pr = ^{r24, cr};
            asp = {pr, cr, 1'b0, 1'b0, pl, cl, 1'b0, 1'b0, r24, l24};
        end
    endfunction

    // InfoFrames: header {len, ver, type}; PB0 = checksum
    localparam [23:0] AVI_HDR = {8'd13, 8'd2, 8'h82};
    localparam [7:0]  AVI_PB1 = 8'h00, AVI_PB2 = 8'h18, AVI_PB3 = 8'h00, AVI_PB4 = 8'd1, AVI_PB5 = 8'h00;
    localparam [7:0]  AVI_SUM = 8'h82 + 8'd2 + 8'd13 + AVI_PB1 + AVI_PB2 + AVI_PB3 + AVI_PB4 + AVI_PB5;
    localparam [7:0]  AVI_CK  = 8'd0 - AVI_SUM;
    localparam [23:0] AIF_HDR = {8'd10, 8'd1, 8'h84};
    localparam [7:0]  AIF_PB1 = 8'h01;          // CT = stream, CC = 2 channels
    localparam [7:0]  AIF_CK  = 8'd0 - (8'h84 + 8'd1 + 8'd10 + AIF_PB1);
    localparam [19:0] ACR_N = 20'd6144, ACR_CTS = 20'd25200;
    localparam [55:0] ACR_SP = {ACR_N[7:0], ACR_N[15:8], 4'd0, ACR_N[19:16],
                                ACR_CTS[7:0], ACR_CTS[15:8], 4'd0, ACR_CTS[19:16], 8'd0};

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            a_rd <= 0; iec_frame <= 0;
        end else if (load && !slot && hc_now == 10'd653) begin
            // slot 0: audio samples
            if (n_take != 0) begin
                p_hdr <= {4'd0, 1'b0, 1'b0, 1'b0, 1'b0,                                 // HB2 (B flags set below)
                          3'd0, 1'b0, (n_take > 3), (n_take > 2), (n_take > 1), 1'b1,   // HB1: layout 0, present
                          8'h02};
                for (k = 0; k < 4; k = k + 1)
                    if (fr_add(iec_frame, k[2:0]) == 8'd0 && k < n_take) p_hdr[20 + k] <= 1'b1;
                p_sp0 <= asp(afifo[a_rd[3:0]], iec_frame);
                p_sp1 <= (n_take > 1) ? asp(afifo[a_rd[3:0] + 4'd1], fr_add(iec_frame, 3'd1)) : 56'd0;
                p_sp2 <= (n_take > 2) ? asp(afifo[a_rd[3:0] + 4'd2], fr_add(iec_frame, 3'd2)) : 56'd0;
                p_sp3 <= (n_take > 3) ? asp(afifo[a_rd[3:0] + 4'd3], fr_add(iec_frame, 3'd3)) : 56'd0;
                a_rd <= a_rd + {2'd0, n_take};
                iec_frame <= fr_add(iec_frame, n_take);
            end else begin
                p_hdr <= 24'd0; p_sp0 <= 0; p_sp1 <= 0; p_sp2 <= 0; p_sp3 <= 0;     // Null packet
            end
        end else if (load && hc_now == 10'd685) begin
            // slot 1: InfoFrames / clock regeneration
            if (vc_now == 10'd480) begin
                p_hdr <= AVI_HDR;
                p_sp0 <= {8'd0, AVI_PB5, AVI_PB4, AVI_PB3, AVI_PB2, AVI_PB1, AVI_CK};
                p_sp1 <= 0; p_sp2 <= 0; p_sp3 <= 0;
            end else if (vc_now == 10'd481) begin
                p_hdr <= AIF_HDR;
                p_sp0 <= {8'd0, 8'd0, 8'd0, 8'd0, 8'd0, AIF_PB1, AIF_CK};
                p_sp1 <= 0; p_sp2 <= 0; p_sp3 <= 0;
            end else if (vc_now[1:0] == 2'd0) begin
                p_hdr <= 24'h000001;
                p_sp0 <= ACR_SP; p_sp1 <= ACR_SP; p_sp2 <= ACR_SP; p_sp3 <= ACR_SP;
            end else begin
                p_hdr <= 24'd0; p_sp0 <= 0; p_sp1 <= 0; p_sp2 <= 0; p_sp3 <= 0;
            end
        end
    end

    // ------------------------------------------------------------ packet serializer + BCH ECC
    function [7:0] ecc1(input [7:0] e, input bt);
        ecc1 = (e >> 1) ^ ((e[0] ^ bt) ? 8'b10000011 : 8'd0);
    endfunction
    reg [7:0] eh, e0, e1, e2, e3;
    wire [5:0] b0i = {pix, 1'b0};
    wire [5:0] b1i = {pix, 1'b1};
    wire [2:0] eb0 = {pix[1:0], 1'b0};
    wire [2:0] eb1 = {pix[1:0], 1'b1};
    wire hb = (pix < 5'd24) ? p_hdr[pix] : eh[pix - 5'd24];
    wire s0a = (pix < 5'd28) ? p_sp0[b0i] : e0[eb0], s0b = (pix < 5'd28) ? p_sp0[b1i] : e0[eb1];
    wire s1a = (pix < 5'd28) ? p_sp1[b0i] : e1[eb0], s1b = (pix < 5'd28) ? p_sp1[b1i] : e1[eb1];
    wire s2a = (pix < 5'd28) ? p_sp2[b0i] : e2[eb0], s2b = (pix < 5'd28) ? p_sp2[b1i] : e2[eb1];
    wire s3a = (pix < 5'd28) ? p_sp3[b0i] : e3[eb0], s3b = (pix < 5'd28) ? p_sp3[b1i] : e3[eb1];

    always @(posedge clk) begin
        if (!d_data || pix == 5'd31) begin
            eh <= 0; e0 <= 0; e1 <= 0; e2 <= 0; e3 <= 0;
        end else begin
            if (pix < 5'd24) eh <= ecc1(eh, hb);
            if (pix < 5'd28) begin
                e0 <= ecc1(ecc1(e0, s0a), s0b);
                e1 <= ecc1(ecc1(e1, s1a), s1b);
                e2 <= ecc1(ecc1(e2, s2a), s2b);
                e3 <= ecc1(ecc1(e3, s3a), s3b);
            end
        end
    end

    // ------------------------------------------------------------ channel symbols
    reg [2:0] mode;
    reg [7:0] d0, d1, d2;
    reg [1:0] c0, c1, c2;
    reg [3:0] t0, t1, t2;
    always @(*) begin
        d0 = b; d1 = g; d2 = r;
        c0 = {vs_n, hs_n};
        c1 = {1'b0, v_pre | d_pre};       // CTL1, CTL0
        c2 = {1'b0, d_pre};               // CTL3, CTL2
        t0 = {1'b1, hb, vs_n, hs_n};
        t1 = {s3a, s2a, s1a, s0a};
        t2 = {s3b, s2b, s1b, s0b};
        if (video)        mode = 3'd1;
        else if (v_guard) mode = 3'd2;
        else if (d_data)  mode = 3'd3;
        else if (d_guard) begin mode = 3'd4; t0 = {2'b11, vs_n, hs_n}; end
        else              mode = 3'd0;
    end

    tmds_enc #(.CH(0)) u_e0 (.clk(clk), .mode(mode), .d(d0), .c(c0), .t(t0), .q(tmds0));
    tmds_enc #(.CH(1)) u_e1 (.clk(clk), .mode(mode), .d(d1), .c(c1), .t(t1), .q(tmds1));
    tmds_enc #(.CH(2)) u_e2 (.clk(clk), .mode(mode), .d(d2), .c(c2), .t(t2), .q(tmds2));
endmodule
