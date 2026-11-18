// ECP5-P2: unit test of rtl/vdpx_dma.v (Icarus, deterministic seed).
// Environment: VRAM write port with random "CPU" writes that take priority (the DMA must wait),
// sample memory with random latency and random "other owner" wait, 16-bit-word address space
// of 2^16 words (SMEM_AW = 16, so range checks are exercised near the top).
// Scoreboard (independent of the RTL): command validation per spec, expected write stream per
// accepted command (address, data, order), words per command, cancel/flush bookkeeping,
// handshake rules (req held until ack, request fields stable, nothing left asserted).
`timescale 1ns/1ps
module tb_dma_unit;
    parameter integer SEED = 32'h0DA0_0001;
    parameter integer NRAND = 4000;
    localparam AW = 16;
    reg clk = 0; always #10 clk = ~clk;
    reg rst = 1;
    reg vblank = 0;
    reg cfg_we = 0; reg [2:0] cfg_idx = 0; reg [15:0] cfg_data = 0;
    wire vw_req; wire [14:0] vw_addr; wire [15:0] vw_data;
    reg  vw_gnt_en = 1;
    wire vw_gnt = vw_req && vw_gnt_en;
    wire sm_req, sm_pair; wire [AW-1:0] sm_addr;
    reg sm_ack = 0; reg [15:0] sm_rdata = 0, sm_rdata_hi = 0; reg sm_wait = 0;
    wire busy; wire [1:0] disp_state, disp_op; wire [2:0] q_level;
    wire [15:0] words_cur, stalls_last, n_acc, n_rej, n_done, n_canc, rate_bcd;
    wire [23:0] cycles_last; wire [3:0] last_err; wire [7:0] last_tag;
    wire ev_accept, ev_reject, ev_start, ev_end, ev_end_cancelled, ev_cancel_cmd;
    wire [3:0] ev_code; wire [15:0] ev_words; wire [2:0] ev_flushed;

    vdpx_dma #(.SMEM_AW(AW)) dut (
        .clk(clk), .rst(rst), .vblank(vblank), .cfg_we(cfg_we), .cfg_idx(cfg_idx), .cfg_data(cfg_data),
        .vw_req(vw_req), .vw_addr(vw_addr), .vw_data(vw_data), .vw_gnt(vw_gnt),
        .sm_req(sm_req), .sm_addr(sm_addr), .sm_pair(sm_pair), .sm_ack(sm_ack),
        .sm_rdata(sm_rdata), .sm_rdata_hi(sm_rdata_hi), .sm_wait(sm_wait),
        .busy(busy), .disp_state(disp_state), .disp_op(disp_op), .q_level(q_level),
        .words_cur(words_cur), .cycles_last(cycles_last), .stalls_last(stalls_last),
        .n_accepted(n_acc), .n_rejected(n_rej), .n_done(n_done), .n_cancelled(n_canc),
        .last_err(last_err), .rate_bcd(rate_bcd), .last_tag(last_tag),
        .ev_accept(ev_accept), .ev_reject(ev_reject), .ev_code(ev_code), .ev_start(ev_start),
        .ev_end(ev_end), .ev_end_cancelled(ev_end_cancelled), .ev_words(ev_words),
        .ev_cancel_cmd(ev_cancel_cmd), .ev_flushed(ev_flushed));

    // ------------------------------------------------------------ memories
    reg [15:0] smem [0:(1<<AW)-1];
    reg [15:0] vram [0:32767];
    integer seed = SEED, i;
    integer errors = 0;
    task fail(input [8*80-1:0] m); begin errors = errors + 1; if (errors < 30) $display("ERRO @%0t: %0s", $time, m); end endtask

    // ------------------------------------------------------------ scoreboard state
    // staging (TB copy) and validity
    reg [15:0] t_src_lo, t_src_hi, t_dst, t_len, t_v0, t_v1; reg [5:0] t_valid;
    // expected command FIFO (accepted, in order): op, src, dst, len, v0, v1
    integer cq_op[0:63], cq_src[0:63], cq_dst[0:63], cq_len[0:63], cq_v0[0:63], cq_v1[0:63];
    integer cq_wr = 0, cq_rd = 0;        // accepted / started
    integer run_ok = 0, run_op, run_src, run_dst, run_len, run_v0, run_v1, run_n = 0;
    integer n_cmd_acc = 0, n_cmd_rej = 0, n_cmd_done = 0, n_cmd_canc = 0, n_words = 0, n_cpu_wr = 0;
    integer n_rej_code [0:15];
    integer cancel_seen = 0;
    reg pending_reject_check = 0; reg [3:0] exp_code;

    function [3:0] predict(input [2:0] op, input integer qlev);
        reg complete; reg [31:0] src; reg [16:0] dend; reg [32:0] send;
        begin
            src = {t_src_hi, t_src_lo}; dend = t_dst + t_len; send = src + t_len;
            complete = t_valid[2] && t_valid[3] && (op != 2 || (t_valid[0] && t_valid[1])) &&
                       (!(op == 1 || op == 3) || t_valid[4]) && (op != 3 || t_valid[5]);
            if (!(op == 1 || op == 2 || op == 3)) predict = 6;
            else if (!complete) predict = 5;
            else if (t_len == 0) predict = 1;
            else if (t_dst[15] || dend > 32768) predict = 2;
            else if (op == 2 && send > (33'd1 << AW)) predict = 3;
            else if (qlev == 4) predict = 4;
            else predict = 0;
        end
    endfunction

    // expected word k of the running command
    function [15:0] exp_data(input integer k);
        begin
            case (run_op)
                1: exp_data = run_v0;
                3: exp_data = (k % 2) ? run_v1 : run_v0;
                default: exp_data = smem[(run_src + k) & ((1<<AW)-1)];
            endcase
        end
    endfunction

    // ------------------------------------------------------------ bus-side tasks
    task cfg(input [2:0] idx, input [15:0] d);
        begin
            @(negedge clk); cfg_we = 1; cfg_idx = idx; cfg_data = d;
            case (idx) 0: t_src_lo = d; 1: t_src_hi = d; 2: t_dst = d; 3: t_len = d; 4: t_v0 = d; 5: t_v1 = d; default: ; endcase
            if (idx < 6) t_valid[idx] = 1;
            if (idx == 7 && d[2:0] != 4) begin
                exp_code = predict(d[2:0], q_level);
                if (exp_code == 0) begin
                    cq_op[cq_wr % 64] = d[2:0]; cq_src[cq_wr % 64] = {t_src_hi, t_src_lo}; cq_dst[cq_wr % 64] = t_dst;
                    cq_len[cq_wr % 64] = t_len; cq_v0[cq_wr % 64] = t_v0; cq_v1[cq_wr % 64] = t_v1;
                    cq_wr = cq_wr + 1;
                end
                pending_reject_check = 1;
            end
            if (idx == 7 && d[2:0] == 4) cancel_seen = 1;
            @(negedge clk); cfg_we = 0;
        end
    endtask
    task cmd(input [2:0] op, input [15:0] src_lo, input [15:0] src_hi, input [15:0] dst, input [15:0] len,
             input [15:0] v0, input [15:0] v1, input vs);
        begin
            cfg(0, src_lo); cfg(1, src_hi); cfg(2, dst); cfg(3, len); cfg(4, v0); cfg(5, v1);
            cfg(7, {8'h5A, 4'd0, vs, op});
        end
    endtask
    task wait_idle(input integer limit);
        integer g;
        begin g = 0; while ((busy || run_ok) && g < limit) begin @(posedge clk); g = g + 1; end
              if (g >= limit) fail("timeout esperando o DMA ocioso"); end
    endtask

    // ------------------------------------------------------------ environment processes
    integer p_block = 30, lat_max = 12, p_wait = 30;
    // VRAM: random CPU writes with priority (they block the DMA grant)
    always @(posedge clk) begin
        if (!rst && ($urandom(seed) % 100) < p_block) begin
            vw_gnt_en <= 0;
        end else vw_gnt_en <= 1;
    end
    always @(posedge clk) if (!rst && !vw_gnt_en) begin
        // the cycle the DMA was refused is a CPU write cycle (outside the DMA area 0x6000..)
        vram[15'h7F00 + (n_cpu_wr % 200)] <= n_cpu_wr[15:0]; n_cpu_wr = n_cpu_wr + 1;
    end
    // sample memory: random latency, random wait behind another owner
    integer sm_cnt = -1; reg [AW-1:0] sm_a_q; reg sm_pair_q, sm_req_d = 0;
    always @(posedge clk) begin
        sm_ack <= 0;
        sm_wait <= sm_req && (($urandom(seed) % 100) < p_wait) && sm_cnt < 0;
        if (rst) sm_cnt = -1;
        else if (sm_req && sm_cnt < 0 && !sm_ack) begin
            sm_cnt = 1 + ($urandom(seed) % lat_max); sm_a_q <= sm_addr; sm_pair_q <= sm_pair;
        end else if (sm_cnt > 0) sm_cnt = sm_cnt - 1;
        else if (sm_cnt == 0) begin
            sm_ack <= 1; sm_rdata <= smem[sm_a_q]; sm_rdata_hi <= smem[sm_a_q ^ 1]; sm_cnt = -1;
        end
    end

    // ------------------------------------------------------------ monitors / scoreboard
    reg [AW-1:0] sm_addr_d; reg sm_ack_d = 0; reg vw_req_d = 0, vw_gnt_d = 0; reg [14:0] vw_addr_d; reg [15:0] vw_data_d;
    always @(posedge clk) begin
        if (!rst) begin
            // handshake rules
            if (sm_req_d && !sm_req && !sm_ack_d) fail("sm_req caiu sem ack");
            if (sm_req_d && sm_req && !sm_ack_d && sm_addr != sm_addr_d) fail("sm_addr mudou durante o pedido");
            if (sm_req && sm_pair && sm_addr[0]) fail("par com endereço ímpar");
            if (vw_req_d && !vw_gnt_d && vw_req && (vw_addr != vw_addr_d || vw_data != vw_data_d)) fail("escrita VRAM mudou sem grant");
            if (vw_req_d && !vw_gnt_d && !vw_req && !ev_end && !cancel_seen) fail("vw_req caiu sem grant nem fim");
            // reject / accept codes
            if (pending_reject_check && (ev_accept || ev_reject)) begin
                pending_reject_check = 0;
                if (ev_accept && exp_code != 0) begin fail("aceito mas o modelo esperava rejeição"); end
                if (ev_reject && ev_code != exp_code) begin
                    $display("   código rtl=%0d modelo=%0d", ev_code, exp_code); fail("código de rejeição diferente");
                end
                if (ev_reject) begin n_cmd_rej = n_cmd_rej + 1; n_rej_code[ev_code] = n_rej_code[ev_code] + 1; end
                else n_cmd_acc = n_cmd_acc + 1;
            end
            if (ev_cancel_cmd) begin
                // flushed = accepted and not started
                if (ev_flushed != (cq_wr - cq_rd)) begin
                    $display("   flushed rtl=%0d modelo=%0d", ev_flushed, cq_wr - cq_rd); fail("número de comandos descartados");
                end
                n_cmd_canc = n_cmd_canc + (cq_wr - cq_rd);
                cq_rd = cq_wr;
            end
            if (ev_start) begin
                if (cq_rd >= cq_wr) fail("início sem comando aceito");
                run_op = cq_op[cq_rd % 64]; run_src = cq_src[cq_rd % 64]; run_dst = cq_dst[cq_rd % 64];
                run_len = cq_len[cq_rd % 64]; run_v0 = cq_v0[cq_rd % 64]; run_v1 = cq_v1[cq_rd % 64];
                run_n = 0; run_ok = 1; cq_rd = cq_rd + 1;
                if (disp_op != 0 && 0) ;
            end
            // DMA writes: address/data/order
            if (vw_req && vw_gnt) begin
                if (!run_ok) fail("escrita sem comando em execução");
                else begin
                    if (vw_addr != run_dst + run_n) fail("endereço de escrita fora de ordem");
                    if (vw_data != exp_data(run_n)) begin
                        $display("   palavra %0d: rtl=%h esperado=%h (op %0d)", run_n, vw_data, exp_data(run_n), run_op);
                        fail("dado escrito errado");
                    end
                    if (run_n >= run_len) fail("escrita além do comprimento");
                    vram[vw_addr] <= vw_data;
                    run_n = run_n + 1; n_words = n_words + 1;
                end
            end
            if (ev_end) begin
                if (ev_words != run_n) begin $display("   palavras rtl=%0d contadas=%0d", ev_words, run_n); fail("contagem de palavras"); end
                if (!ev_end_cancelled && run_n != run_len) fail("fim normal antes do comprimento");
                if (ev_end_cancelled) n_cmd_canc = n_cmd_canc + 1; else n_cmd_done = n_cmd_done + 1;
                run_ok = 0; cancel_seen = 0;
            end
        end
        sm_req_d <= sm_req; sm_addr_d <= sm_addr; sm_ack_d <= sm_ack;
        vw_req_d <= vw_req; vw_gnt_d <= vw_gnt; vw_addr_d <= vw_addr; vw_data_d <= vw_data;
    end

    // ------------------------------------------------------------ test program
    integer k, op, len, dst, srcw, n_dir = 0;
    reg [15:0] r16;
    task do_reset;
        begin
            @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
            t_valid = 0; cq_rd = 0; cq_wr = 0; run_ok = 0; pending_reject_check = 0; cancel_seen = 0;
            @(negedge clk);
            if (sm_req || vw_req || busy) fail("saídas ativas depois do reset");
        end
    endtask
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) smem[i] = (i * 16'h9E37) ^ 16'h5A5A;
        for (i = 0; i < 32768; i = i + 1) vram[i] = 0;
        for (i = 0; i < 16; i = i + 1) n_rej_code[i] = 0;
        t_valid = 0;
        repeat (4) @(negedge clk); rst = 0;

        // ---- directed
        cmd(2, 0, 0, 16'h6000, 4, 0, 0, 0);              // COPY before... (all params set: accepted)
        wait_idle(2000);
        do_reset;
        cfg(2, 16'h6000); cfg(3, 8); cfg(7, 16'd2);       // COPY without SRC since reset: INCOMPLETE
        cfg(7, 16'd1);                                    // FILL without VALUE0: INCOMPLETE
        cfg(4, 16'h1111); cfg(7, 16'd3);                  // PATTERN without VALUE1: INCOMPLETE
        cfg(7, 16'd0); cfg(7, 16'd5); cfg(7, 16'd7);      // BAD_OP
        cmd(1, 0, 0, 16'h6000, 0, 16'hAAAA, 0, 0);        // ZERO_LEN
        cmd(1, 0, 0, 16'h7FFF, 1, 16'hBEEF, 0, 0);        // last word: ACCEPT
        wait_idle(1000);
        if (vram[15'h7FFF] != 16'hBEEF) fail("último endereço da VRAM");
        cmd(1, 0, 0, 16'h7FF8, 9, 16'h1, 0, 0);           // one past the end: DST_RANGE
        cmd(1, 0, 0, 16'h8000, 1, 16'h1, 0, 0);           // DST[15]: DST_RANGE
        cmd(1, 0, 0, 16'h0000, 16'hFFFF, 16'h1, 0, 0);    // longer than the VRAM: DST_RANGE
        cmd(2, 16'hFFF0, 0, 16'h6000, 17, 0, 0, 0);       // SRC+LEN beyond 2^16: SRC_RANGE
        cmd(2, 16'h0000, 1, 16'h6000, 1, 0, 0, 0);        // SRC_HI beyond the memory: SRC_RANGE
        cmd(2, 16'hFFF0, 0, 16'h6000, 16, 0, 0, 0);       // last 16 words of the memory: ACCEPT
        cmd(2, 16'h0001, 0, 16'h6100, 1, 0, 0, 0);        // one word, odd source
        cmd(2, 16'h0003, 0, 16'h6200, 7, 0, 0, 0);        // odd source, odd length (single + pairs)
        cmd(3, 0, 0, 16'h6300, 9, 16'hC0DE, 16'hF00D, 0); // PATTERN
        wait_idle(5000);
        // reserved index 6 between staging and commit: ignored (FILL must use the staged VALUE0)
        cfg(2, 16'h6400); cfg(3, 2); cfg(4, 16'h4242); cfg(6, 16'hFFFF); cfg(7, 16'd1);
        wait_idle(5000);
        if (vram[15'h6401] != 16'h4242) fail("índice 6 alterou o comando");
        // CANCEL with an idle engine and an empty queue: no effect, nothing flushed
        cfg(7, 16'd4);
        repeat (5) @(posedge clk);
        if (busy || sm_req || vw_req) fail("CANCEL ocioso ativou o motor");
        cancel_seen = 0;
        // queue full: 1 running + 4 queued, the 6th is rejected; staging changes after commit
        p_block = 90;
        for (k = 0; k < 6; k = k + 1) cmd(1, 0, 0, 16'h0100 * k, 16'h0100, 16'h1000 + k, 0, 0);
        cfg(4, 16'hDEAD);                                  // must not affect queued commands
        p_block = 30;
        wait_idle(100000);
        // cancel during a SDRAM read (long latency) and during VRAM writes (blocked grant)
        lat_max = 200;
        cmd(2, 16'h0100, 0, 16'h0000, 16'h0400, 0, 0, 0);
        cmd(1, 0, 0, 16'h2000, 16'h0100, 16'h7777, 0, 0); // queued, will be flushed
        repeat (150) @(posedge clk);
        cfg(7, 16'd4);
        wait_idle(5000);
        lat_max = 12; p_block = 98;
        cmd(1, 0, 0, 16'h3000, 16'h0800, 16'h4444, 0, 0);
        repeat (300) @(posedge clk);
        cfg(7, 16'd4);
        wait_idle(5000);
        p_block = 30;
        // VSYNC: does not start before the vblank edge; cancel while waiting
        cmd(1, 0, 0, 16'h3800, 4, 16'h5555, 0, 1);
        repeat (50) @(posedge clk);
        if (n_words != 0 && run_n != 0) fail("VSYNC começou antes do vblank");
        cfg(7, 16'd4); wait_idle(1000);
        cmd(1, 0, 0, 16'h3800, 4, 16'h6666, 0, 1);
        repeat (50) @(posedge clk); vblank = 1; repeat (20) @(posedge clk); vblank = 0;
        wait_idle(1000);
        if (vram[15'h3803] != 16'h6666) fail("VSYNC não executou");
        // reset during a transfer
        cmd(2, 16'h0200, 0, 16'h4000, 16'h1000, 0, 0, 0);
        repeat (500) @(posedge clk);
        do_reset;
        cmd(1, 0, 0, 16'h4800, 16, 16'h9999, 0, 0);        // works after reset (all params given)
        wait_idle(1000);
        if (vram[15'h480F] != 16'h9999) fail("DMA depois do reset");
        n_dir = n_cmd_acc + n_cmd_rej;
        $display("dirigidos: %0d comandos (%0d aceitos, %0d rejeitados), %0d palavras", n_dir, n_cmd_acc, n_cmd_rej, n_words);

        // ---- random: commands, invalid values, cancels, backpressure, latency
        for (k = 0; k < NRAND; k = k + 1) begin
            p_block = $urandom(seed) % 95; lat_max = 1 + $urandom(seed) % 40; p_wait = $urandom(seed) % 80;
            op = 1 + ($urandom(seed) % 3);
            r16 = $urandom(seed);
            case ($urandom(seed) % 8)
                0: len = 0;
                1: len = 1;
                2: len = 1 + ($urandom(seed) % 4);
                3: len = 16'h8000;
                4: len = 1 + ($urandom(seed) % 600);
                default: len = 1 + ($urandom(seed) % 64);
            endcase
            dst = ($urandom(seed) % 100 < 5) ? 32768 - len + ($urandom(seed) % 3) - 1 : ($urandom(seed) % 32768);
            srcw = ($urandom(seed) % 100 < 5) ? (1 << AW) - len + ($urandom(seed) % 3) - 1 : ($urandom(seed) % (1 << AW));
            if (($urandom(seed) % 100) < 3) op = 5;              // invalid op
            cmd(op, srcw[15:0], srcw >> 16, dst[15:0], len[15:0], $urandom(seed), $urandom(seed), 0);
            if (($urandom(seed) % 100) < 4) begin repeat ($urandom(seed) % 200) @(posedge clk); cfg(7, 16'd4); end
            if (($urandom(seed) % 100) < 25) wait_idle(4000000);   // 32K words at 95% blocking ~ 650k cycles
            if (($urandom(seed) % 1000) < 3) begin repeat ($urandom(seed) % 300) @(posedge clk); do_reset; end
        end
        wait_idle(4000000);
        repeat (50) @(posedge clk);
        if (run_ok || cq_rd != cq_wr) fail("comandos esperados não executados");
        if (sm_req || vw_req) fail("pedido preso no fim");
        $display("DMA unit (seed %h): %0d comandos aceitos, %0d rejeitados, %0d concluídos, %0d cancelados/descartados, %0d palavras escritas, %0d escritas de CPU concorrentes",
                 SEED, n_cmd_acc, n_cmd_rej, n_cmd_done, n_cmd_canc, n_words, n_cpu_wr);
        $display("   rejeições por código: ZERO %0d DST %0d SRC %0d FILA %0d INCOMPLETO %0d OP %0d",
                 n_rej_code[1], n_rej_code[2], n_rej_code[3], n_rej_code[4], n_rej_code[5], n_rej_code[6]);
        if (errors == 0 && n_rej_code[1] && n_rej_code[2] && n_rej_code[3] && n_rej_code[4] && n_rej_code[5] && n_rej_code[6])
            $display("PASS DMA unit");
        else begin $display("FAIL DMA unit (%0d erros)", errors); $fatal(1); end
        $finish;
    end
endmodule
