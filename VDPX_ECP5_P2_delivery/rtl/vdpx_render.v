// MD-VDPX line renderer (M1.5).
//
// Order per line (budget 3200 system clocks = 1600 pixel clocks x2):
//   1. plane A pass  (41 tiles x 14 cycles)  -> lbA, and clears lbS at the same x
//   2. plane B pass  (41 tiles x 14 cycles)  -> lbB
//   3. sprite scan   (128 sprites x 3 cycles) -> list of up to 32 sprites / 64 tile columns
//   4. sprite draw   (back to front, 3 + 12 cycles per tile column) -> lbS (opaque pixels only)
// Worst case ~ 1152 + 384 + 864 = ~2400 cycles (ECP5-P1: +1 cycle per plane tile, state
// T_AD, and +1 per sprite tile column, state D_AD, for registered VRAM addresses).
//
// Line buffer entry: {pri, pal[3:0], nibble[3:0]} (9 bits).
module vdpx_render (
    input             clk,
    input             rst,
    input             start,        // pulse: render line 'line' into set 'set'
    input       [7:0] line,         // internal line 0..223
    input             set,
    output reg        busy,
    output reg        spr_ovf,      // pulse: sprite limit hit on this line

    input      [15:0] r_abase, r_bbase, r_psize,
    input      [15:0] r_ax, r_ay, r_bx, r_by, r_tbase,
    input      [15:0] r_smode,      // [0] A hscroll/line [1] B hscroll/line [2] A vscroll/col [3] B vscroll/col
    input      [15:0] r_hsbase,

    output reg [14:0] vaddr,        // VRAM word address (combinational)
    output            vreq,
    input      [15:0] vdata,        // 1-cycle latency

    output reg  [8:0] sat_addr,     // SAT word address (combinational)
    output            sreq,
    input      [15:0] sat_data,     // 1-cycle latency

    output      [5:0] vs_addr,      // VSRAM word address (asynchronous read)
    input      [15:0] vs_data,

    output reg        lbA_we,
    output reg        lbB_we,
    output reg        lbS_we,
    output reg  [9:0] lb_addr,      // {set, x}  (A/B and S-clear)
    output reg  [8:0] lb_data,
    output reg  [9:0] lbs_addr,     // sprite buffer address
    output reg  [8:0] lbs_data
);
    localparam [4:0]
        S_IDLE = 5'd0,  P_SET = 5'd1,  P_HS0 = 5'd2,  P_HS1 = 5'd3,
        T_E0   = 5'd4,  T_E1  = 5'd5,  T_E2  = 5'd6,  T_P0  = 5'd7,
        T_P1   = 5'd8,  T_PIX = 5'd9,
        SC_A   = 5'd10, SC_B  = 5'd11, SC_C  = 5'd12,
        D_INIT = 5'd13, D_A   = 5'd14, D_B   = 5'd15, D_C   = 5'd16,
        D_E0   = 5'd17, D_E1  = 5'd18, D_E2  = 5'd19, D_PIX = 5'd20,
        D_AD   = 5'd21,             // ECP5-P1: registered sprite pattern address
        T_AD   = 5'd22;             // ECP5-P1: registered nametable entry address

    reg  [4:0] st;
    reg  [7:0] cur_line;
    reg        cur_set;

    // ------------------------------------------------------------ planes
    reg        plane;               // 0 = A, 1 = B
    reg  [5:0] ti;
    reg  [2:0] k;
    reg [15:0] e0, e1, p0, p1;
    reg  [1:0] wsel, hsel;
    reg [15:0] base;
    reg [15:0] sx_r;
    reg  [2:0] fy_t;

    wire [15:0] sel_sx   = plane ? r_bx : r_ax;
    wire  [1:0] sel_w    = plane ? r_psize[5:4] : r_psize[1:0];
    wire  [1:0] sel_h    = plane ? r_psize[7:6] : r_psize[3:2];
    wire [15:0] sel_base = plane ? r_bbase : r_abase;
    wire        hs_line  = plane ? r_smode[1] : r_smode[0];
    wire        vs_col   = plane ? r_smode[3] : r_smode[2];

    assign vs_addr = {ti[5:1], plane};
    wire [15:0] sy_t     = vs_col ? vs_data : (plane ? r_by : r_ay);
    wire  [9:0] hmask_px = (hsel == 2'd0) ? 10'd255 : (hsel == 2'd1) ? 10'd511 : 10'd1023;
    wire  [9:0] py       = ({2'b00, cur_line} + sy_t[9:0]) & hmask_px;
    wire  [6:0] row      = py[9:3];

    wire [12:0] c0    = sx_r[15:3];
    wire  [2:0] fine  = sx_r[2:0];
    wire  [6:0] wmask = (wsel == 2'd0) ? 7'd31 : (wsel == 2'd1) ? 7'd63 : 7'd127;
    wire  [6:0] col   = (c0[6:0] + {1'b0, ti}) & wmask;
    wire [15:0] row_off = (wsel == 2'd0) ? {4'd0, row, 5'd0}
                        : (wsel == 2'd1) ? {3'd0, row, 6'd0}
                        :                  {2'd0, row, 7'd0};
    wire [15:0] ent_addr = base + ((row_off + {9'd0, col}) << 1);
    // ECP5-P1: VSRAM -> row -> entry address is computed in T_AD and registered;
    // T_E0/T_E1 address the VRAM from ent_r.
    reg  [14:0] ent_r;
    wire [15:0] hs_addr  = r_hsbase + {7'd0, cur_line, 1'b0} + {15'd0, plane};

    wire  [2:0] fyy      = e0[15] ? ~fy_t : fy_t;
    wire [15:0] pat_addr = r_tbase + {e0[11:0], 4'd0} + {12'd0, fyy, 1'b0};

    reg  [6:0] s;                   // scan index
    reg  [5:0] cnt;                 // sprites in list (0..32)
    reg  [6:0] cols;                // tile columns in list (0..64)
    reg [15:0] w0r, w1r, w2r;
    reg  [4:0] j;                   // draw index
    reg  [2:0] c;                   // tile column within sprite

    // ------------------------------------------------------------ pixel extraction (shared)
    reg         pix_hf;
    always @(*) pix_hf = (st == D_PIX) ? w2r[14] : e0[14];
    wire  [2:0] n  = pix_hf ? ~k : k;
    wire [15:0] pw = n[2] ? p1 : p0;
    reg   [3:0] nib;
    always @(*) begin
        case (n[1:0])
            2'd0: nib = pw[15:12];
            2'd1: nib = pw[11:8];
            2'd2: nib = pw[7:4];
            default: nib = pw[3:0];
        endcase
    end
    wire signed [10:0] xs = $signed({2'b00, ti, 3'b000}) + $signed({8'd0, k}) - $signed({8'd0, fine});
    wire xs_ok = (xs >= 0) && (xs < 320);

    // ------------------------------------------------------------ sprites

    reg  [6:0] ls_s  [0:31];
    reg  [5:0] ls_dy [0:31];
    reg  [2:0] ls_w  [0:31];        // width-1
    reg  [2:0] ls_h  [0:31];        // height-1

    // scan decision (state SC_C: w0r latched, sat_data = word 3)
    wire  [9:0] sdy     = {2'b00, cur_line} - w0r[9:0];
    wire  [2:0] s_h1    = w0r[12:10];
    wire  [2:0] s_w1    = w0r[15:13];
    wire  [6:0] s_hpx   = {1'b0, s_h1, 3'b000} + 7'd8;
    wire        s_vis   = sat_data[0] && (sdy < {3'b000, s_hpx});
    wire  [7:0] cols_n  = {1'b0, cols} + {5'd0, s_w1} + 8'd1;
    wire        s_room  = (cnt < 6'd32) && (cols_n <= 8'd64);

    // draw (j selects the list entry)
    wire  [6:0] d_s   = ls_s[j];
    wire  [5:0] d_dy  = ls_dy[j];
    wire  [2:0] d_w1  = ls_w[j];
    wire  [2:0] d_h1  = ls_h[j];
    wire        d_hf  = w2r[14];
    wire        d_vf  = w2r[15];
    wire  [2:0] d_cc  = d_hf ? (d_w1 - c) : c;
    wire  [5:0] d_dyf = d_vf ? ({d_h1, 3'b111} - d_dy) : d_dy;
    wire  [3:0] d_hh   = {1'b0, d_h1} + 4'd1;
    // ECP5-P1: 3x4-bit product as shift-and-add (keeps it out of a DSP block)
    wire  [6:0] d_ccxh = (d_cc[0] ? {3'd0, d_hh}       : 7'd0)
                       + (d_cc[1] ? {2'd0, d_hh, 1'b0} : 7'd0)
                       + (d_cc[2] ? {1'd0, d_hh, 2'b0} : 7'd0);
    wire [13:0] d_tile = w2r[13:0] + {7'd0, d_ccxh} + {11'd0, d_dyf[5:3]};
    wire [15:0] spat_addr = r_tbase + {d_tile[11:0], 4'd0} + {12'd0, d_dyf[2:0], 1'b0};
    // ECP5-P1: spat_addr is computed in D_AD and registered, so the VRAM address
    // in D_E0/D_E1 comes straight from a flip-flop (one extra cycle per tile column).
    reg  [14:0] spat_r;
    wire signed [11:0] d_x = $signed({{2{w1r[9]}}, w1r[9:0]}) + $signed({6'd0, c, 3'b000}) + $signed({9'd0, k});
    wire d_x_ok = (d_x >= 0) && (d_x < 320);

    // ------------------------------------------------------------ memory request muxes
    assign vreq = (st == T_E0) || (st == T_E1) || (st == T_E2) || (st == T_P0) ||
                  (st == P_HS0) || (st == D_E0) || (st == D_E1);
    assign sreq = (st == SC_A) || (st == SC_B) || (st == D_A) || (st == D_B);

    always @(*) begin
        case (st)
            P_HS0:   vaddr = hs_addr[14:0];
            T_E0:    vaddr = ent_r;
            T_E1:    vaddr = ent_r + 15'd1;
            T_E2:    vaddr = pat_addr[14:0];
            T_P0:    vaddr = pat_addr[14:0] + 15'd1;
            D_E0:    vaddr = spat_r;
            D_E1:    vaddr = spat_r + 15'd1;
            default: vaddr = 15'd0;
        endcase
        case (st)
            SC_A:    sat_addr = {s, 2'd0};
            SC_B:    sat_addr = {s, 2'd3};
            D_A:     sat_addr = {d_s, 2'd1};
            D_B:     sat_addr = {d_s, 2'd2};
            default: sat_addr = 9'd0;
        endcase
    end

    // ------------------------------------------------------------ FSM
    always @(posedge clk) begin
        lbA_we <= 1'b0; lbB_we <= 1'b0; lbS_we <= 1'b0; spr_ovf <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0;
        end else begin
            case (st)
            S_IDLE: if (start) begin
                cur_line <= line; cur_set <= set;
                plane <= 1'b0; busy <= 1'b1; st <= P_SET;
            end
            // ---------------- planes
            P_SET: begin
                wsel <= (sel_w == 2'd3) ? 2'd2 : sel_w;
                hsel <= (sel_h == 2'd3) ? 2'd2 : sel_h;
                base <= sel_base;
                sx_r <= sel_sx;
                ti   <= 6'd0;
                st   <= hs_line ? P_HS0 : T_AD;
            end
            P_HS0: st <= P_HS1;
            P_HS1: begin sx_r <= vdata; st <= T_AD; end
            T_AD: begin ent_r <= ent_addr[14:0]; fy_t <= py[2:0]; st <= T_E0; end
            T_E0: st <= T_E1;
            T_E1: begin e0 <= vdata; st <= T_E2; end
            T_E2: begin e1 <= vdata; st <= T_P0; end
            T_P0: begin p0 <= vdata; st <= T_P1; end
            T_P1: begin p1 <= vdata; k <= 3'd0; st <= T_PIX; end
            T_PIX: begin
                if (xs_ok) begin
                    lb_addr <= {cur_set, xs[8:0]};
                    lb_data <= {e1[4], e1[3:0], nib};
                    if (plane == 1'b0) begin
                        lbA_we   <= 1'b1;
                        lbS_we   <= 1'b1;               // clear sprite buffer
                        lbs_addr <= {cur_set, xs[8:0]};
                        lbs_data <= 9'd0;
                    end else begin
                        lbB_we <= 1'b1;
                    end
                end
                k <= k + 3'd1;
                if (k == 3'd7) begin
                    if (ti == 6'd40) begin
                        if (plane == 1'b0) begin
                            plane <= 1'b1; st <= P_SET;
                        end else begin
                            s <= 7'd0; cnt <= 6'd0; cols <= 7'd0; st <= SC_A;
                        end
                    end else begin
                        ti <= ti + 6'd1; st <= T_AD;
                    end
                end
            end
            // ---------------- sprite scan
            SC_A: st <= SC_B;
            SC_B: begin w0r <= sat_data; st <= SC_C; end
            SC_C: begin
                if (s_vis && !s_room) begin
                    spr_ovf <= 1'b1;
                    st <= D_INIT;
                end else begin
                    if (s_vis) begin
                        ls_s[cnt[4:0]]  <= s;
                        ls_dy[cnt[4:0]] <= sdy[5:0];
                        ls_w[cnt[4:0]]  <= s_w1;
                        ls_h[cnt[4:0]]  <= s_h1;
                        cnt  <= cnt + 6'd1;
                        cols <= cols_n[6:0];
                    end
                    s <= s + 7'd1;
                    st <= (s == 7'd127) ? D_INIT : SC_A;
                end
            end
            // ---------------- sprite draw (back to front)
            D_INIT: begin
                if (cnt == 6'd0) begin
                    busy <= 1'b0; st <= S_IDLE;
                end else begin
                    j <= cnt[4:0] - 5'd1; st <= D_A;
                end
            end
            D_A: st <= D_B;
            D_B: begin w1r <= sat_data; st <= D_C; end
            D_C: begin w2r <= sat_data; c <= 3'd0; st <= D_AD; end
            D_AD: begin spat_r <= spat_addr[14:0]; st <= D_E0; end
            D_E0: st <= D_E1;
            D_E1: begin p0 <= vdata; st <= D_E2; end
            D_E2: begin p1 <= vdata; k <= 3'd0; st <= D_PIX; end
            D_PIX: begin
                if (d_x_ok && nib != 4'd0) begin
                    lbS_we   <= 1'b1;
                    lbs_addr <= {cur_set, d_x[8:0]};
                    lbs_data <= {w1r[15], w1r[14:11], nib};
                end
                k <= k + 3'd1;
                if (k == 3'd7) begin
                    if (c == d_w1) begin
                        if (j == 5'd0) begin
                            busy <= 1'b0; st <= S_IDLE;
                        end else begin
                            j <= j - 5'd1; st <= D_A;
                        end
                    end else begin
                        c <= c + 3'd1; st <= D_AD;
                    end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
