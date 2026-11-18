// ECP5-P1: directed + random test of sdram_ctrl RMW = 1 against sdram_model HONOR_DQM = 0
// (Colorlight i9: DQM0-3 tied to GND, every WRITE stores 32 bits). A golden copy of the
// 16-bit address space is kept; every read is compared, and the model checks protocol,
// timing (tRCD, tRC, tRP, tRFC, CL2, refresh interval) and DQ contention.
//
// Board timing (real delays, Icarus): SDRAM clock = clk shifted by PHASE_NS (PLL CLKOS3) and
// delayed by TOC to the SDRAM pin; commands/data reach the SDRAM TCMD after the clk edge;
// read data is valid at the FPGA flip-flops from edge N+1 + TOC + TAC + TIN_MAX to
// edge N+2 + TOC + TOH + TIN_MIN (M12L64322A grade -7, CL2: tAC 8 ns, tOH 2 ns).
//   default                         PHASE_NS 16, RDCAP 3  (ECP5-P1)           -> must PASS
//   -Ptb_sdram_rmw.PHASE_NS=10.0 -Ptb_sdram_rmw.RDCAP=2   (M4.2 scheme on i9) -> must FAIL
`timescale 1ns/1ps
module tb_sdram_rmw;
    parameter real PHASE_NS = 16.0;
    parameter integer RDCAP = 3;
    parameter integer RMW_UNDER_TEST = 1;     // 0 = negative test (M4.2 controller, DQM masks)
    parameter real TOC = 3.5, TAC = 8.0, TOH = 2.0, TIN_MAX = 7.0, TIN_MIN = 1.0, TCMD = 5.0;
    reg clk = 0;
    always #10 clk = ~clk;                    // 50 MHz
    reg clk_sd = 0;                           // clk delayed by PHASE_NS, then TOC to the pin
    always @(clk) clk_sd <= #(PHASE_NS + TOC) clk;
    reg rst = 1;

    reg         req = 0, we = 0;
    reg  [21:0] addr = 0;
    reg  [15:0] wdata = 0;
    wire        ack, ready;
    wire [15:0] rdata;
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire  [1:0] sd_ba;
    wire [10:0] sd_a;
    wire  [3:0] sd_dqm;
    wire [31:0] sd_dq_out, sd_dq_mem, errors;

    wire [31:0] sd_dq_fpga;
    sdram_ctrl #(.INIT_CYCLES(200), .RMW(RMW_UNDER_TEST), .RD_CAPTURE(RDCAP)) dut (
        .clk(clk), .rst(rst), .req(req), .we(we), .addr(addr), .wdata(wdata),
        .ack(ack), .rdata(rdata), .ready(ready),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm),
        .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_fpga));
    // FPGA -> SDRAM pins (transport delay TCMD); board wiring: CS# = GND, CKE = 3V3, DQM = GND
    reg [3:0] p_cmd = 4'b0111; reg [1:0] p_ba = 0; reg [10:0] p_a = 0; reg [31:0] p_dq = 0; reg p_oe = 0;
    always @(sd_ras_n or sd_cas_n or sd_we_n or sd_ba or sd_a or sd_dq_out or sd_dq_oe) begin
        p_cmd <= #(TCMD) {1'b0, sd_ras_n, sd_cas_n, sd_we_n};
        p_ba <= #(TCMD) sd_ba; p_a <= #(TCMD) sd_a; p_dq <= #(TCMD) sd_dq_out; p_oe <= #(TCMD) sd_dq_oe;
    end
    wire mem_drv;
    sdram_model #(.INIT_MIN(100), .HONOR_DQM(0)) mem (
        .sd_clk(clk_sd), .cke(1'b1), .cs_n(p_cmd[3]), .ras_n(p_cmd[2]), .cas_n(p_cmd[1]), .we_n(p_cmd[0]),
        .ba(p_ba), .a(p_a), .dqm(4'b0000), .dq_in(p_oe ? p_dq : 32'hZZZZ_ZZZZ),
        .dq_out(sd_dq_mem), .ctrl_oe(p_oe), .ref_relaxed(1'b0), .errors(errors), .dq_drv(mem_drv));
    // SDRAM pins -> FPGA flip-flops: worst-case valid window of the read data
    reg ds = 0, de = 0; reg [31:0] dlat = 0;
    always @(mem_drv) begin
        ds <= #(TAC + TIN_MAX) mem_drv;          // valid no earlier than N+1 + TOC + TAC + TIN_MAX
        de <= #(TOH + TIN_MIN) mem_drv;          // ... and no later than N+2 + TOC + TOH + TIN_MIN
    end
    always @(posedge mem_drv) dlat <= sd_dq_mem;
    assign sd_dq_fpga = (ds && de) ? dlat : 32'hDEADBEEF;

    reg [15:0] gold [0:(1<<22)-1];
    reg        known [0:(1<<22)-1];
    integer i, b, k, fails = 0, nrd = 0, nwr = 0, cyc = 0, max_lat = 0, t0;
    always @(posedge clk) cyc <= cyc + 1;

    task wr(input [21:0] a, input [15:0] d);
        begin
            @(posedge clk); req <= 1; we <= 1; addr <= a; wdata <= d; t0 = cyc;
            @(posedge clk); while (!ack) @(posedge clk);
            req <= 0;
            if (cyc - t0 > max_lat) max_lat = cyc - t0;
            gold[a] = d; known[a] = 1; nwr = nwr + 1;
        end
    endtask
    task rd(input [21:0] a);
        begin
            @(posedge clk); req <= 1; we <= 0; addr <= a; t0 = cyc;
            @(posedge clk); while (!ack) @(posedge clk);
            req <= 0;
            if (cyc - t0 > max_lat) max_lat = cyc - t0;
            nrd = nrd + 1;
            #1;
            if (known[a] && rdata !== gold[a]) begin
                fails = fails + 1;
                if (fails < 20) $display("FALHA leitura a=%06h lido=%04h esperado=%04h", a, rdata, gold[a]);
            end
        end
    endtask
    // the 32-bit word in the SDRAM model must hold {odd half, even half} (M4.2 organization)
    task chk_word(input [21:0] a);
        reg [31:0] w;
        begin
            w = mem.mem[{a[21:11], a[10:9], a[8:1]}];
            if (known[{a[21:1], 1'b0}] && w[15:0] !== gold[{a[21:1], 1'b0}]) begin
                fails = fails + 1; $display("FALHA palavra %06h metade par %04h esperado %04h", a, w[15:0], gold[{a[21:1], 1'b0}]);
            end
            if (known[{a[21:1], 1'b1}] && w[31:16] !== gold[{a[21:1], 1'b1}]) begin
                fails = fails + 1; $display("FALHA palavra %06h metade impar %04h esperado %04h", a, w[31:16], gold[{a[21:1], 1'b1}]);
            end
        end
    endtask

    reg [21:0] ra, extremes [0:11];
    reg [15:0] rv;
    integer seed = 32'h5EED_0001, n_extreme_ok, cyc_load0;
    integer c_walk = 0, c_ext = 0, c_alt = 0, c_burst = 0, c_rand = 0, c_sweep = 0;
    initial begin
        for (i = 0; i < (1<<22); i = i + 1) known[i] = 0;
        repeat (5) @(posedge clk);
        rst <= 0;
        wait (ready);

        // 1. walking 1 / walking 0 on both halves of several words (rows/banks/columns)
        for (k = 0; k < 8; k = k + 1) begin
            ra = (22'h05A5A4 + k * 22'h0821) & 22'h3FFFFE;
            for (b = 0; b < 16; b = b + 1) begin
                wr(ra, 16'h1 << b);  wr(ra + 1, ~(16'h1 << b));
                rd(ra); rd(ra + 1); chk_word(ra);
                wr(ra + 1, 16'h1 << b); wr(ra, ~(16'h1 << b));
                rd(ra); rd(ra + 1); chk_word(ra);
                c_walk = c_walk + 8;
            end
        end

        // 2. extreme addresses: first/last word, column/bank/row boundaries
        extremes[0] = 22'h000000; extremes[1] = 22'h000001; extremes[2] = 22'h3FFFFF; extremes[3] = 22'h3FFFFE;
        extremes[4] = 22'h0001FF; extremes[5] = 22'h000200; extremes[6] = 22'h0007FF; extremes[7] = 22'h000800;
        extremes[8] = 22'h1FFFFF; extremes[9] = 22'h200000; extremes[10] = 22'h3FF800; extremes[11] = 22'h0007FE;
        for (k = 0; k < 12; k = k + 1) wr(extremes[k], 16'hA000 + k);
        for (k = 0; k < 12; k = k + 1) begin rd(extremes[k]); chk_word(extremes[k]); c_ext = c_ext + 1; end

        // 3. alternating writes to the two halves of the same 32-bit word (neighbor must survive)
        for (k = 0; k < 2000; k = k + 1) begin
            ra = {$random(seed)} & 22'h3FFFFE;
            wr(ra, $random(seed)); rd(ra + 1);
            wr(ra + 1, $random(seed)); rd(ra);
            wr(ra, $random(seed)); rd(ra + 1); rd(ra);
            chk_word(ra);
            c_alt = c_alt + 1;
        end

        // 4. bursts: back-to-back requests on a small region (same rows, alternating halves)
        for (k = 0; k < 4000; k = k + 1) begin
            ra = 22'h123400 + ({$random(seed)} & 22'h3F);
            if ($random(seed) & 1) wr(ra, $random(seed)); else rd(ra);
            c_burst = c_burst + 1;
        end

        // 5. refresh under load + 6. integrity: random mixed traffic over the whole 8 MB
        cyc_load0 = cyc;
        for (k = 0; k < 60000; k = k + 1) begin
            ra = {$random(seed)} & 22'h3FFFFF;
            if ($random(seed) & 1) wr(ra, $random(seed)); else rd(ra);
            c_rand = c_rand + 1;
        end
        // final sweep: re-read every word written by the extreme/burst sections
        for (k = 0; k < 12; k = k + 1) begin rd(extremes[k]); c_sweep = c_sweep + 1; end
        for (k = 0; k < 64; k = k + 1) begin rd(22'h123400 + k); c_sweep = c_sweep + 1; end

        repeat (50) @(posedge clk);
        $display("SDRAM RMW (fase do clock %0.1f ns, captura na borda %0d, tAC %0.1f, tOH %0.1f, tIN %0.1f..%0.1f, tOC %0.1f ns):",
                 PHASE_NS, RDCAP, TAC, TOH, TIN_MIN, TIN_MAX, TOC);
        $display("           walking=%0d extremos=%0d alternadas=%0d rajadas=%0d aleatorias=%0d varredura=%0d",
                 c_walk, c_ext, c_alt, c_burst, c_rand, c_sweep);
        $display("           %0d escritas de 16 bits, %0d leituras, %0d escritas de 32 bits no modelo, latencia maxima %0d ciclos",
                 nwr, nrd, mem.n_wr, max_lat);
        $display("           %0d ciclos sob carga (%0d intervalos de refresh), %0d erros de protocolo/timing, %0d falhas de dados",
                 cyc - cyc_load0, (cyc - cyc_load0) / 700, errors, fails);
        if (fails == 0 && errors == 0 && mem.n_wr == nwr) $display("PASS SDRAM RMW sem DQM");
        else begin $display("FAIL SDRAM RMW"); $fatal(1); end
        $finish;
    end
    initial begin #2000000000; $display("FAIL timeout"); $fatal(1); end
endmodule
