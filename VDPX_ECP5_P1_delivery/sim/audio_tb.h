// Audio side of the testbenches: I2S ADC model (stands in for the PCM1808
// digitizing the Mega Drive audio), I2S DAC decoder, APU reference model
// alignment and WAV output.
#pragma once
#include "apumodel.h"
#include "refmodel.h"
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

struct AudioTB {
    // ---- ADC (Mega Drive audio input) test signal
    double fl = 0, fr = 0;        // Hz (0 = silence)
    int amp = 0;
    std::vector<int16_t> adc_l, adc_r;   // value sent in each frame
    long frame = -1;              // current I2S frame index (counted on LRCK falling edges)
    int bitpos = 0;
    int prev_bclk = 0, prev_lrck = 0;
    int din = 0;

    // ---- DAC decode
    int dprev_bclk = 0, dprev_lrck = 0, dbit = 0;
    uint32_t dsh = 0;
    int16_t dec_l = 0;
    std::vector<int16_t> tx_l, tx_r;

    // ---- APU model
    RefAPU apu;
    size_t applied = 0;
    size_t applied_base = 0;     // ECP5-P1: log index where the RTL counter restarted (core reset)
    std::vector<int16_t> out_l, out_r;          // RTL outputs (whole run)
    long mismatches = 0, checked = 0;

    // ---- WAV recording
    bool rec = false;
    std::string rec_name;
    std::vector<int16_t> rec_buf;

    int16_t sig(double f, long n) const {
        if (f == 0 || amp == 0) return 0;
        return (int16_t)lrint(amp * sin(2 * M_PI * f * n / 48000.0));
    }

    // call once per clock, after the rising edge has been evaluated; returns din to drive
    int adc_step(int bclk, int lrck) {
        if (lrck != prev_lrck) {
            bitpos = 0;
            if (!lrck) {                                // new frame (left channel)
                frame++;
                adc_l.push_back(sig(fl, frame));
                adc_r.push_back(sig(fr, frame));
            }
        } else if (prev_bclk && !bclk) {
            bitpos++;
        }
        if ((lrck != prev_lrck) || (prev_bclk && !bclk)) {
            int16_t v = frame < 0 ? 0 : (lrck ? adc_r.back() : adc_l.back());
            uint32_t w24 = ((uint32_t)(uint16_t)v << 8) | 0x5A;     // 24-bit word, low byte = noise
            din = (bitpos >= 1 && bitpos <= 24) ? (w24 >> (24 - bitpos)) & 1 : 0;
        }
        prev_bclk = bclk; prev_lrck = lrck;
        return din;
    }

    void dac_step(int bclk, int lrck, int dout) {
        if (lrck != dprev_lrck) {
            if (lrck) dec_l = (int16_t)(dsh & 0xFFFF);            // left word complete
            else { tx_l.push_back(dec_l); tx_r.push_back((int16_t)(dsh & 0xFFFF)); }
            dbit = 0; dsh = 0;
        }
        if (!dprev_bclk && bclk) {                                 // rising edge: sample
            if (dbit >= 1 && dbit <= 16) dsh = (dsh << 1) | (dout & 1);
            dbit++;
        }
        dprev_bclk = bclk; dprev_lrck = lrck;
    }

    // RTL produced a sample; 'wr_applied' = APU writes applied so far
    void on_output(RefVDPX &ref, unsigned wr_applied, int16_t l, int16_t r) {
        if (!apu.smem) { apu.smem = &ref.smem; apu.smem_mask = (1u << ref.smem_aw) - 1; }
        unsigned target = wr_applied;
        // wr_applied is 16-bit in RTL: extend
        while (((applied - applied_base) & 0xFFFF) != target && applied < ref.apu_log.size()) {
            apu.write(ref.apu_log[applied].first, ref.apu_log[applied].second);
            applied++;
        }
        // external input used now = frame completed at this tick = previous frame
        int16_t el = 0, er = 0;
        if (frame >= 1) { el = adc_l[frame - 1]; er = adc_r[frame - 1]; }
        int16_t el2, er2;
        apu.tick(el, er, &el2, &er2);
        checked++;
        if (el2 != l || er2 != r) {
            if (mismatches < 10)
                fprintf(stderr, "AUDIO amostra %zu: rtl=(%d,%d) modelo=(%d,%d)\n",
                        out_l.size(), l, r, el2, er2);
            mismatches++;
        }
        out_l.push_back(l); out_r.push_back(r);
        if (rec) { rec_buf.push_back(l); rec_buf.push_back(r); }
    }

    // ECP5-P1: core reset. 'rtl_applied' = APU writes the RTL had applied before the reset;
    // later logged writes were still queued and are lost with the reset (as in the RTL).
    void on_core_reset(RefVDPX &ref, unsigned rtl_applied) {
        if (!apu.smem) { apu.smem = &ref.smem; apu.smem_mask = (1u << ref.smem_aw) - 1; }
        while (((applied - applied_base) & 0xFFFF) != (rtl_applied & 0xFFFF) && applied < ref.apu_log.size()) {
            apu.write(ref.apu_log[applied].first, ref.apu_log[applied].second);
            applied++;
        }
        ref.apu_log.resize(applied);
        applied_base = applied;
        apu.core_reset();
        out_l.clear(); out_r.clear(); tx_l.clear(); tx_r.clear();
        // the RTL I2S restarts a frame (LRCK low, bit 0): the ADC model restarts its bit count
        bitpos = 0; prev_bclk = 0; din = 0;
        resets++;
    }
    int resets = 0;

    static void write_wav(const std::string &path, const std::vector<int16_t> &st) {
        FILE *f = fopen(path.c_str(), "wb");
        if (!f) return;
        uint32_t data = st.size() * 2, rate = 48000, br = rate * 4, sz = 36 + data;
        uint16_t pcm = 1, ch = 2, ba = 4, bits = 16;
        uint32_t fmt = 16;
        fwrite("RIFF", 1, 4, f); fwrite(&sz, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
        fwrite(&fmt, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f);
        fwrite(&rate, 4, 1, f); fwrite(&br, 4, 1, f); fwrite(&ba, 2, 1, f); fwrite(&bits, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
        fwrite(st.data(), 2, st.size(), f);
        fclose(f);
    }

    // DAC stream must equal the RTL outputs with a constant delay
    bool check_tx(int *delay) const {
        for (int d = 0; d <= 3; d++) {
            bool ok = true; long n = 0;
            for (size_t i = 0; i + d < tx_l.size() && i < out_l.size(); i++, n++)
                if (tx_l[i + d] != out_l[i] || tx_r[i + d] != out_r[i]) { ok = false; break; }
            if (ok && n > 10) { *delay = d; return true; }
        }
        return out_l.size() <= 10;
    }
};
