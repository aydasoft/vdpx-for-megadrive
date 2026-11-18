// CN2 probe (M4.2): the Tang only *listens* to the expansion port, so it can be
// its own logic analyzer. Every /FDC cycle is timed in system clocks
// (1 tick = 19.84 ns) and classified as "write" (/FDWR seen) or "no /FDWR"
// (a 68000 read of $A12000, or a cycle whose /FDWR never arrived). For each
// class it keeps counters and min/max of the timings, plus whether /CAS0 was
// seen. All inputs go through the same 2-FF synchronizers as the adapter, so
// relative timings are exact to +-1 tick. Statistics clear only on reset.
module cn2_probe (
    input             clk,
    input             rst,
    input             fdc_n,
    input             fdwr_n,
    input             cas0_n,
    input             fres,
    input       [3:1] a,
    input      [15:0] d,
    input             acc_pulse,        // adapter accepted a word
    input             drop_pulse,       // adapter rejected a word (FIFO full)
    input       [4:0] fifo_level,

    output reg [31:0] n_acc,
    output reg [15:0] n_drop,
    output reg  [4:0] fifo_hw,
    output reg  [2:0] last_a,
    output reg [15:0] last_d,
    output reg [31:0] n_wr,           // /FDC cycles with /FDWR
    output reg [31:0] n_wr_cas0,      //   ... that also had /CAS0
    output reg [31:0] n_rd,           // /FDC cycles without /FDWR
    output reg [31:0] n_rd_cas0,      //   ... that had /CAS0
    output reg [31:0] n_cas_out,      // /CAS0 pulses outside the /FDC window
    output reg  [7:0] fdcw_min, fdcw_max,   // /FDC low width, write cycles
    output reg  [7:0] fdcr_min, fdcr_max,   // /FDC low width, no-/FDWR cycles
    output reg  [7:0] f2w_min,  f2w_max,    // /FDC fall -> /FDWR fall
    output reg  [7:0] ww_min,   ww_max,     // /FDWR low width
    output reg  [7:0] f2c_min,  f2c_max,    // /FDC fall -> /CAS0 fall (no-/FDWR cycles)
    output reg [15:0] n_fres,
    output            fres_now
);
    reg [1:0] s_fdc, s_fdwr, s_cas, s_fres;
    always @(posedge clk) begin
        s_fdc  <= {s_fdc[0],  fdc_n};
        s_fdwr <= {s_fdwr[0], fdwr_n};
        s_cas  <= {s_cas[0],  cas0_n};
        s_fres <= {s_fres[0], fres};
    end
    wire fdc  = ~s_fdc[1];
    wire fdwr = ~s_fdwr[1];
    wire cas  = ~s_cas[1];
    assign fres_now = s_fres[1];

    reg       in_cyc, saw_wr, saw_cas, cas_d, fres_d;
    reg [7:0] t, t_w, t_c, w_len;

    function [7:0] inc8(input [7:0] v); inc8 = (v == 8'hFF) ? v : v + 8'd1; endfunction
    function [31:0] inc32(input [31:0] v); inc32 = (v == 32'hFFFFFFFF) ? v : v + 32'd1; endfunction

    always @(posedge clk) begin
        if (rst) begin
            in_cyc <= 0; cas_d <= 0; fres_d <= 0;
            n_acc <= 0; n_drop <= 0; fifo_hw <= 0; last_a <= 0; last_d <= 0;
            n_wr <= 0; n_wr_cas0 <= 0; n_rd <= 0; n_rd_cas0 <= 0; n_cas_out <= 0;
            fdcw_min <= 8'hFF; fdcw_max <= 0; fdcr_min <= 8'hFF; fdcr_max <= 0;
            f2w_min <= 8'hFF; f2w_max <= 0; ww_min <= 8'hFF; ww_max <= 0;
            f2c_min <= 8'hFF; f2c_max <= 0; n_fres <= 0;
        end else begin
            cas_d <= cas; fres_d <= fres_now;
            if (acc_pulse) n_acc <= inc32(n_acc);
            if (drop_pulse && n_drop != 16'hFFFF) n_drop <= n_drop + 16'd1;
            if (fifo_level > fifo_hw) fifo_hw <= fifo_level;
            if (fres_now && !fres_d && n_fres != 16'hFFFF) n_fres <= n_fres + 16'd1;
            if (cas && !cas_d && !fdc && !in_cyc) n_cas_out <= inc32(n_cas_out);

            if (!in_cyc) begin
                if (fdc) begin
                    in_cyc <= 1; t <= 8'd1; saw_wr <= fdwr; saw_cas <= cas;
                    t_w <= 0; t_c <= 0; w_len <= fdwr ? 8'd1 : 8'd0;
                    if (fdwr) begin last_a <= a; last_d <= d; end
                end
            end else if (fdc) begin
                t <= inc8(t);
                if (fdwr) begin
                    w_len <= inc8(w_len);
                    if (!saw_wr) begin saw_wr <= 1; t_w <= t; last_a <= a; last_d <= d; end
                end
                if (cas && !saw_cas) begin saw_cas <= 1; t_c <= t; end
            end else begin
                // end of the /FDC cycle: classify and accumulate
                in_cyc <= 0;
                if (saw_wr) begin
                    n_wr <= inc32(n_wr);
                    if (saw_cas) n_wr_cas0 <= inc32(n_wr_cas0);
                    if (t < fdcw_min) fdcw_min <= t;
                    if (t > fdcw_max) fdcw_max <= t;
                    if (t_w < f2w_min) f2w_min <= t_w;
                    if (t_w > f2w_max) f2w_max <= t_w;
                    if (w_len < ww_min) ww_min <= w_len;
                    if (w_len > ww_max) ww_max <= w_len;
                end else begin
                    n_rd <= inc32(n_rd);
                    if (t < fdcr_min) fdcr_min <= t;
                    if (t > fdcr_max) fdcr_max <= t;
                    if (saw_cas) begin
                        n_rd_cas0 <= inc32(n_rd_cas0);
                        if (t_c < f2c_min) f2c_min <= t_c;
                        if (t_c > f2c_max) f2c_max <= t_c;
                    end
                end
            end
        end
    end
endmodule
