// M4.2 write-only co-simulation (tb_m2wo): fx68k + o md_fdc_adapter SINTETIZÁVEL (só escrita).
// Derivado do tb_m2. Leituras na janela da VDPX não são conferidas com o modelo: o
// barramento fica solto (FFFF), e o teste exige que o adaptador nunca o dirija.
// Mede: nível máximo da FIFO, palavras perdidas, intervalo mínimo entre escritas.
//
// M2 co-simulation testbench: fx68k runs m68k/rom.hex, VDPX is driven only
// through the console-side CN2 strobes + md_fdc_adapter. Every transaction that reaches the
// VDPX core is mirrored into the reference model; captured frames are
// compared pixel by pixel with the model state at the end of the frame.
//
// Debug port protocol ($600000, written by the 68000 program):
//   0xC0nn progress, 0xE0nn self-test error count, 0x10nn capture frame nn,
//   0xD000 done, 0xDEAD exception/halt.
#ifndef CLK_MHZ
#define CLK_MHZ 50.4   // ECP5-P1: 50.0 with -DCLK_MHZ=50.0
#endif
#include "Vmd_sim_top.h"
#ifndef M2_PREFETCH_VAL
#define M2_PREFETCH_VAL 1
#endif
#include "verilated.h"
#include "../refmodel.h"
#include "../audio_tb.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static Vmd_sim_top *dut;
static uint64_t cycles = 0;
static int errors = 0;
static RefVDPX ref;          // fed from the 68000 side
static AudioTB aud;
static RefVDPX ref_core;     // fed from the core side (consistency)
// P2: DMA scoreboards on both models (68000 side and core side) + benchmark markers
static DmaCheck dchk_core;
static const bool bench = getenv("M2_BENCH") != nullptr;
static uint64_t dma_t_start = 0;
static long n_dma_end = 0;

// capture
static std::vector<uint8_t> cap(640 * 480 * 3);
static int cx, cy, prev_de = 0, prev_vs = 1, prev_vbl = 0;
static long cap_pixels;
enum { CAP_IDLE, CAP_ARMED, CAP_RUN } cap_state = CAP_IDLE;
static int cap_id = -1;
static RefVDPX snap;
static bool have_snap = false;
static int frames_ok = 0, frames_bad = 0;

// statistics
static long n_wr = 0, n_rd = 0, n_rd_chk = 0, n_rd_bad = 0;
static long bus_cycles_vdpx = 0, as_low_vdpx = 0, bus_cycles_other = 0, as_low_other = 0;
static long n_core = 0;
static int max_level = 0; static long n_drop = 0, n_rd_driven = 0;
static uint64_t last_wr_cyc = 0, min_wr_gap = ~0ull; static long n_byte_wr = 0;
static unsigned cyc_addr = 0, cyc_rw = 1, cyc_wdata = 0, cyc_rdata = 0;
static int prev_as = 1;
static bool cur_vdpx = false;

static void save_ppm(const std::string &path, const std::vector<uint8_t> &img) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n640 480\n255\n");
    fwrite(img.data(), 1, img.size(), f);
    fclose(f);
}

static std::string outdir = ".";

static void finish_frame() {
    if (!have_snap) { fprintf(stderr, "frame %d sem snapshot\n", cap_id); errors++; return; }
    auto exp = snap.render();
    long diff = 0; int fx = -1, fy = -1;
    for (int i = 0; i < 640 * 480; i++)
        if (memcmp(&cap[i * 3], &exp[i * 3], 3)) { if (fx < 0) { fx = i % 640; fy = i / 640; } diff++; }
    char name[64]; snprintf(name, sizeof name, "m2wo_frame%02d", cap_id);
    save_ppm(outdir + "/" + name + ".ppm", cap);
    if (diff) {
        save_ppm(outdir + "/" + name + "_esperado.ppm", exp);
        fprintf(stderr, "FRAME %d: %ld pixels diferentes (primeiro em %d,%d)\n", cap_id, diff, fx, fy);
        frames_bad++; errors++;
    } else {
        frames_ok++;
    }
    printf("  frame %2d capturado: %s\n", cap_id, diff ? "DIFERENTE" : "igual ao modelo");
}

