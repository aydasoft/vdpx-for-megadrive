// ECP5-P2: DMA reference model + system scoreboard (shared by tb_main, tb_m4, tb_ecp5).
//
// RefDMA (written from DMA_REGISTER_MAP.md, not from the RTL) receives the target-6 writes
// that the reference model sees on the bus, validates each COMMAND and records the expected
// outcome. DmaCheck then follows the RTL through its verification taps:
//   - accept/reject events must come in commit order, with the predicted code (QUEUE_FULL is
//     timing dependent: accepted only when the RTL queue was full, counted separately);
//   - every DMA write on the VRAM write port must be the next (address, data) of the running
//     command; COPY data comes from the reference sample memory; the write is then applied to
//     the reference VRAM, so the reference follows the real port order;
//   - CPU writes on the VRAM port (when deferred) are matched against the bus writes;
//   - end events report the number of writes actually seen; cancels flush exactly the
//     accepted-but-not-started commands.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <vector>

struct DmaCmd {
    int op = 0;                 // 1 FILL 2 COPY 3 PATTERN, 4 CANCEL marker
    uint32_t src = 0;
    unsigned dst = 0, len = 0;
    uint16_t v0 = 0, v1 = 0;
    int code = 0;               // predicted code (0 = accept)
};

struct RefDMA {
    uint16_t r[6] = {0};
    unsigned valid = 0;
    unsigned smem_aw = 20;
    std::deque<DmaCmd> commits;  // in bus order, consumed by DmaCheck

    void reset() { valid = 0; commits.clear(); }
    void write(unsigned idx, uint16_t d) {
        if (idx < 6) { r[idx] = d; valid |= 1u << idx; return; }
        if (idx != 7) return;
        DmaCmd c;
        int op = d & 7;
        c.op = op;
        if (op == 4) { commits.push_back(c); return; }
        c.src = ((uint32_t)r[1] << 16) | r[0];
        c.dst = r[2]; c.len = r[3]; c.v0 = r[4]; c.v1 = r[5];
        bool need_src = op == 2, need_v0 = op == 1 || op == 3, need_v1 = op == 3;
        bool complete = (valid & 0xC) == 0xC && (!need_src || (valid & 3) == 3) &&
                        (!need_v0 || (valid & 16)) && (!need_v1 || (valid & 32));
        if (op < 1 || op > 3) c.code = 6;
        else if (!complete) c.code = 5;
        else if (c.len == 0) c.code = 1;
        else if ((c.dst & 0x8000) || c.dst + c.len > 32768) c.code = 2;
        else if (need_src && (uint64_t)c.src + c.len > (1ull << smem_aw)) c.code = 3;
        else c.code = 0;
        commits.push_back(c);
    }
};

struct DmaCheck {
    uint16_t *vram = nullptr;             // reference VRAM (32768 words)
    const std::vector<uint16_t> *smem = nullptr;
    unsigned smem_mask = 0;
    RefDMA *dma = nullptr;
    std::deque<DmaCmd> queued;            // accepted, not started
    DmaCmd run; bool running = false; unsigned run_n = 0;
    std::deque<std::pair<unsigned, uint16_t>> cpu_q;   // deferred CPU VRAM writes (bus order)
    bool defer_cpu = false;
    long errors = 0, accepted = 0, rejected = 0, qfull = 0, done = 0, cancelled = 0, flushed = 0,
         dma_words = 0, cpu_words = 0;
    long rej_code[16] = {0};
    int last_code = -1;

