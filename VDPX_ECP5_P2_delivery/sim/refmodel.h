// Reference model of MD-VDPX (written from docs/M0_especificacao.md,
// independent of the RTL). Models the register interface and renders
// the expected 640x480 HDMI frame. M1.5: sprites, line/column scroll.
#pragma once
#include <cstdint>
#include <vector>

#include "p2/dma_check.h"

struct RefVDPX {
    // P2: DMA staging/commit model (target 6) and optional deferral of CPU VRAM writes, so
    // that a testbench can apply them in the order the RTL write port executes them.
    RefDMA dma;
    bool defer_vram_cpu = false;
    std::deque<std::pair<unsigned, uint16_t>> *cpu_vram_q = nullptr;
    uint16_t vram[32768] = {0};
    uint16_t cram[256]   = {0};
    uint16_t vsram[64]   = {0};
    uint16_t sat[512]    = {0};
    uint16_t regs[16]    = {0};
    unsigned reg_sel     = 0;
    // M3: sample memory (target 5) and log of APU register writes (target 4)
    unsigned smem_aw     = 20;
    std::vector<uint16_t> smem = std::vector<uint16_t>(1u << 20, 0);
    std::vector<std::pair<uint8_t, uint16_t>> apu_log;

    enum { MODE=0, BG=1, ABASE=2, BBASE=3, PSIZE=4, AX=5, AY=6, BX=7, BY=8,
           TBASE=9, SMODE=10, HSBASE=11, TGT=12, ADDR=13, INC=14, AHI=15 };

    static const int MAX_SPR_LINE  = 32;
    static const int MAX_COLS_LINE = 64;

    RefVDPX() { regs[INC] = 1; }

    static bool reg_impl(unsigned r) { return r <= 15; }

    void advance_addr() {
        uint32_t n = (uint32_t)regs[ADDR] + regs[INC];
        regs[ADDR] = (uint16_t)n;
        if (n >> 16) regs[AHI]++;
    }
    uint32_t smem_addr() const { return (((uint32_t)regs[AHI] << 16) | regs[ADDR]) & ((1u << smem_aw) - 1); }

    void write(unsigned a, uint16_t d) {
        switch (a) {
        case 0: {
            unsigned ad = regs[ADDR];
            switch (regs[TGT] & 7) {
            case 0:
                if (defer_vram_cpu && cpu_vram_q) cpu_vram_q->push_back({ad & 0x7fff, d});
                else vram[ad & 0x7fff] = d;
                break;
            case 1: cram[ad & 0xff] = d; break;
            case 2: vsram[ad & 63] = d; break;
            case 3: sat[ad & 511] = d; break;
            case 4: apu_log.push_back({(uint8_t)(ad & 0xff), d}); break;
            case 5: smem[smem_addr()] = d; break;
            case 6: if (ad < 8) dma.write(ad, d); break;       // P2: DMA registers 0..7
            default: break;
            }
            advance_addr();
            break; }
        case 2: reg_sel = d & 15; break;
        case 3: if (reg_impl(reg_sel)) regs[reg_sel] = d; break;
        default: break;
        }
    }

    // returns false if the value is time-dependent (not checkable)
    bool read(unsigned a, uint16_t &out) {
        switch (a) {
        case 0: {
            unsigned ad = regs[ADDR];
            bool det = true;
            switch (regs[TGT] & 7) {
            case 0: out = vram[ad & 0x7fff]; break;
            case 1: out = cram[ad & 0xff]; break;
            case 2: out = vsram[ad & 63]; break;
            case 3: out = sat[ad & 511]; break;
            case 4: det = false; out = 0; break;   // APU registers: value depends on tick timing
            case 5: out = smem[smem_addr()]; break;
            default: out = 0; break;
            }
            advance_addr();
            return det; }
        case 2: out = reg_sel; return true;
        case 3: out = reg_impl(reg_sel) ? regs[reg_sel] : 0; return true;
        case 6: out = 0x5658; return true;
        case 7: out = 0; return true;
        default: return false; // status, counters
        }
    }

    struct Px { bool op; bool pri; uint8_t idx; };

    Px plane_px(int plane, int x, int y) const {
        unsigned ps = regs[PSIZE];
        unsigned ws = plane ? (ps >> 4) & 3 : ps & 3;
        unsigned hs = plane ? (ps >> 6) & 3 : (ps >> 2) & 3;
        if (ws == 3) ws = 2;
        if (hs == 3) hs = 2;
        unsigned W = 32u << ws, H = 32u << hs;
        unsigned sm = regs[SMODE];
        bool hline = plane ? (sm & 2) : (sm & 1);
        bool vcol  = plane ? (sm & 8) : (sm & 4);
        unsigned sx = hline ? vram[(regs[HSBASE] + 2 * y + plane) & 0x7fff]
                            : (plane ? regs[BX] : regs[AX]);
        unsigned fine = sx & 7;
        unsigned ti = (x + fine) >> 3;                 // fetched tile index along the line
        unsigned sy = vcol ? vsram[(2 * (ti >> 1) + plane) & 63]
                           : (plane ? regs[BY] : regs[AY]);
        unsigned base = plane ? regs[BBASE] : regs[ABASE];
        unsigned px = (x + sx) % (W * 8);
        unsigned py = (y + (sy & 0x3ff)) % (H * 8);
        unsigned col = px / 8, row = py / 8;
        unsigned ea = (base + 2 * (row * W + col)) & 0xffff;
        uint16_t e0 = vram[ea & 0x7fff];
        uint16_t e1 = vram[(ea + 1) & 0x7fff];
        unsigned tile = e0 & 0x3fff;
        unsigned r = py & 7, c = px & 7;
        if (e0 & 0x8000) r = 7 - r;
        if (e0 & 0x4000) c = 7 - c;
        unsigned pa = (regs[TBASE] + tile * 16 + 2 * r + (c >= 4 ? 1 : 0)) & 0x7fff;
        uint16_t w = vram[pa];
        unsigned nib = (w >> (12 - 4 * (c & 3))) & 15;
        Px p;
        p.op = nib != 0;
        p.pri = (e1 >> 4) & 1;
        p.idx = (uint8_t)(((e1 & 15) << 4) | nib);
        return p;
    }

