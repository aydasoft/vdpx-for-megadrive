// ECP5-P1 board simulation (Colorlight i9 + Ext-Board, everything except the PLL and pads):
// self-test script -> VDPX -> SDRAM (RMW, no DQM) / APU -> HDMI -> TMDS serializer (ODDRX1F).
//
// Unlike tb_m4 (which takes the 10-bit symbols before the serializer), this testbench only
// sees the 4 pad outputs: it samples them every half period of the 125 MHz clock,
// deserializes them with the TMDS clock lane (sim/ecp5/tmds_deser.h) and feeds the HDMI sink
// model with the recovered symbols. Frames, audio packets, ACR, InfoFrames and the CN2 probe
// panel (OCR) are checked on that recovered stream. The serial symbols are also compared
// one by one with the transmitter's parallel symbols (fixed latency, all lanes).
//
// Clocks: 2 ns grid. clk_x5 125 MHz toggles every 2 steps, clk_sys 50 MHz every 5, clk_pix
// 25 MHz every 10; all rising edges coincide at t = 0 mod 40 ns (as the EHXPLLL outputs).
//
// Environment:
//   M42_SELFTEST_ONLY=1  no CN2 traffic (self-test alone, as with nothing on the CN2)
//   ECP5_LOCKLOSS=1      PLL lock is lost after HDMI frame 8 for 2000 system cycles; the
//                        decoder and the model registers restart, and the frames after the
//                        recovery must match again (self-test only, audio not compared)
#include "Vecp5_board_sim.h"
#include "verilated.h"
#include "../refmodel.h"
#include "../audio_tb.h"
#include "../m4/hdmi_dec.h"
#include "../m4/vdpx_overlay_tb.h"
#include "tmds_deser.h"
#include <map>
#include <cstdio>
#include <string>
#include <cstdlib>
#include <cstring>

static Vecp5_board_sim *dut;
static RefVDPX ref;
static AudioTB aud;
static HdmiDec *hd;
static DmaCheck dchk;                 // P2: DMA scoreboard
#define DMA_EXP_ST "DONE"            // self-test ends with COPY of 32 words (animation frame)
#define DMA_EXP_OP "COPY"
#define DMA_EXP_W  32
static int errors = 0;

struct MdOp { bool wr; int a; uint16_t d; };
static std::vector<MdOp> md_ops;
static size_t md_pc = 0;
static int md_t = -1, md_gap = 0;
static long md_writes = 0, md_applied = 0, md_reads = 0;