    void err(const char *m, long a = -1, long b = -1) {
        if (errors < 20) fprintf(stderr, "DMA CHECK: %s (%ld, %ld)\n", m, a, b);
        errors++;
    }
    uint16_t exp_word(unsigned k) const {
        switch (run.op) {
            case 1: return run.v0;
            case 3: return (k & 1) ? run.v1 : run.v0;
            default: return (*smem)[(run.src + k) & smem_mask];
        }
    }
    // call once per system clock, after the rising edge was evaluated
    // ev: dma_events bus (see vdpx_top.v); vw_*: VRAM write port taps; q_level: RTL queue level
    void cycle(uint32_t ev, bool vw_we, bool vw_dma, unsigned vw_addr, uint16_t vw_data, unsigned q_level) {
        bool e_acc = (ev >> 28) & 1, e_rej = (ev >> 27) & 1, e_start = (ev >> 22) & 1, e_end = (ev >> 21) & 1;
        bool e_endc = (ev >> 20) & 1, e_canc = (ev >> 3) & 1;
        unsigned code = (ev >> 23) & 15, words = (ev >> 4) & 0xFFFF, fl = ev & 7;
        (void)q_level;
        if (e_acc || e_rej || e_canc) {
            // events of one commit; a cancel and an accept/reject never share a cycle
            if (dma->commits.empty()) { err("evento sem commit no modelo"); return; }
            DmaCmd c = dma->commits.front(); dma->commits.pop_front();
            if (e_canc) {
                if (c.op != 4) err("cancel no RTL, outro comando no modelo", c.op);
                if (fl != queued.size()) err("descartados (rtl, modelo)", fl, (long)queued.size());
                flushed += queued.size(); cancelled += queued.size();
                queued.clear();
            } else {
                if (c.op == 4) err("modelo esperava cancel");
                last_code = code;
                if (e_acc) {
                    if (c.code != 0) err("aceito, modelo esperava rejeição", c.code);
                    queued.push_back(c); accepted++;
                } else {
                    rejected++; rej_code[code & 15]++;
                    if (code == 4 && c.code == 0) qfull++;            // timing dependent: queue full
                    else if ((int)code != c.code) err("código de rejeição (rtl, modelo)", code, c.code);
                }
            }
        }
        if (e_start) {
            if (queued.empty()) err("início sem comando aceito");
            else { run = queued.front(); queued.pop_front(); running = true; run_n = 0; }
        }
        if (vw_we) {
            if (vw_dma) {
                if (!running) err("escrita DMA sem comando", vw_addr);
                else {
                    if (vw_addr != ((run.dst + run_n) & 0x7fff)) err("endereço DMA (rtl, esperado)", vw_addr, run.dst + run_n);
                    uint16_t e = exp_word(run_n);
                    if (vw_data != e) err("dado DMA (rtl, esperado)", vw_data, e);
                    if (run_n >= run.len) err("escrita DMA além do comprimento");
                    run_n++; dma_words++;
                }
                vram[vw_addr & 0x7fff] = vw_data;
            } else if (defer_cpu) {
                if (cpu_q.empty()) err("escrita CPU na porta sem escrita no barramento", vw_addr);
                else {
                    auto w = cpu_q.front(); cpu_q.pop_front();
                    if (w.first != vw_addr || w.second != vw_data) err("escrita CPU (endereço rtl, esperado)", vw_addr, w.first);
                }
                vram[vw_addr & 0x7fff] = vw_data; cpu_words++;
            }
        }
        if (e_end) {
            if (!running) err("fim sem comando");
            if (words != run_n) err("palavras no fim (rtl, vistas)", words, run_n);
            if (!e_endc && run_n != run.len) err("fim normal antes do comprimento", run_n, run.len);
            if (e_endc) cancelled++; else done++;
            running = false;
        }
    }
    bool idle() const { return !running && queued.empty() && dma->commits.empty(); }
    void report(const char *tag) const {
        printf("    DMA%s: %ld aceitos, %ld rejeitados (fila cheia %ld), %ld concluídos, %ld cancelados (%ld da fila), "
               "%ld palavras DMA conferidas, %ld escritas CPU conferidas na porta, %ld erros\n",
               tag, accepted, rejected, qfull, done, cancelled, flushed, dma_words, cpu_words, errors);
    }
};
