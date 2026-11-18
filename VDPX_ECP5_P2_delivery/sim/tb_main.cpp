// MD-VDPX M1 testbench: executes a scene script (bus operations) against the
// RTL and the reference model, captures full HDMI frames and compares them
// pixel by pixel.
//
// Scene script commands (one per line, '#' comments):
//   w <addr> <data>      bus write (addr = word offset 0..7, values hex)
//   r <addr>             bus read, compared with the model when deterministic
//   wait <cycles>        idle cycles (decimal)
//   frame <name>         capture next complete frame, compare, save out/<name>.ppm
//   adc <fL> <fR> <amp>  test signal on the ADC input (Mega Drive audio), sine waves
//   rec <name>           start recording audio to out/<name>.wav
//   samples <n>          run until n more audio samples were produced (all checked)
//   stoprec              write the WAV file
//   dmawait              (P2, testbench aid) run until the DMA is idle and every expected write was seen
//   dmastat              (P2) print the DMA scoreboard counters
#include "Vvdpx_sim.h"
#ifndef CLK_MHZ_TB
#define CLK_MHZ_TB 50.4     // 50.0 in the test50 build (-CFLAGS -DCLK_MHZ_TB=50.0)
#endif
#include "verilated.h"
#include "refmodel.h"
#include "audio_tb.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <memory>

static Vvdpx_sim *dut = nullptr;
static AudioTB aud;
static RefVDPX *gref = nullptr;
static uint64_t cycles = 0;
static int errors = 0;

// video capture state
static std::vector<uint8_t> cap(640 * 480 * 3);
static int cx = 0, cy = 0, prev_de = 0, prev_vs = 1;
static bool frame_done = false, capturing = false;
static long cap_pixels = 0;

static bool status_clear_pending = false;
static DmaCheck dchk;                       // P2: DMA scoreboard (sim/p2/dma_check.h)
static bool dma_used = false;
static long dma_peak_q = 0;
static bool dma_log = false;
static bool frame_split = false;
static long dma_w_render = 0, dma_w_capture = 0;   // DMA writes while the renderer is busy / a frame is captured

static void sample_video() {
    if (!dut->vid_ce) return;               // outputs change once per pixel (clk = 2x pixel clock)
    int de = dut->vid_de, vs = dut->vid_vs_n;
    if (prev_vs == 1 && vs == 0) {          // vsync start = end of active frame
        if (capturing && cy == 480 && cap_pixels == 640L * 480) frame_done = true;
        if (!capturing) status_clear_pending = true;
        capturing = true; cx = 0; cy = 0; cap_pixels = 0;
    }
    if (capturing && de) {
        if (cx < 640 && cy < 480) {
            uint8_t *p = &cap[(cy * 640 + cx) * 3];
            p[0] = dut->vid_r; p[1] = dut->vid_g; p[2] = dut->vid_b;
        }
        cx++; cap_pixels++;
    }
    if (capturing && prev_de && !de) { cy++; cx = 0; }
    prev_de = de; prev_vs = vs;
}

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    cycles++;
    sample_video();
    {   // P2: every VRAM port write and DMA event, in RTL order
        unsigned q = (dut->dma_status[2] >> 28) & 7;
        if ((long)q > dma_peak_q) dma_peak_q = q;
        dchk.cycle(dut->dma_events, dut->dbg_vw_we, dut->dbg_vw_dma, dut->dbg_vw_addr, dut->dbg_vw_data, q);
        if (dut->dbg_vw_dma) { if (dut->dbg_rbusy) dma_w_render++; if (capturing && !frame_done) dma_w_capture++; }
        if (dma_log && ((dut->dma_events >> 21) & 1)) {
            unsigned cyc = dut->dma_status[1] & 0xFFFFFF, stalls = dut->dma_status[0] >> 16;
            unsigned words = (dut->dma_events >> 4) & 0xFFFF;
            printf("DMA_LOG op=%d len=%u words=%u cycles=%u stalls=%u ciclos/palavra=%.3f MB/s=%.2f\n",
                   dchk.run.op, dchk.run.len, words, cyc, stalls, words ? (double)cyc / words : 0.0,
                   cyc ? words * 2.0 * CLK_MHZ_TB / cyc : 0.0);
        }
    }
    // audio: ADC drives din (changes after BCLK falling), DAC decode, model check
    dut->i2s_din = aud.adc_step(dut->i2s_bclk, dut->i2s_lrck);
    aud.dac_step(dut->i2s_bclk, dut->i2s_lrck, dut->i2s_dout);
    if (dut->aud_valid)
        aud.on_output(*gref, dut->aud_wr_applied, (int16_t)dut->aud_l, (int16_t)dut->aud_r);
}

