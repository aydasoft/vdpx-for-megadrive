// Bit-exact reference model of the MD-VDPX APU (spec section 10),
// written from the specification, independent of rtl/vdpx_apu.v.
#pragma once
#include <cstdint>
#include <vector>

struct RefAPU {
    uint16_t reg[256] = {0};
    uint32_t pos[8] = {0};       // 17.12
    bool playing[8] = {false};
    uint32_t phase[8] = {0};     // 20 bits
    uint16_t lfsr[8];
    const std::vector<uint16_t> *smem = nullptr;
    unsigned smem_mask = 0;

    RefAPU() {
        for (int i = 0; i < 8; i++) lfsr[i] = 0x4000;
        reg[193] = 0x8080;
    }

    // register write, applied at the start of a tick (in order)
    void write(unsigned a, uint16_t d) {
        a &= 255;
        if (a != 194) reg[a] = d;
        if (a < 128 && (a & 7) == 0) {
            unsigned c = a >> 3;
            if (c < 8) { playing[c] = d & 1; if (d & 1) pos[c] = 0; }
            else { phase[c - 8] = 0; lfsr[c - 8] = 0x4000; }
        }
    }

    int8_t smem_byte(uint32_t baddr) const {
        uint16_t w = (*smem)[(baddr >> 1) & smem_mask];
        return (int8_t)((baddr & 1) ? (w & 0xff) : (w >> 8));
    }

    static int16_t clip16(int64_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }

    // one 48 kHz output sample; ext = MD audio received in the previous I2S frame
    void tick(int16_t ext_l, int16_t ext_r, int16_t *out_l, int16_t *out_r) {
        int64_t al = 0, ar = 0;
        for (int c = 0; c < 8; c++) {                     // PCM
            const uint16_t *r = &reg[c * 8];
            uint32_t len = r[3], lp = r[4];
            bool loop = r[0] & 2;
            if (playing[c] && (pos[c] >> 12) >= len) {
                if (loop && len > lp) {
                    pos[c] -= (len - lp) << 12;
                    if ((pos[c] >> 12) >= len) pos[c] = lp << 12;
                } else {
                    playing[c] = false;
                }
            }
            int s = 0;
            if (playing[c]) {
                uint32_t start = ((uint32_t)(r[2] & 0x7f) << 16) | r[1];
                s = smem_byte((start + (pos[c] >> 12)) & 0x7fffff);
                pos[c] += r[5];
            }
            al += s * (r[6] >> 8);
            ar += s * (r[6] & 0xff);
        }
        for (int k = 0; k < 8; k++) {                     // wavetable / noise
            const uint16_t *r = &reg[(8 + k) * 8];
            int s = 0;
            if (r[0] & 1) {
                if (r[0] & 2) s = (lfsr[k] & 1) ? 96 : -96;
                else {
                    unsigned idx = phase[k] >> 15;            // 0..31
                    uint16_t w = reg[128 + k * 8 + (idx >> 2)];
                    unsigned nib = (w >> (12 - 4 * (idx & 3))) & 15;
                    s = ((int)nib - 8) * 16;
                }
                uint32_t sum = phase[k] + r[1];
                phase[k] = sum & 0xFFFFF;
                if ((r[0] & 2) && (sum >> 20)) {
                    unsigned fb = (lfsr[k] ^ (lfsr[k] >> 1)) & 1;
                    lfsr[k] = (uint16_t)((lfsr[k] >> 1) | (fb << 14));
                }
            }
            al += s * (r[2] >> 8);
            ar += s * (r[2] & 0xff);
        }
        uint16_t m = reg[192], e = reg[193];
        int64_t l = ((al * (m >> 8)) >> 10) + (((int64_t)ext_l * (e >> 8)) >> 7);
        int64_t rr = ((ar * (m & 0xff)) >> 10) + (((int64_t)ext_r * (e & 0xff)) >> 7);
        *out_l = clip16(l);
        *out_r = clip16(rr);
    }
};
