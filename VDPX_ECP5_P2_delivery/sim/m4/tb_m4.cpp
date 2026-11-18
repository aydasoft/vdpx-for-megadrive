// M4 board simulation: self-test script -> VDPX -> SDRAM/APU -> HDMI (TMDS).
// The TMDS symbols are decoded by an HDMI sink model; decoded frames and audio
// are compared with the reference models fed from the VDPX internal bus.
#include "Vboard_sim.h"
#include "verilated.h"
#include "../refmodel.h"
#include "../audio_tb.h"
#include "hdmi_dec.h"
#include "vdpx_overlay_tb.h"
#include <map>
#include <cstdio>
#include <string>
#include <cstdlib>

static Vboard_sim *dut;
static RefVDPX ref;
static AudioTB aud;
static HdmiDec hd;
static DmaCheck dchk;
#define DMA_EXP_ST "IDLE"            // Tang build: P1 self-test, no DMA command
#define DMA_EXP_OP "----"
#define DMA_EXP_W  0
static int errors = 0;

// ---- 68000 bus cycles on the CN2 pins (sys-clock units of 19.84 ns).
// One zero-wait 68000 cycle at 7.67 MHz = 4 clocks = 26 sys cycles:
//   /FDC (and /CAS0 for reads) low from t=3 to t=20, /FDWR low for 7 sys clocks (~139 ns), supplemented by asynchronous M4.2 sweep
//   (data strobes come one 68000 clock after /AS), read data sampled at t=19.
struct MdOp { bool wr; int a; uint16_t d; };
static std::vector<MdOp> md_ops;
static size_t md_pc = 0;
static int md_t = -1, md_gap = 0;
static uint16_t md_rd = 0;
static int md_sample = getenv("MD_SAMPLE") ? atoi(getenv("MD_SAMPLE")) : 19;
static long md_reads = 0, md_bad = 0, md_writes = 0, md_applied = 0;
static std::vector<std::pair<int,uint16_t>> md_rd_log;   // (addr, value seen at the pins)
// ---- OCR of the diagnostic overlay (exact glyph match on the decoded HDMI frame)
static std::vector<uint8_t> ovl_frame;
static std::string ocr_row(const std::vector<uint8_t> &f, int row) {
    std::string out;
    for (int col = 0; col < 40; col++) {
        uint8_t g[8] = {0};
        for (int y = 0; y < 8; y++)
            for (int x = 0; x < 8; x++) {
                const uint8_t *p = &f[(((OVL_TOP + row) * 16 + y * 2) * 640 + col * 16 + x * 2) * 3];
                if (p[0] > 0xC0) g[y] |= 0x80 >> x;          // text is white or yellow, box is dark
            }
        char c = '#';
        for (size_t k = 0; k < sizeof(OVL_FONT) / 8; k++)
            if (!memcmp(g, OVL_FONT[k], 8)) { c = OVL_CHARS[k]; break; }
        out += c;
    }
    return out;
}
static bool ovl_field(const std::vector<uint8_t> &f, const char *name, long *val, std::string *raw) {
    for (const auto &fd : OVL_FIELDS) {
        if (strcmp(fd.name, name)) continue;
        std::string r = ocr_row(f, fd.row).substr(fd.col, fd.ndig);
        *raw = r;
        if (fd.kind[0] == 'f') { *val = (r == "S"); return r == "S" || r == "N"; }
        if (fd.kind[0] == 'e') { *val = 0; return true; }        // P2 enumerated text: compare raw
        char *end;
        *val = strtol(r.c_str(), &end, fd.kind[0] == 'h' ? 16 : 10);
        return *end == 0;
    }
    return false;
}