static void step() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    cycles++;

    // ---- audio: ADC input (simulated Mega Drive FM/PSG), DAC decode, APU model
    dut->i2s_din = aud.adc_step(dut->i2s_bclk, dut->i2s_lrck);
    aud.dac_step(dut->i2s_bclk, dut->i2s_lrck, dut->i2s_dout);
    if (dut->aud_valid) aud.on_output(ref, dut->aud_wr_applied, (int16_t)dut->aud_l, (int16_t)dut->aud_r);

    // ---- P2: DMA (both models follow the same RTL port writes)
    // the scoreboard runs on the core-side model (it sees the commands in core order); the DMA writes
    // it verified are mirrored into the 68000-side model so that the final state comparison holds
    dchk_core.cycle(dut->dma_events, dut->dbg_vw_we, dut->dbg_vw_dma, dut->dbg_vw_addr, dut->dbg_vw_data, 0);
    if (dut->dbg_vw_dma) ref.vram[dut->dbg_vw_addr & 0x7fff] = dut->dbg_vw_data;
    if ((dut->dma_events >> 22) & 1) dma_t_start = cycles;
    if ((dut->dma_events >> 21) & 1) {
        n_dma_end++;
        if (bench) printf("BENCH dma_fim palavras=%u ciclos_execucao=%llu ciclo=%llu\n", (dut->dma_events >> 4) & 0xFFFF,
                          (unsigned long long)(cycles - dma_t_start), (unsigned long long)cycles);
    }

    // ---- core-side transactions (count + consistency model)
    if (dut->snp_commit) n_core++;
    if (dut->snp_ack) {
        n_core++;
        if (dut->snp_we) ref_core.write(dut->snp_addr, dut->snp_wdata);
        else { uint16_t e; ref_core.read(dut->snp_addr, e); }
    }

    // ---- 68000 side: one transaction per bus cycle in the VDPX window
    int as = dut->cpu_as_n;
    if (prev_as && !as) {
        cur_vdpx = ((dut->cpu_addr << 1) & 0xFFFFF0) == 0xA12000;
        if (cur_vdpx) bus_cycles_vdpx++; else bus_cycles_other++;
        cyc_addr = (dut->cpu_addr & 7);
    }
    if (dut->wo_level > max_level) max_level = dut->wo_level;
    if (dut->wo_drop) n_drop++;
    if (!as) {
        if (cur_vdpx) as_low_vdpx++; else as_low_other++;
        cyc_rw = dut->cpu_rw; cyc_wdata = dut->cpu_wdata; cyc_rdata = dut->cpu_rdata;
    }
    if (!prev_as && as && cur_vdpx) {           // end of a VDPX bus cycle
        if (!cyc_rw) {
            ref.write(cyc_addr, cyc_wdata); n_wr++;
            if (last_wr_cyc && cycles - last_wr_cyc < min_wr_gap) min_wr_gap = cycles - last_wr_cyc;
            last_wr_cyc = cycles;
        } else {
            n_rd++;
            if (cyc_rdata != 0xFFFF) n_rd_driven++;   // alguém dirigiu o barramento numa leitura
        }
    }
    prev_as = as;

    // ---- snapshot of the model when the captured frame's last line has been rendered
    int vbl = dut->vblank;
    if (cap_state == CAP_RUN && !prev_vbl && vbl) { snap = ref; have_snap = true; }
    prev_vbl = vbl;

    // ---- video capture
    if (dut->vid_ce) {
        int de = dut->vid_de, vs = dut->vid_vs_n;
        if (prev_vs == 1 && vs == 0) {
            if (cap_state == CAP_RUN) {
                if (cy == 480 && cap_pixels == 640L * 480) finish_frame();
                else { fprintf(stderr, "frame %d incompleto\n", cap_id); errors++; }
                cap_state = CAP_IDLE;
            } else if (cap_state == CAP_ARMED) {
                cap_state = CAP_RUN; cx = cy = 0; cap_pixels = 0; have_snap = false;
            }
        }
        if (cap_state == CAP_RUN && de) {
            if (cx < 640 && cy < 480) {
                uint8_t *p = &cap[(cy * 640 + cx) * 3];
                p[0] = dut->vid_r; p[1] = dut->vid_g; p[2] = dut->vid_b;
            }
            cx++; cap_pixels++;
        }
        if (cap_state == CAP_RUN && prev_de && !de) { cy++; cx = 0; }
        prev_de = de; prev_vs = vs;
    }
}

