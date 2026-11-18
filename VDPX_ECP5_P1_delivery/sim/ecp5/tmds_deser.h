// ECP5-P1: TMDS deserializer for the testbenches. Input = the 4 pad outputs (ODDRX1F Q of
// lanes 0..2 and of the clock lane) sampled once per half period of the 125 MHz clock,
// i.e. one bit per lane per sample (250 Mbit/s). A symbol starts at the bit where the
// clock lane goes 0 -> 1 (clock lane pattern 1111100000, bit 0 first). Every symbol must
// span exactly 10 samples; anything else is counted as a misalignment.
#pragma once
#include <cstdint>
#include <deque>

struct TmdsDeser {
    int prev_c = 1;                 // so that starting inside a clock-high phase is not a boundary
    int nbits = 0;
    bool started = false;
    uint16_t acc[3] = {0, 0, 0};
    uint16_t cacc = 0;
    long symbols = 0, misalign = 0, bad_clock = 0;
    uint16_t out[3] = {0, 0, 0};

    void reset() { prev_c = 1; nbits = 0; started = false; acc[0] = acc[1] = acc[2] = 0; cacc = 0; }

    // returns true when a complete symbol is in out[]
    bool bit(int q0, int q1, int q2, int qc) {
        bool emitted = false;
        if (!prev_c && qc) {                       // first bit of a new symbol
            if (started) {
                if (nbits == 10) {
                    if (cacc != 0x01F) bad_clock++;   // clock lane must be 1111100000 (bit 0 first)
                    out[0] = acc[0]; out[1] = acc[1]; out[2] = acc[2];
                    symbols++;
                    emitted = true;
                } else misalign++;
            }
            started = true; nbits = 0; acc[0] = acc[1] = acc[2] = 0; cacc = 0;
        }
        if (started && nbits < 16) {
            acc[0] |= (uint16_t)(q0 & 1) << nbits;
            acc[1] |= (uint16_t)(q1 & 1) << nbits;
            acc[2] |= (uint16_t)(q2 & 1) << nbits;
            cacc   |= (uint16_t)(qc & 1) << nbits;
            nbits++;
        }
        prev_c = qc;
        return emitted;
    }
};

// Compares the deserialized symbols with the parallel symbols of the transmitter (taken at
// each pixel clock edge before the serializer). The latency (in pixels) is learned on the
// first LEARN symbols (must be unique) and then enforced for every symbol.
struct SerParCheck {
    std::deque<uint32_t> par;                   // packed {t2,t1,t0}
    static const int MAXLAT = 6, LEARN = 4000;
    long n = 0, mismatches = 0;
    int lat = -1;
    bool cand[MAXLAT + 1];
    SerParCheck() { for (int i = 0; i <= MAXLAT; i++) cand[i] = true; }
    static uint32_t pack(uint16_t a, uint16_t b, uint16_t c) { return (uint32_t)a | ((uint32_t)b << 10) | ((uint32_t)c << 20); }
    void on_parallel(uint16_t t0, uint16_t t1, uint16_t t2) {
        par.push_front(pack(t0, t1, t2));
        if (par.size() > 64) par.pop_back();
    }
    void on_serial(const uint16_t *s) {
        uint32_t v = pack(s[0], s[1], s[2]);
        n++;
        if (par.size() < MAXLAT + 2) return;
        if (lat < 0) {
            for (int k = 0; k <= MAXLAT; k++) if (cand[k] && par[k] != v) cand[k] = false;
            if (n >= LEARN) {
                int cnt = 0, last = -1;
                for (int k = 0; k <= MAXLAT; k++) if (cand[k]) { cnt++; last = k; }
                if (cnt == 1) lat = last;
                else if (cnt == 0 || n > 50 * LEARN) mismatches++;   // no latency fits / never unique
            }
            return;
        }
        if (par[lat] != v) mismatches++;
    }
};