static uint16_t bus(bool we, unsigned addr, uint16_t data) {
    dut->bus_cs = 1; dut->bus_we = we; dut->bus_addr = addr; dut->bus_wdata = data;
    int guard = 0;
    do {
        tick();
        if (++guard > 3000) {  /* APU FIFO full: waits for the next 48 kHz tick */ fprintf(stderr, "BUS TIMEOUT addr=%u\n", addr); exit(2); }
    } while (!dut->bus_ack);
    uint16_t r = dut->bus_rdata;
    dut->bus_cs = 0; dut->bus_we = 0;
    tick();
    return r;
}

static void save_ppm(const std::string &path, const std::vector<uint8_t> &img) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n640 480\n255\n");
    fwrite(img.data(), 1, img.size(), f);
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "uso: %s cena.scn dir_saida\n", argv[0]); return 1; }
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    dut = new Vvdpx_sim(ctx);
    static RefVDPX ref;
    gref = &ref;
    // P2: the reference follows the RTL write port (CPU and DMA writes in port order)
    dchk.vram = ref.vram; dchk.smem = &ref.smem; dchk.smem_mask = (1u << ref.smem_aw) - 1;
    dchk.dma = &ref.dma; ref.dma.smem_aw = ref.smem_aw;
    ref.defer_vram_cpu = true; ref.cpu_vram_q = &dchk.cpu_q; dchk.defer_cpu = true;
    std::string outdir = argv[2];

    dut->rst = 1; dut->bus_cs = 0;
    for (int i = 0; i < 10; i++) tick();
    dut->rst = 0;
    for (int i = 0; i < 10; i++) tick();

    std::ifstream in(argv[1]);
    if (!in) { fprintf(stderr, "não abriu %s\n", argv[1]); return 1; }
    std::string line;
    int frames = 0, reads = 0, writes = 0, overflow = 0, sprovf_frames = 0;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string cmd; ss >> cmd;
        if (cmd == "w") {
            unsigned a, d; ss >> std::hex >> a >> d;
            ref.write(a, d); bus(true, a, d); writes++;   // model first: it predicts the port write
            if (a == 0 && (ref.regs[RefVDPX::TGT] & 7) == 6) dma_used = true;
        } else if (cmd == "r") {
            unsigned a; ss >> std::hex >> a;
            uint16_t got = bus(false, a, 0), exp;
            if (ref.read(a, exp)) {
                reads++;
                if (got != exp) {
                    if (errors < 20) fprintf(stderr, "READ MISMATCH a=%u got=%04x exp=%04x\n", a, got, exp);
                    errors++;
                }
            }
        } else if (cmd == "dmawait") {
            long guard = 0;
            while (!(dchk.idle() && !((dut->dma_status[3] >> 3) & 1))) {
                tick();
                if (++guard > 20000000) { fprintf(stderr, "DMA TIMEOUT\n"); return 2; }
            }
            tick();
        } else if (cmd == "dmalog") {
            dma_log = true;
        } else if (cmd == "echo") {
            std::string rest; std::getline(ss, rest); printf("%s\n", rest.c_str() + (rest.size() && rest[0] == ' '));
        } else if (cmd == "dmastat") {
            dchk.report("");
        } else if (cmd == "wait") {
            long n; ss >> n; for (long i = 0; i < n; i++) tick();
        } else if (cmd == "adc") {
            ss >> aud.fl >> aud.fr >> aud.amp;
        } else if (cmd == "rec") {
            ss >> aud.rec_name; aud.rec = true; aud.rec_buf.clear();
        } else if (cmd == "stoprec") {
            AudioTB::write_wav(outdir + "/" + aud.rec_name + ".wav", aud.rec_buf);
            aud.rec = false;
        } else if (cmd == "samples") {
            long n; ss >> n;
            size_t target = aud.out_l.size() + n;
            long guard = 0;
            while (aud.out_l.size() < target) {
                tick();
                if (++guard > (n + 4) * 1100) { fprintf(stderr, "AUDIO TIMEOUT\n"); return 2; }
            }
        } else if (cmd == "framebegin") {
            // P2: start capturing the next frame and return as soon as it began (vsync), so that
            // the following commands (DMA) run during the active display; 'frameend' completes it
            frame_done = false; capturing = false; status_clear_pending = false;
            long guard = 0;
            while (!capturing) {
                tick();
                if (status_clear_pending) { status_clear_pending = false; bus(false, 1, 0); }
                if (++guard > 4000000) { fprintf(stderr, "FRAME TIMEOUT\n"); return 2; }
            }
            frame_split = true;
        } else if (cmd == "frame" || cmd == "frameend") {
            std::string name; ss >> name;
            if (cmd == "frame" || !frame_split) { frame_done = false; capturing = false; status_clear_pending = false; }
            frame_split = false;
            long guard = 0;
            while (!frame_done) {
                tick();
                if (status_clear_pending) { status_clear_pending = false; bus(false, 1, 0); } // clear sticky flags at frame start
                if (++guard > 4000000) { fprintf(stderr, "FRAME TIMEOUT\n"); return 2; }
            }
            // sticky flags accumulated during exactly this frame (reading STATUS clears them)
            uint16_t st = bus(false, 1, 0);
            if (st & 4) { overflow++; errors++; fprintf(stderr, "RENDER OVERFLOW em %s\n", name.c_str()); }
            bool exp_sovf = false;
            auto exp = ref.render(&exp_sovf);
            if (((st >> 3) & 1) != (exp_sovf ? 1 : 0)) {
                errors++;
                fprintf(stderr, "FLAG SPR_OVF em %s: rtl=%d modelo=%d\n", name.c_str(), (st >> 3) & 1, exp_sovf);
            }
            if (exp_sovf) sprovf_frames++;
            long diff = 0; int fx = -1, fy = -1;
            for (int i = 0; i < 640 * 480; i++)
                if (memcmp(&cap[i * 3], &exp[i * 3], 3)) { if (fx < 0) { fx = i % 640; fy = i / 640; } diff++; }
            save_ppm(outdir + "/" + name + ".ppm", cap);
            if (diff) {
                save_ppm(outdir + "/" + name + "_esperado.ppm", exp);
                fprintf(stderr, "FRAME %s: %ld pixels diferentes (primeiro em %d,%d)\n", name.c_str(), diff, fx, fy);
                errors++;
            }
            frames++;
        }
    }
    int txd = -1;
    for (int i = 0; i < 50; i++) tick();     // let the last bus writes reach the VRAM port
    if (dchk.errors) errors++;
    if (!dchk.cpu_q.empty()) { errors++; fprintf(stderr, "escritas de CPU na VRAM que não chegaram à porta: %zu\n", dchk.cpu_q.size()); }
    if (dma_used) {
        dchk.report("");
        printf("    DMA: ocupação máxima da fila %ld; escritas DMA com o renderizador ocupado %ld, durante quadros capturados %ld\n",
               dma_peak_q, dma_w_render, dma_w_capture);
        if (!dchk.idle()) { errors++; fprintf(stderr, "DMA: comandos esperados ainda pendentes no fim\n"); }
    }
    if (aud.mismatches) errors++;
    if (!aud.check_tx(&txd)) { errors++; fprintf(stderr, "saída I2S (DAC) diferente das amostras do mixer\n"); }
    printf("%s: %d escritas, %d leituras verificadas, %d frames (%d com limite de sprites), "
           "%ld amostras de áudio (%ld erradas), %llu ciclos -> %s\n",
           argv[1], writes, reads, frames, sprovf_frames, aud.checked, aud.mismatches,
           (unsigned long long)cycles, errors ? "FALHOU" : "OK");
    dut->final();
    delete dut;
    delete ctx;
    return errors ? 1 : 0;
}