    // sprites visible on line y after applying the per-line limits.
    // returns list of sprite indices (front first); *ovf set if a limit was hit.
    std::vector<int> sprite_list(int y, bool *ovf) const {
        std::vector<int> l;
        int cols = 0;
        *ovf = false;
        for (int s = 0; s < 128; s++) {
            uint16_t w0 = sat[s * 4], w3 = sat[s * 4 + 3];
            int H = ((w0 >> 10) & 7) + 1, W = ((w0 >> 13) & 7) + 1;
            unsigned dy = (unsigned)(y - (w0 & 0x3ff)) & 0x3ff;
            bool vis = (w3 & 1) && dy < (unsigned)(H * 8);
            if (!vis) continue;
            if ((int)l.size() >= MAX_SPR_LINE || cols + W > MAX_COLS_LINE) { *ovf = true; break; }
            l.push_back(s);
            cols += W;
        }
        return l;
    }

    Px sprite_px(const std::vector<int> &l, int x, int y) const {
        for (int s : l) {                       // front (lowest index) first
            uint16_t w0 = sat[s * 4], w1 = sat[s * 4 + 1], w2 = sat[s * 4 + 2];
            int H = ((w0 >> 10) & 7) + 1, W = ((w0 >> 13) & 7) + 1;
            unsigned dy = (unsigned)(y - (w0 & 0x3ff)) & 0x3ff;
            int X = w1 & 0x3ff; if (X & 0x200) X -= 0x400;
            int rel = x - X;
            if (rel < 0 || rel >= W * 8) continue;
            bool hf = (w2 >> 14) & 1, vf = (w2 >> 15) & 1;
            int c = rel >> 3, k = rel & 7;
            int cc = hf ? W - 1 - c : c;
            int dyf = vf ? H * 8 - 1 - (int)dy : (int)dy;
            unsigned t = (w2 & 0x3fff) + cc * H + (dyf >> 3);
            int n = hf ? 7 - k : k;
            unsigned pa = (regs[TBASE] + t * 16 + (dyf & 7) * 2 + (n >= 4 ? 1 : 0)) & 0x7fff;
            unsigned nib = (vram[pa] >> (12 - 4 * (n & 3))) & 15;
            if (nib) {
                Px p; p.op = true; p.pri = (w1 >> 15) & 1;
                p.idx = (uint8_t)((((w1 >> 11) & 15) << 4) | nib);
                return p;
            }
        }
        Px p; p.op = false; p.pri = false; p.idx = 0;
        return p;
    }

    uint8_t compose(const std::vector<int> &l, int x, int y) const {
        Px a = plane_px(0, x, y), b = plane_px(1, x, y), s = sprite_px(l, x, y);
        uint8_t bg = regs[BG] & 0xff;
        if (s.op && s.pri) return s.idx;
        if (a.op && a.pri) return a.idx;
        if (b.op && b.pri) return b.idx;
        if (s.op) return s.idx;
        if (a.op) return a.idx;
        if (b.op) return b.idx;
        return bg;
    }

    static void rgb(uint16_t c, uint8_t *o) {
        unsigned r = (c >> 10) & 31, g = (c >> 5) & 31, b = c & 31;
        o[0] = (r << 3) | (r >> 2);
        o[1] = (g << 3) | (g >> 2);
        o[2] = (b << 3) | (b >> 2);
    }

    // expected 640x480 RGB888 frame; *spr_ovf = any line hit the sprite limit
    std::vector<uint8_t> render(bool *spr_ovf = nullptr) const {
        std::vector<uint8_t> f(640 * 480 * 3);
        std::vector<uint8_t> in(320 * 224);
        bool any = false;
        for (int y = 0; y < 224; y++) {
            bool ovf;
            auto l = sprite_list(y, &ovf);
            any |= ovf;
            for (int x = 0; x < 320; x++) in[y * 320 + x] = compose(l, x, y);
        }
        if (spr_ovf) *spr_ovf = any;
        for (int v = 0; v < 480; v++)
            for (int h = 0; h < 640; h++) {
                uint8_t idx;
                if (v < 16 || v >= 464 || !(regs[MODE] & 1)) idx = regs[BG] & 0xff;
                else idx = in[((v - 16) / 2) * 320 + h / 2];
                rgb(cram[idx], &f[(v * 640 + h) * 3]);
            }
        return f;
    }
};