static void md_build() {
    if (getenv("M42_SELFTEST_ONLY")) return;
    auto W = [](int a, uint16_t d) { md_ops.push_back({true, a, d}); };
    auto R = [](int a) { md_ops.push_back({false, a, 0}); };
    R(6);                                  // ID
    W(2, 1); W(3, 0x0003); R(3);           // BGCOLOR = 3, read back
    W(2, 12); W(3, 1); W(2, 13); W(3, 1); W(2, 14); W(3, 1);
    W(0, 0x7C00); W(0, 0x03E0); W(0, 0x001F);   // CRAM[1..3] = red, green, blue
    W(2, 13); W(3, 0);
    for (int i = 0; i < 6; i++) R(0);      // read CRAM[0..5] back (prefetch path)
    R(1);                                  // STATUS
    W(2, 12); W(3, 0); W(2, 13); W(3, 0x0010);
    for (int i = 0; i < 4; i++) R(0);      // VRAM reads
    W(2, 5); W(3, 0x0007); R(2); R(3);
}

static void save_ppm(const std::string &path, const std::vector<uint8_t> &img) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n640 480\n255\n");
    fwrite(img.data(), 1, img.size(), f);
    fclose(f);
}

int main(int argc, char **argv) {
    std::string outdir = argc > 1 ? argv[1] : ".";
    int nframes = argc > 2 ? atoi(argv[2]) : 40;
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    dut = new Vboard_sim(ctx);

    dut->md_fdc_n = 1; dut->md_fdwr_n = 1; dut->md_cas0_n = 1; dut->md_fres = 0; dut->md_a = 0; dut->md_d_in = 0;
    md_build();
    dut->selftest_btn = 0;
    dut->rst_btn = 1;
    aud.fl = 196; aud.fr = 294; aud.amp = 3000;     // "som do Mega Drive" entrando pelo ADC
    aud.rec = true;

    std::vector<RefVDPX> snaps;     // model snapshot at each VDPX vblank start
    int prev_vbl = 0, frames_cmp = 0, frames_ok = 0;
    uint64_t sys_cycles = 0;
    const uint64_t max_cycles = (uint64_t)(nframes + 2) * 840000;

    // time unit = 1/4 system period; sys toggles every 2 units, pix every 4 units (offset 1)
    for (uint64_t u = 0; sys_cycles < max_cycles; u++) {
        bool sys_edge = false, pix_edge = false;
        if (u % 2 == 0) { dut->clk_sys = !dut->clk_sys; sys_edge = dut->clk_sys; }
        if (u % 4 == 1) { dut->clk_pix = !dut->clk_pix; pix_edge = dut->clk_pix; }
        if (!sys_edge && !pix_edge && (u % 2) && (u % 4 != 1)) continue;
        dut->eval();
        if (sys_edge) {
            sys_cycles++;
            if (sys_cycles == 50) dut->rst_btn = 0;
            // VDPX internal bus -> reference model (self-test script)
            if (dut->dbg_core_ack) {
                if ((dut->leds & 2) && !(dut->leds & 1) && dut->dbg_core_we) md_applied++;
                if (dut->dbg_core_we) ref.write(dut->dbg_core_addr, dut->dbg_core_wdata);
                else { uint16_t e; ref.read(dut->dbg_core_addr, e); }
            }
            // reads completed by the adapter: advance the model and compare
            if (dut->md_d_oe || dut->dbg_commit) { errors++; fprintf(stderr, "write-only violation\n"); }
            if (!dchk.dma) { dchk.vram = ref.vram; dchk.smem = &ref.smem; dchk.smem_mask = (1u << ref.smem_aw) - 1; dchk.dma = &ref.dma; ref.dma.smem_aw = 22; }
            dchk.cycle(dut->dbg_dma_events, dut->dbg_vw_we, dut->dbg_vw_dma, dut->dbg_vw_addr, dut->dbg_vw_data, 0);
            if (dut->dbg_commit) {
                uint16_t e;
                bool det = ref.read(dut->dbg_commit_addr, e);
                md_reads++;
                if (md_rd_log.empty()) { errors++; fprintf(stderr, "commit sem leitura nos pinos\n"); }
                else {
                    auto rv = md_rd_log.front(); md_rd_log.erase(md_rd_log.begin());
                    if (rv.first != dut->dbg_commit_addr) { errors++; fprintf(stderr, "endereço de leitura trocado\n"); }
                    if (det && rv.second != e) {
                        md_bad++; errors++;
                        fprintf(stderr, "leitura MD a=%d pinos=%04x modelo=%04x\n", rv.first, rv.second, e);
                    }
                }
            }
            // drive the CN2 pins (starts after HDMI frame 12)
            if (hd.frames_done >= 12 && md_pc < md_ops.size()) {
                if (md_t < 0) { if (md_gap > 0) md_gap--; else md_t = 0; }
                if (md_t >= 0) {
                    const MdOp &op = md_ops[md_pc];
                    dut->md_a = op.a;
                    dut->md_fdc_n  = !(md_t >= 3 && md_t <= 20);
                    dut->md_cas0_n = !(!op.wr && md_t >= 3 && md_t <= 20);
                    dut->md_fdwr_n = !(op.wr && md_t >= 14 && md_t <= 20);
                    dut->md_d_in = op.wr ? op.d : 0xFFFF;
                    if (!op.wr && md_t == md_sample) {
                        md_rd = dut->md_d_oe ? dut->md_d_out : 0xFFFF;   // 74LVC245 + pull-ups
                        if (md_rd != 0xFFFF) { errors++; } // reads must stay undriven
                    }
                    if (++md_t == 26) {
                        if (op.wr) md_writes++;
                        md_t = -1; md_gap = 30; md_pc++;
                    }
                }
            }
            int vbl = dut->dbg_vblank;
            if (!prev_vbl && vbl) { snaps.push_back(ref); if (snaps.size() > 3) snaps.erase(snaps.begin()); }
            prev_vbl = vbl;
            dut->i2s_din = aud.adc_step(dut->i2s_bclk, dut->i2s_lrck);
            aud.dac_step(dut->i2s_bclk, dut->i2s_lrck, dut->i2s_dout);
            if (dut->dbg_aud_valid) aud.on_output(ref, dut->dbg_aud_wr_applied, (int16_t)dut->dbg_aud_l, (int16_t)dut->dbg_aud_r);
        }
        if (pix_edge) {
            hd.symbol(dut->tmds0, dut->tmds1, dut->tmds2);
            if (hd.frame_ready) {
                hd.frame_ready = false;
                int fno = hd.frames_done;
                if (fno >= 3 && (fno % 8 == 3 || fno == nframes) && !snaps.empty()) {
                    auto exp = snaps.back().render();
                    long diff = 0;
                    // the diagnostic overlay covers text rows OVL_TOP.. (checked separately by OCR)
                    size_t lim = dut->dbg_overlay_on ? (size_t)OVL_TOP * 16 * 640 * 3 : exp.size();
                    for (size_t i = 0; i < lim; i += 3)
                        if (memcmp(&exp[i], &hd.last_frame[i], 3)) diff++;
                    if (fno == nframes) ovl_frame = hd.last_frame;
                    char name[64]; snprintf(name, sizeof name, "%s/m4_hdmi_frame%02d.ppm", outdir.c_str(), fno);
                    save_ppm(name, hd.last_frame);
                    frames_cmp++;
                    if (diff) {
                        fprintf(stderr, "frame HDMI %d: %ld pixels diferentes\n", fno, diff);
                        errors++;
                        save_ppm(std::string(name) + "_esperado.ppm", exp);
                    } else frames_ok++;
                    printf("  frame %2d decodificado do HDMI: %s\n", fno, diff ? "DIFERENTE" : "igual ao modelo");
                }
            }
        }
    }

    // audio carried over HDMI must equal the mixer output (contiguous, after lock)
    long hm = 0, off = -1;
    if (!hd.aud_l.empty()) {
        for (size_t o = 0; o < aud.out_l.size(); o++)
            if (aud.out_l[o] == hd.aud_l[0] && aud.out_r[o] == hd.aud_r[0]) {
                bool ok = true;
                for (size_t i = 0; i < hd.aud_l.size() && o + i < aud.out_l.size(); i++)
                    if (aud.out_l[o + i] != hd.aud_l[i] || aud.out_r[o + i] != hd.aud_r[i]) { ok = false; break; }
                if (ok) { off = o; break; }
            }
        if (off < 0) { errors++; fprintf(stderr, "áudio do HDMI não bate com a saída do mixer\n"); }
        else hm = hd.aud_l.size();
    }
    AudioTB::write_wav(outdir + "/m4_hdmi_audio.wav",
        [&]{ std::vector<int16_t> v; for (size_t i = 0; i < hd.aud_l.size(); i++) { v.push_back(hd.aud_l[i]); v.push_back(hd.aud_r[i]); } return v; }());
    int txd;
    if (aud.mismatches) errors++;
    if (!aud.check_tx(&txd)) { errors++; fprintf(stderr, "I2S diferente do mixer\n"); }
    if (hd.errors) errors++;
    if (dut->sdram_errors) { errors++; fprintf(stderr, "SDRAM: %u erros de protocolo/timing\n", dut->sdram_errors); }
    if (dchk.errors || dchk.accepted) { errors++; fprintf(stderr, "DMA inesperado no autoteste da Tang\n"); }
    if (hd.acr_n != 6144 || hd.acr_cts != 25200) { errors++; fprintf(stderr, "ACR N/CTS errado: %d/%d\n", hd.acr_n, hd.acr_cts); }
    if (hd.avi_vic != 1) { errors++; fprintf(stderr, "AVI VIC errado: %d\n", hd.avi_vic); }
    if (md_applied != md_writes) { errors++; fprintf(stderr, "MD writes issued=%ld applied=%ld\n", md_writes, md_applied); }
    if (md_pc != md_ops.size()) { errors++; fprintf(stderr, "ciclos do MD não terminaram\n"); }
    if (dut->dbg_late_read) { errors++; fprintf(stderr, "leitura do MD respondida tarde\n"); }
    if (!getenv("M42_SELFTEST_ONLY") && (!(dut->leds & 2) || (dut->leds & 1))) { errors++; fprintf(stderr, "o autoteste não cedeu lugar ao MD\n"); }
    if (getenv("M42_SELFTEST_ONLY") && (!(dut->leds & 1) || (dut->leds & 2))) { errors++; fprintf(stderr, "autoteste independente inativo\n"); }
    printf("    porta de expansão: %ld escritas e %ld commits (write-only; leituras ignoradas), %ld erradas\n", md_writes, md_reads, md_bad);
    if (frames_cmp == 0) { errors++; fprintf(stderr, "nenhum frame comparado\n"); }
    if (hm < 1000) { errors++; fprintf(stderr, "poucas amostras de áudio no HDMI: %ld\n", hm); }
    if (!(dut->leds & 4)) { errors++; fprintf(stderr, "SDRAM não ficou pronta\n"); }
    if (!(dut->leds & 16)) { errors++; fprintf(stderr, "HDMI não travou nas sincronias\n"); }
    if (dut->leds & 8) { errors++; fprintf(stderr, "FIFO de vídeo esvaziou\n"); }

    // ---- overlay / CN2 probe: values read from the HDMI image must match what the TB applied
    if (!getenv("M42_SELFTEST_ONLY")) {
        if (ovl_frame.empty()) { errors++; fprintf(stderr, "overlay não capturado\n"); }
        else {
            for (int r = 0; r < 9; r++) printf("    HDMI| %s\n", ocr_row(ovl_frame, r).c_str());
            struct Exp { const char *n; long lo, hi; };
            // CN2 drive: /FDC low 18 ticks, /FDWR low 7 ticks starting 11 ticks after /FDC,
            // reads with /CAS0 together with /FDC; 19 writes, 15 reads (see md_build)
            Exp ex[] = {{"st", 0, 0}, {"md", 1, 1}, {"n_acc", 19, 19}, {"n_drop", 0, 0},
                        {"fifo_hw", 1, 2}, {"last_off", 6, 6}, {"last_d", 7, 7},
                        {"n_wr", 19, 19}, {"n_wr_cas0", 0, 0}, {"n_rd", 15, 15}, {"n_rd_cas0", 15, 15},
                        {"fdcw_min", 17, 19}, {"fdcw_max", 17, 19}, {"fdcr_min", 17, 19}, {"fdcr_max", 17, 19},
                        {"f2w_min", 10, 12}, {"f2w_max", 10, 12}, {"ww_min", 6, 8}, {"ww_max", 6, 8},
                        {"f2c_min", 0, 1}, {"f2c_max", 0, 1}, {"fres_now", 0, 0}, {"n_fres", 0, 0},
                        {"n_cas_out", 0, 0}};
            int ok = 0;
            for (auto &e : ex) {
                long v; std::string raw;
                if (!ovl_field(ovl_frame, e.n, &v, &raw) || v < e.lo || v > e.hi) {
                    errors++;
                    fprintf(stderr, "overlay %s = '%s' (esperado %ld..%ld)\n", e.n, raw.c_str(), e.lo, e.hi);
                } else ok++;
            }
            printf("    overlay: %d/%d campos lidos do HDMI conferem com os sinais aplicados no CN2\n", ok,
                   (int)(sizeof ex / sizeof ex[0]));
            // P2: DMA rows of the panel (state/op text, counters, rate = words*1000/cycles in BCD)
            {
                long w, c, ri, rf, q, er; std::string rs, ro, raw;
                bool ok2 = ovl_field(ovl_frame, "dma_st", &w, &rs) && ovl_field(ovl_frame, "dma_op", &w, &ro) &&
                           ovl_field(ovl_frame, "dma_w", &w, &raw) && ovl_field(ovl_frame, "dma_cyc", &c, &raw) &&
                           ovl_field(ovl_frame, "dma_ri", &ri, &raw) && ovl_field(ovl_frame, "dma_rf", &rf, &raw) &&
                           ovl_field(ovl_frame, "dma_q", &q, &raw) && ovl_field(ovl_frame, "dma_err", &er, &raw);
                long exp_rate = c ? w * 1000 / c : 0;
                long got_rate = (ri >> 8) * 1000 + ((ri >> 4) & 15) * 100 + (ri & 15) * 10 + rf;   // BCD digits read as hex
                bool good = ok2 && rs == DMA_EXP_ST && ro == DMA_EXP_OP && w == DMA_EXP_W && q == 0 && er == 0 &&
                            got_rate == exp_rate && (DMA_EXP_W == 0 || c > 0);
                printf("    painel DMA: %s %s palavras %ld ciclos %ld taxa %ld.%ld MB/s (esperado %ld.%ld) fila %ld erros %ld -> %s\n",
                       rs.c_str(), ro.c_str(), w, c, got_rate / 10, got_rate % 10, exp_rate / 10, exp_rate % 10, q, er,
                       good ? "OK" : "ERRADO");
                if (!good) errors++;
            }
            save_ppm(outdir + "/m42_overlay.ppm", ovl_frame);
        }
    }

    printf("M4: %d/%d frames do HDMI iguais ao modelo; %ld amostras de áudio no HDMI iguais ao mixer "
           "(%ld conferidas com o modelo da APU, %ld erradas)\n", frames_ok, frames_cmp, hm, aud.checked, aud.mismatches);
    printf("    pacotes: %ld (áudio %ld, ACR %ld N=%d CTS=%d, AVI %ld VIC=%d, Audio IF %ld, nulos %ld), erros HDMI %ld, SDRAM %u\n",
           hd.n_pkts, hd.n_audio_pkts, hd.n_acr, hd.acr_n, hd.acr_cts, hd.n_avi, hd.avi_vic, hd.n_aif, hd.n_null,
           hd.errors, dut->sdram_errors);
    printf("    LEDs: autoteste=%d MD=%d SDRAM=%d FIFO_erro=%d HDMI_travado=%d áudio_ovf=%d; %llu ciclos -> %s\n",
           dut->leds & 1, (dut->leds >> 1) & 1, (dut->leds >> 2) & 1, (dut->leds >> 3) & 1, (dut->leds >> 4) & 1,
           (dut->leds >> 5) & 1, (unsigned long long)sys_cycles, errors ? "FALHOU" : "OK");
    dut->final();
    delete dut; delete ctx;
    return errors ? 1 : 0;
}