static std::vector<uint8_t> ovl_frame;
static std::string ocr_row(const std::vector<uint8_t> &f, int row) {
    std::string out;
    for (int col = 0; col < 40; col++) {
        uint8_t g[8] = {0};
        for (int y = 0; y < 8; y++)
            for (int x = 0; x < 8; x++) {
                const uint8_t *p = &f[(((OVL_TOP + row) * 16 + y * 2) * 640 + col * 16 + x * 2) * 3];
                if (p[0] > 0xC0) g[y] |= 0x80 >> x;
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

// same CN2 program as tb_m4 (19 writes, 15 reads that must stay undriven)
static void md_build() {
    if (getenv("M42_SELFTEST_ONLY") || getenv("ECP5_LOCKLOSS")) return;
    auto W = [](int a, uint16_t d) { md_ops.push_back({true, a, d}); };
    auto R = [](int a) { md_ops.push_back({false, a, 0}); };
    R(6);
    W(2, 1); W(3, 0x0003); R(3);
    W(2, 12); W(3, 1); W(2, 13); W(3, 1); W(2, 14); W(3, 1);
    W(0, 0x7C00); W(0, 0x03E0); W(0, 0x001F);
    W(2, 13); W(3, 0);
    for (int i = 0; i < 6; i++) R(0);
    R(1);
    W(2, 12); W(3, 0); W(2, 13); W(3, 0x0010);
    for (int i = 0; i < 4; i++) R(0);
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
    const bool selftest_only = getenv("M42_SELFTEST_ONLY") != nullptr;
    const bool lockloss = getenv("ECP5_LOCKLOSS") != nullptr;
    const bool init_glitch = getenv("ECP5_INIT_GLITCH") != nullptr;
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    dut = new Vecp5_board_sim(ctx);
    hd = new HdmiDec;

    dut->md_fdc_n = 1; dut->md_fdwr_n = 1; dut->md_cas0_n = 1; dut->md_fres = 0; dut->md_a = 0; dut->md_d = 0;
    md_build();
    dut->pll_locked = 0;
    dut->clk_sd = 1;      // toggles at 6, 16, 26 ns...: rising edges at 16 + 20k ns (288 deg after clk_sys)
    dut->sdram_ref_relaxed = lockloss;   // a 2000-cycle reset has no refresh: JEDEC limit applies
    aud.fl = 196; aud.fr = 294; aud.amp = init_glitch ? 0 : 3000;   // glitch run: silent ADC (see below)
    aud.rec = true;
    bool prev_lock = false;
    uint64_t aud_first = 0, aud_last = 0; long aud_n = 0;   // mixer output rate (50 MHz clock)
    long n_core_resets = 0;

    dchk.vram = ref.vram; dchk.smem = &ref.smem; dchk.smem_mask = (1u << ref.smem_aw) - 1;
    dchk.dma = &ref.dma; ref.dma.smem_aw = 22;
    TmdsDeser des;
    SerParCheck spc;
    std::vector<RefVDPX> snaps;
    int prev_vbl = 0, frames_cmp = 0, frames_ok = 0, frames_after_loss = 0;
    uint64_t sys_cycles = 0, x5_edges = 0;
    const uint64_t max_cycles = (uint64_t)(nframes + 2) * 840000 + (lockloss ? 2000 : 0);
    long lock_events = 0;
    bool in_loss = false, decode_on = true;
    uint64_t loss_start = 0, loss_end = 0, relock_at = 0;
    long hd_err_before = 0;
    int frames_before = 0;
    long audio_samples_frames0 = -1; int audio_frame0 = -1;

    // reset sequence: lock low for 40 cycles, then high; lock glitch during SDRAM init
    // (cycles 150..169: the controller is in its 200-cycle power-up wait); normal from 170.
    // ---- board model of the SDRAM read path (2 ns grid). The model's data is valid from its
    // clock edge N+1 to N+2 (zero delay). At the FPGA flip-flops it is valid from
    //   N+1 + tOC + tAC + tIN_max  (3.5 + 8 + 7  -> 20 ns, rounded up)
    // to N+2 + tOC + tOH + tIN_min (3.5 + 2 + 1  ->  6 ns, rounded down)
    // tAC/tOH: M12L64322A grade -7 (worst listed), CL2. tOC: ODDRX1F + LVCMOS33 output and
    // board; tIN: input buffer + longest/shortest routing from nextpnr (see SDRAM_32BIT_REPORT).
    const int D_START = getenv("ECP5_DSTART") ? atoi(getenv("ECP5_DSTART")) : 10;   // in 2 ns steps
    const int D_END   = getenv("ECP5_DEND")   ? atoi(getenv("ECP5_DEND"))   : 3;
    long long drv_rise = -1000000, drv_fall = -1000000; uint32_t drv_data = 0; int prev_drv = 0;
    for (uint64_t u = 0; sys_cycles < max_cycles; u++) {
        bool x5_tog = (u % 2 == 0), sys_tog = (u % 5 == 0), pix_tog = (u % 10 == 0), sd_tog = (u % 5 == 3);
        // board delay model, evaluated every 2 ns step
        {
            long long uu = (long long)u;
            // current/last drive interval [drv_rise, drv_fall) of the model, shifted by the board
            long long end = prev_drv ? (1LL << 62) : (drv_fall > drv_rise ? drv_fall + D_END : -1);
            uint32_t v = (uu >= drv_rise + D_START && uu < end) ? drv_data : 0xDEADBEEF;
            if (dut->sd_dq_board != v) { dut->sd_dq_board = v; if (!x5_tog && !sys_tog && !pix_tog && !sd_tog) dut->eval(); }
        }
        if (!x5_tog && !sys_tog && !pix_tog && !sd_tog) continue;
        if (x5_tog) dut->clk_x5 = !dut->clk_x5;
        if (sys_tog) dut->clk_sys = !dut->clk_sys;
        if (pix_tog) dut->clk_pix = !dut->clk_pix;
        if (sd_tog) dut->clk_sd = !dut->clk_sd;      // clk_sd = clk_sys delayed by 16 ns (8 steps)
        bool sys_edge = sys_tog && dut->clk_sys, pix_edge = pix_tog && dut->clk_pix;
        dut->eval();
        if (dut->mem_drv && !prev_drv) { drv_rise = (long long)u; drv_data = dut->mem_dq; }
        if (!dut->mem_drv && prev_drv) drv_fall = (long long)u;
        prev_drv = dut->mem_drv;

        // ---- pads: one bit per lane per 125 MHz half period
        if (x5_tog) {
            x5_edges++;
            if (decode_on && sys_cycles >= 200 && des.bit(dut->tmds_q & 1, (dut->tmds_q >> 1) & 1, (dut->tmds_q >> 2) & 1, (dut->tmds_q >> 3) & 1)) {
                spc.on_serial(des.out);
                hd->symbol(des.out[0], des.out[1], des.out[2]);
                if (hd->frame_ready) {
                    hd->frame_ready = false;
                    int fno = hd->frames_done;
                    if (audio_frame0 < 0 && fno >= 4) { audio_frame0 = fno; audio_samples_frames0 = hd->aud_l.size(); }
                    bool cmp = lockloss ? (fno >= 3 && !snaps.empty())
                                        : (fno >= 3 && (fno % 8 == 3 || fno == nframes) && !snaps.empty());
                    if (cmp) {
                        auto exp = snaps.back().render();
                        long diff = 0;
                        size_t lim = dut->dbg_overlay_on ? (size_t)OVL_TOP * 16 * 640 * 3 : exp.size();
                        for (size_t i = 0; i < lim; i += 3)
                            if (memcmp(&exp[i], &hd->last_frame[i], 3)) diff++;
                        if (fno == nframes) ovl_frame = hd->last_frame;
                        char name[96];
                        snprintf(name, sizeof name, "%s/ecp5%s_hdmi_frame%02d.ppm", outdir.c_str(),
                                 lockloss ? "_lockloss" : (selftest_only ? "_selftest" : ""), fno);
                        if (fno % 8 == 3 || fno == nframes) save_ppm(name, hd->last_frame);
                        frames_cmp++;
                        if (lock_events) frames_after_loss++;
                        if (diff) {
                            fprintf(stderr, "frame HDMI (serial) %d: %ld pixels diferentes\n", fno, diff);
                            errors++;
                            save_ppm(std::string(name) + "_esperado.ppm", exp);
                        } else frames_ok++;
                        printf("  frame %2d decodificado do TMDS serial: %s\n", fno, diff ? "DIFERENTE" : "igual ao modelo");
                    }
                    if (lockloss && fno == 8 && !lock_events && !in_loss) {
                        in_loss = true; loss_start = sys_cycles; loss_end = sys_cycles + 2000;
                    }
                }
            }
        }
        if (pix_edge) spc.on_parallel(dut->dbg_tmds0, dut->dbg_tmds1, dut->dbg_tmds2);

        if (sys_edge) {
            sys_cycles++;
            // ---- PLL lock / reset sequence
            bool lock = sys_cycles >= 40 && (!init_glitch || !(sys_cycles >= 150 && sys_cycles < 170));
            if (in_loss) {
                lock = false;
                if (sys_cycles == loss_start + 1) {
                    decode_on = false;                         // receiver sees garbage while unlocked
                    hd_err_before = hd->errors; frames_before = hd->frames_done;
                }
                if (sys_cycles >= loss_end) {
                    in_loss = false; lock_events++; relock_at = sys_cycles;
                    snaps.clear();
                }
            }
            if (prev_lock && !lock) {
                // lock lost: the core resets now (asynchronously). Registers of the reference
                // model go to their reset values, memories stay; the APU model follows the RTL.
                memset(ref.regs, 0, sizeof ref.regs); ref.regs[RefVDPX::INC] = 1; ref.reg_sel = 0;
                if (!lockloss) aud.on_core_reset(ref, dut->dbg_aud_wr_applied);
                ref.dma.reset(); dchk.queued.clear(); dchk.running = false;   // DMA state is reset too
                n_core_resets++;
            }
            prev_lock = lock;
            dut->pll_locked = lock;
            if (lock_events && !decode_on && sys_cycles == relock_at + 100) {
                delete hd; hd = new HdmiDec; des.reset(); spc = SerParCheck(); decode_on = true;
            }

            if (dut->dbg_core_ack) {
                if ((dut->leds & 2) && !(dut->leds & 1) && dut->dbg_core_we) md_applied++;
                if (dut->dbg_core_we) ref.write(dut->dbg_core_addr, dut->dbg_core_wdata);
                else { uint16_t e; ref.read(dut->dbg_core_addr, e); }
            }
            if (dut->dbg_md_d_oe || dut->dbg_commit) { errors++; fprintf(stderr, "write-only violation\n"); }
            dchk.cycle(dut->dbg_dma_events, dut->dbg_vw_we, dut->dbg_vw_dma, dut->dbg_vw_addr, dut->dbg_vw_data, 0);
            // CN2 cycles (as tb_m4, in 20 ns system clocks)
            if (hd->frames_done >= 12 && md_pc < md_ops.size()) {
                if (md_t < 0) { if (md_gap > 0) md_gap--; else md_t = 0; }
                if (md_t >= 0) {
                    const MdOp &op = md_ops[md_pc];
                    dut->md_a = op.a;
                    dut->md_fdc_n  = !(md_t >= 3 && md_t <= 20);
                    dut->md_cas0_n = !(!op.wr && md_t >= 3 && md_t <= 20);
                    dut->md_fdwr_n = !(op.wr && md_t >= 14 && md_t <= 20);
                    dut->md_d = op.wr ? op.d : 0xFFFF;
                    if (!op.wr && md_t == 19) md_reads++;
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
            if (dut->dbg_aud_valid && sys_cycles > 20000) { if (!aud_n) aud_first = sys_cycles; aud_last = sys_cycles; aud_n++; }
            if (getenv("DBG_AUD") && dut->dbg_aud_valid && aud.out_l.size() < 4)
                fprintf(stderr, "dbg: cyc %llu out (%d,%d) wr_applied %u log %zu applied %zu base %zu\n", (unsigned long long)sys_cycles,
                        (int16_t)dut->dbg_aud_l, (int16_t)dut->dbg_aud_r, dut->dbg_aud_wr_applied, ref.apu_log.size(), aud.applied, aud.applied_base);
            if (!lockloss && dut->dbg_aud_valid)
                aud.on_output(ref, dut->dbg_aud_wr_applied, (int16_t)dut->dbg_aud_l, (int16_t)dut->dbg_aud_r);
        }
    }

    // ---- audio carried over HDMI = mixer output (contiguous)
    long hm = 0;
    if (!lockloss) {
        long off = -1;
        if (!hd->aud_l.empty()) {
            for (size_t o = 0; o < aud.out_l.size(); o++)
                if (aud.out_l[o] == hd->aud_l[0] && aud.out_r[o] == hd->aud_r[0]) {
                    bool ok = true;
                    for (size_t i = 0; i < hd->aud_l.size() && o + i < aud.out_l.size(); i++)
                        if (aud.out_l[o + i] != hd->aud_l[i] || aud.out_r[o + i] != hd->aud_r[i]) { ok = false; break; }
                    if (ok) { off = o; break; }
                }
            if (off < 0) { errors++; fprintf(stderr, "áudio do HDMI não bate com a saída do mixer\n"); }
            else hm = hd->aud_l.size();
        }
        AudioTB::write_wav(outdir + std::string("/ecp5") + (selftest_only ? "_selftest" : "") + "_hdmi_audio.wav",
            [&]{ std::vector<int16_t> v; for (size_t i = 0; i < hd->aud_l.size(); i++) { v.push_back(hd->aud_l[i]); v.push_back(hd->aud_r[i]); } return v; }());
        int txd;
        if (aud.mismatches) errors++;
        if (!aud.check_tx(&txd)) { errors++; fprintf(stderr, "I2S diferente do mixer\n"); }
        if (hm < 1000) { errors++; fprintf(stderr, "poucas amostras de áudio no HDMI: %ld\n", hm); }
    }
    // audio rate seen by the sink: 48000 / (25e6 / (800*525)) = 806.4 samples per frame
    double spf = 0;
    if (audio_frame0 > 0 && hd->frames_done > audio_frame0 + 4) {
        spf = (double)(hd->aud_l.size() - audio_samples_frames0) / (hd->frames_done - audio_frame0);
        if (!lockloss && (spf < 806.4 * 0.99 || spf > 806.4 * 1.01)) { errors++; fprintf(stderr, "taxa de áudio %.2f amostras/frame\n", spf); }
    }

    // mixer rate: (aud_n - 1) samples between aud_first and aud_last at 50 MHz
    double fs = aud_n > 1 ? (aud_n - 1) * 50e6 / (double)(aud_last - aud_first) : 0;
    if (fs < 47990 || fs > 48010) { errors++; fprintf(stderr, "taxa do mixer %.2f Hz\n", fs); }
    printf("    mixer: %ld amostras, taxa medida %.3f Hz (clock de 50 MHz, quadro I2S 3125/3 ciclos)\n", aud_n, fs);
    // ---- link checks
    if (hd->errors) { errors++; fprintf(stderr, "decodificador HDMI: %ld erros\n", hd->errors); }
    if (des.misalign || des.bad_clock) { errors++; fprintf(stderr, "TMDS serial: %ld símbolos desalinhados, %ld clocks errados\n", des.misalign, des.bad_clock); }
    if (spc.lat < 0 || spc.mismatches) { errors++; fprintf(stderr, "serial x paralelo: latência %d, %ld diferenças\n", spc.lat, spc.mismatches); }
    if (dut->sdram_errors) { errors++; fprintf(stderr, "SDRAM: %u erros de protocolo/timing\n", dut->sdram_errors); }
    if (hd->acr_n != 6144 || hd->acr_cts != 25000) { errors++; fprintf(stderr, "ACR N/CTS errado: %d/%d\n", hd->acr_n, hd->acr_cts); }
    if (hd->avi_vic != 1) { errors++; fprintf(stderr, "AVI VIC errado: %d\n", hd->avi_vic); }
    if (frames_cmp == 0) { errors++; fprintf(stderr, "nenhum frame comparado\n"); }
    if (!(dut->leds & 4)) { errors++; fprintf(stderr, "SDRAM não ficou pronta\n"); }
    if (!(dut->leds & 16)) { errors++; fprintf(stderr, "HDMI não travou nas sincronias\n"); }
    if (dut->leds & 8) { errors++; fprintf(stderr, "FIFO de vídeo esvaziou\n"); }
    if (!lockloss && (dut->leds & 32)) { errors++; fprintf(stderr, "overflow da FIFO de áudio do HDMI\n"); }
    if (lockloss) {
        if (lock_events != 1 || frames_after_loss < 3) { errors++; fprintf(stderr, "recuperação após perda de lock: %ld eventos, %d frames depois\n", lock_events, frames_after_loss); }
        printf("    perda de lock após o frame 8 (%llu..%llu): %ld erros HDMI antes, receptor reiniciado; %d frames comparados depois da recuperação\n",
               (unsigned long long)loss_start, (unsigned long long)loss_end, hd_err_before, frames_after_loss);
        (void)frames_before;
    }
    if (!selftest_only && !lockloss) {
        if (md_applied != md_writes) { errors++; fprintf(stderr, "MD writes issued=%ld applied=%ld\n", md_writes, md_applied); }
        if (md_pc != md_ops.size()) { errors++; fprintf(stderr, "ciclos do MD não terminaram\n"); }
        if (!(dut->leds & 2) || (dut->leds & 1)) { errors++; fprintf(stderr, "o autoteste não cedeu lugar ao MD\n"); }
        if (ovl_frame.empty()) { errors++; fprintf(stderr, "overlay não capturado\n"); }
        else {
            for (int r = 0; r < 9; r++) printf("    TMDS| %s\n", ocr_row(ovl_frame, r).c_str());
            struct Exp { const char *n; long lo, hi; };
            Exp ex[] = {{"st", 0, 0}, {"md", 1, 1}, {"n_acc", 19, 19}, {"n_drop", 0, 0},
                        {"fifo_hw", 1, 2}, {"last_off", 6, 6}, {"last_d", 7, 7},
                        {"n_wr", 19, 19}, {"n_wr_cas0", 0, 0}, {"n_rd", 15, 15}, {"n_rd_cas0", 15, 15},
                        {"fdcw_min", 17, 19}, {"fdcw_max", 17, 19}, {"fdcr_min", 17, 19}, {"fdcr_max", 17, 19},
                        {"f2w_min", 10, 12}, {"f2w_max", 10, 12}, {"ww_min", 6, 8}, {"ww_max", 6, 8},
                        {"f2c_min", 0, 1}, {"f2c_max", 0, 1}, {"fres_now", 0, 0}, {"n_fres", 0, 0},
                        {"n_cas_out", 0, 0}, {"unit_i", 20, 20}, {"unit_f", 0, 0}};
            int ok = 0;
            for (auto &e : ex) {
                long v; std::string raw;
                if (!ovl_field(ovl_frame, e.n, &v, &raw) || v < e.lo || v > e.hi) {
                    errors++;
                    fprintf(stderr, "overlay %s = '%s' (esperado %ld..%ld)\n", e.n, raw.c_str(), e.lo, e.hi);
                } else ok++;
            }
            printf("    overlay: %d/%d campos lidos do TMDS serial conferem com os sinais aplicados no CN2\n", ok,
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
            save_ppm(outdir + "/ecp5_overlay.ppm", ovl_frame);
        }
    }
    if ((selftest_only || lockloss) && (!(dut->leds & 1) || (dut->leds & 2))) { errors++; fprintf(stderr, "autoteste independente inativo\n"); }

    printf("ECP5%s: %d/%d frames do TMDS serial iguais ao modelo; %ld amostras de áudio no HDMI iguais ao mixer "
           "(%ld conferidas com o modelo da APU, %ld erradas); %.1f amostras/frame (esperado 806,4)\n",
           lockloss ? " (perda de lock)" : (selftest_only ? " (autoteste)" : ""),
           frames_ok, frames_cmp, hm, aud.checked, aud.mismatches, spf);
    printf("    TMDS serial: %ld símbolos, %ld desalinhados, clock lane errada %ld, latência serial/paralelo %d pixels, %ld diferenças\n",
           des.symbols, des.misalign, des.bad_clock, spc.lat, spc.mismatches);
    printf("    pacotes: %ld (áudio %ld, ACR %ld N=%d CTS=%d, AVI %ld VIC=%d, Audio IF %ld, nulos %ld), erros HDMI %ld\n",
           hd->n_pkts, hd->n_audio_pkts, hd->n_acr, hd->acr_n, hd->acr_cts, hd->n_avi, hd->avi_vic, hd->n_aif, hd->n_null, hd->errors);
    if (init_glitch) printf("    reset durante a inicialização: lock 0 até o ciclo 40, 1, 0 nos ciclos 150..169 (SDRAM em power-up), %ld resets do núcleo, ADC em silêncio\n", n_core_resets);
    dchk.report(" (autoteste)");
    if (dchk.errors) { errors++; }
    if (dchk.done < 3) { errors++; fprintf(stderr, "DMA do autoteste não executou\n"); }
    printf("    SDRAM (sem DQM, RMW): %u escritas de 32 bits no modelo, %u erros; CN2: %ld escritas, %ld aplicadas, %ld leituras não dirigidas\n",
           dut->sdram_writes, dut->sdram_errors, md_writes, md_applied, md_reads);
    printf("    LEDs: autoteste=%d MD=%d SDRAM=%d FIFO_erro=%d HDMI_travado=%d áudio_ovf=%d; %llu ciclos de 50 MHz -> %s\n",
           dut->leds & 1, (dut->leds >> 1) & 1, (dut->leds >> 2) & 1, (dut->leds >> 3) & 1, (dut->leds >> 4) & 1,
           (dut->leds >> 5) & 1, (unsigned long long)sys_cycles, errors ? "FALHOU" : "OK");
    dut->final();
    delete dut; delete ctx;
    return errors ? 1 : 0;
}