int main(int argc, char **argv) {
    if (argc > 1) outdir = argv[1];
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    dut = new Vmd_sim_top(ctx);

    aud.fl = 196; aud.fr = 196; aud.amp = 2500;      // "FM do Mega Drive": sol 196 Hz pelo ADC
    aud.rec = true;
    for (auto *pr : {&ref, &ref_core}) { (void)pr; }
    dchk_core.vram = ref_core.vram; dchk_core.smem = &ref_core.smem; dchk_core.smem_mask = (1u << ref_core.smem_aw) - 1;
    dchk_core.dma = &ref_core.dma;
    dut->rst = 1;
    for (int i = 0; i < 200; i++) step();
    dut->rst = 0;

    bool done = false;
    int selftest = -1;
    const uint64_t limit = (bench ? 200ull : 60ull) * 840000;          // ~60 frames (bench: 200)
    while (!done && cycles < limit) {
        step();
        if (dut->dbg_we) {
            unsigned d = dut->dbg_data;
            switch (d & 0xF000) {
            case 0xC000: printf("[68k] progresso %u (ciclo %llu, frame ~%.1f)\n", d & 0xFF,
                                (unsigned long long)cycles, cycles / 840000.0); break;
            case 0xE000: selftest = d & 0xFFF;
                         printf("[68k] auto-teste de leitura: %d erros\n", selftest);
                         if (selftest) errors++;
                         break;
            case 0x1000:
                if (cap_state != CAP_IDLE) { fprintf(stderr, "captura %u pedida com outra em curso\n", d & 0xFF); errors++; }
                cap_id = d & 0xFF; cap_state = CAP_ARMED; break;
            case 0xB000:   // P2 benchmark markers: 0xBkii (k = point, ii = test index)
                printf("BENCH marca %X teste %u ciclo %llu escritas %ld\n", (d >> 8) & 15, d & 0xFF,
                       (unsigned long long)cycles, n_wr);
                if (((d >> 8) & 15) == 8 && !dchk_core.idle()) {
                    fprintf(stderr, "DMA ainda ocupado quando o 68000 seguiu (espera fixa insuficiente)\n"); errors++;
                }
                break;
            case 0xD000:
                if (d == 0xDEAD) { fprintf(stderr, "[68k] EXCEÇÃO/HALT\n"); errors++; done = true; }
                else { printf("[68k] fim do programa\n"); done = true; }
                break;
            }
        }
    }
    // let a pending capture finish
    uint64_t extra = 0;
    while (cap_state != CAP_IDLE && extra++ < 2000000) step();

    if (!done) { fprintf(stderr, "TIMEOUT: programa não terminou\n"); errors++; }
    if (frames_ok + frames_bad == 0 && !bench) { fprintf(stderr, "nenhum frame capturado\n"); errors++; }
    if (dchk_core.errors) errors++;
    if (n_dma_end || dchk_core.accepted) dchk_core.report(" (núcleo)");

    AudioTB::write_wav(outdir + "/m2wo_audio.wav", aud.rec_buf);
    int txd;
    if (aud.mismatches) errors++;
    if (!aud.check_tx(&txd)) { errors++; fprintf(stderr, "saída I2S diferente do mixer\n"); }
    printf("    áudio: %ld amostras conferidas com o modelo, %ld erradas (gravado em m2wo_audio.wav)\n",
           aud.checked, aud.mismatches);
    if (n_rd_driven) { errors++; fprintf(stderr, "%ld leituras com o barramento dirigido (deveria ficar solto)\n", n_rd_driven); }
    if (n_drop || dut->wo_overflow) { errors++; fprintf(stderr, "FIFO de escrita perdeu %ld palavras\n", n_drop); }
    if (n_core != n_wr) {
        fprintf(stderr, "escritas do 68000 (%ld) != transações no núcleo (%ld)\n", n_wr, n_core); errors++;
    }
    if (memcmp(ref.vram, ref_core.vram, sizeof ref.vram) || memcmp(ref.cram, ref_core.cram, sizeof ref.cram) ||
        memcmp(ref.sat, ref_core.sat, sizeof ref.sat) || memcmp(ref.regs, ref_core.regs, sizeof ref.regs)) {
        fprintf(stderr, "estado visto pelos pinos do 68000 != estado que chegou no núcleo\n"); errors++;
    }
    double avg = bus_cycles_vdpx ? (double)as_low_vdpx / bus_cycles_vdpx : 0;
    double avg_o = bus_cycles_other ? (double)as_low_other / bus_cycles_other : 0;
    printf("M2WO (PREFETCH=%d): %ld escritas e %ld leituras na VDPX pelos pinos do 68000, %ld escritas no núcleo\n",
           M2_PREFETCH_VAL, n_wr, n_rd, n_core);
    printf("    FIFO: nível máximo %d de 16, %ld perdidas; menor intervalo entre escritas %llu ciclos (%.0f ns)\n",
           max_level, n_drop, (unsigned long long)min_wr_gap, min_wr_gap * 1000.0 / CLK_MHZ);
    printf("    %d/%d frames iguais ao modelo\n", frames_ok, frames_ok + frames_bad);
    printf("    /AS baixo: VDPX %.0f ns em média, ROM/RAM sem wait state %.0f ns -> ~%.2f wait states por acesso\n",
           avg * 1000.0 / CLK_MHZ, avg_o * 1000.0 / CLK_MHZ, (avg - avg_o) / (CLK_MHZ / 7.67));
    printf("    %llu ciclos simulados (%.2f frames) -> %s\n", (unsigned long long)cycles,
           cycles / 840000.0, errors ? "FALHOU" : "OK");
    dut->final();
    delete dut; delete ctx;
    return errors ? 1 : 0;
}
