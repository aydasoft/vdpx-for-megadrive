// HDMI sink model for verification: decodes the three TMDS symbol streams
// (one 10-bit symbol per pixel clock and channel) back into video frames,
// sync, and data island packets (with BCH checks), like a TV would.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

struct HdmiDec {
    // ---- symbol tables
    std::map<uint16_t, int> terc4, ctrl;
    static const uint16_t VG0 = 0x2CC, VG1 = 0x133, VG2 = 0x2CC;   // 1011001100, 0100110011
    static const uint16_t DG12 = 0x133;

    HdmiDec() {
        const uint16_t t[16] = {0x29C, 0x263, 0x2E4, 0x2E2, 0x171, 0x11E, 0x18E, 0x13C,
                                0x2CC, 0x139, 0x19C, 0x2C6, 0x28E, 0x271, 0x163, 0x2C3};
        for (int i = 0; i < 16; i++) terc4[t[i]] = i;
        ctrl[0x354] = 0; ctrl[0x0AB] = 1; ctrl[0x154] = 2; ctrl[0x2AB] = 3;
        frame.assign(640 * 480 * 3, 0);
    }

    // ---- state
    enum Period { CTRL, VPRE, VGUARD, VIDEO, DPRE, DGUARD_L, DATA, DGUARD_T } per = CTRL;
    int pre_cnt = 0, guard_cnt = 0, pkt_pix = 0;
    int hs = 1, vs = 1, prev_hs = 1, prev_vs = 1;
    int x = 0, y = 0;
    bool synced = false;
    bool armed = false;      // first full line after the sink locked
    long errors = 0;
    int disparity[3] = {0, 0, 0};

    std::vector<uint8_t> frame;
    long frame_pixels = 0;
    int frames_done = 0;
    bool frame_ready = false;
    std::vector<uint8_t> last_frame;

    // packets
    uint32_t hdr = 0;
    uint64_t sp[4] = {0, 0, 0, 0};
    long n_pkts = 0, n_audio_pkts = 0, n_acr = 0, n_avi = 0, n_aif = 0, n_null = 0;
    std::vector<int16_t> aud_l, aud_r;
    int acr_n = -1, acr_cts = -1, avi_vic = -1;
    int iec_expect = -1;     // expected IEC frame index of the next sample

    void err(const char *m) {
        if (!armed) return;                  // until one full line after lock the sink ignores errors
        if (errors < 15) fprintf(stderr, "HDMI: %s (x=%d y=%d)\n", m, x, y);
        errors++;
    }

    static uint8_t ecc1(uint8_t e, int b) { return (e >> 1) ^ (((e ^ b) & 1) ? 0x83 : 0); }

    int vdec(uint16_t q, int ch) {
        int ones = __builtin_popcount(q);
        disparity[ch] += ones - (10 - ones);
        uint8_t d = q & 0xFF;
        if (q & 0x200) d = ~d;
        uint8_t o = d & 1;
        for (int i = 1; i < 8; i++) {
            int bit = ((d >> i) ^ (d >> (i - 1))) & 1;
            if (!(q & 0x100)) bit ^= 1;
            o |= bit << i;
        }
        return o;
    }

    void finish_packet() {
        n_pkts++;
        if (!armed) iec_expect = -1;     // IEC frame tracking starts at the first B flag after lock
        // BCH checks: header 24+8, subpackets 56+8
        uint8_t e = 0;
        for (int i = 0; i < 24; i++) e = ecc1(e, (hdr >> i) & 1);
        if (e != ((hdr >> 24) & 0xFF)) err("ECC do cabeçalho errado");
        for (int k = 0; k < 4; k++) {
            uint8_t es = 0;
            for (int i = 0; i < 56; i++) es = ecc1(es, (sp[k] >> i) & 1);
            if (es != ((sp[k] >> 56) & 0xFF)) err("ECC de subpacote errado");
        }
        uint8_t hb0 = hdr & 0xFF, hb1 = (hdr >> 8) & 0xFF, hb2 = (hdr >> 16) & 0xFF;
        auto byte = [&](int k, int i) { return (uint8_t)((sp[k] >> (8 * i)) & 0xFF); };
        if (hb0 == 0x00) n_null++;
        else if (hb0 == 0x02) {
            n_audio_pkts++;
            if (hb1 & 0x10) err("layout 1 inesperado");
            for (int k = 0; k < 4; k++) {
                if (!((hb1 >> k) & 1)) continue;
                uint32_t l24 = sp[k] & 0xFFFFFF, r24 = (sp[k] >> 24) & 0xFFFFFF;
                uint8_t f = byte(k, 6);
                int pl = (f >> 3) & 1, cl = (f >> 2) & 1, pr = (f >> 7) & 1, cr = (f >> 6) & 1;
                if (__builtin_parity(l24 ^ cl) != pl || __builtin_parity(r24 ^ cr) != pr) err("paridade IEC errada");
                if ((l24 & 0xFF) || (r24 & 0xFF)) err("bits baixos da amostra não são zero");
                bool B = (hb2 >> (4 + k)) & 1;
                if (B) iec_expect = 0;
                if (iec_expect >= 0) {
                    int fr = iec_expect;
                    int ecl = (fr == 2 || fr == 25 || fr == 20), ecr = (fr == 2 || fr == 25 || fr == 21);
                    if (cl != ecl || cr != ecr) err("channel status IEC errado");
                    iec_expect = (iec_expect + 1) % 192;
                }
                aud_l.push_back((int16_t)(l24 >> 8));
                aud_r.push_back((int16_t)(r24 >> 8));
            }
        } else if (hb0 == 0x01) {
            n_acr++;
            int cts = (byte(0, 1) & 15) << 16 | byte(0, 2) << 8 | byte(0, 3);
            int n = (byte(0, 4) & 15) << 16 | byte(0, 5) << 8 | byte(0, 6);
            acr_n = n; acr_cts = cts;
        } else if (hb0 == 0x82 || hb0 == 0x84) {
            int len = hb2 & 0x1F;
            uint8_t sum = hb0 + hb1 + hb2;
            for (int i = 0; i <= len; i++) sum += byte(i / 7, i % 7);
            if (sum != 0) err("checksum de InfoFrame errado");
            if (hb0 == 0x82) { n_avi++; avi_vic = byte(0, 4); }
            else n_aif++;
        } else {
            err("tipo de pacote desconhecido");
        }
    }

    // advance the position counters (same convention as the transmitter)
    void step_pos() {
        if (prev_hs && !hs) { if (synced && x != 656) err("HSYNC fora do lugar"); x = 656; synced = true; }
        if (prev_vs && !vs) {
            if ((y != 490 || x != 0) && frames_done > 0) err("VSYNC fora do lugar");
            if (synced && frame_pixels == 640L * 480) {
                last_frame = frame; frame_ready = true;
            } else if (synced && frames_done > 0) {
                err("frame com número errado de pixels");
            }
            frames_done++;
            frame_pixels = 0;
            y = 490;
        }
        prev_hs = hs; prev_vs = vs;
    }
    void next_pos() {
        if (++x == 800) { x = 0; if (++y == 525) y = 0; if (synced) armed = true; }
    }

    void symbol(uint16_t q0, uint16_t q1, uint16_t q2) {
        bool c0 = ctrl.count(q0), c1 = ctrl.count(q1), c2 = ctrl.count(q2);
        if (c0 && c1 && c2) {
            int cc0 = ctrl[q0], cc1 = ctrl[q1], cc2 = ctrl[q2];
            hs = cc0 & 1; vs = (cc0 >> 1) & 1;
            if (per == VIDEO) per = CTRL;
            if (per == DATA || per == DGUARD_L) err("data island terminou sem guard band");
            if (cc1 == 1 && cc2 == 0) { if (per != VPRE) { per = VPRE; pre_cnt = 0; } pre_cnt++; }
            else if (cc1 == 1 && cc2 == 1) { if (per != DPRE) { per = DPRE; pre_cnt = 0; } pre_cnt++; }
            else { per = CTRL; pre_cnt = 0; }
            step_pos(); next_pos();
            return;
        }
        // non-control symbol
        if (per == VPRE) {
            if (pre_cnt < 8) err("preâmbulo de vídeo curto");
            per = VGUARD; guard_cnt = 0;
        } else if (per == DPRE) {
            if (pre_cnt < 8) err("preâmbulo de data island curto");
            per = DGUARD_L; guard_cnt = 0;
        }
        if (per == VGUARD) {
            if (q0 != VG0 || q1 != VG1 || q2 != VG2) err("guard band de vídeo errado");
            step_pos(); next_pos();
            if (++guard_cnt == 2) { per = VIDEO; disparity[0] = disparity[1] = disparity[2] = 0; }
            return;
        }
        if (per == DGUARD_L || per == DGUARD_T) {
            if (q1 != DG12 || q2 != DG12 || !terc4.count(q0) || (terc4[q0] & 0xC) != 0xC) err("guard band de data island errado");
            if (terc4.count(q0)) { hs = terc4[q0] & 1; vs = (terc4[q0] >> 1) & 1; }
            step_pos(); next_pos();
            if (++guard_cnt == 2) {
                if (per == DGUARD_L) { per = DATA; pkt_pix = 0; hdr = 0; memset(sp, 0, sizeof sp); }
                else per = CTRL;
            }
            return;
        }
        if (per == DATA) {
            if (pkt_pix == 0 && q1 == DG12 && q2 == DG12) {      // trailing guard
                per = DGUARD_T; guard_cnt = 0;
                symbol(q0, q1, q2);
                return;
            }
            if (!terc4.count(q0) || !terc4.count(q1) || !terc4.count(q2)) { err("símbolo TERC4 inválido"); step_pos(); next_pos(); return; }
            int t0 = terc4[q0], t1 = terc4[q1], t2 = terc4[q2];
            hs = t0 & 1; vs = (t0 >> 1) & 1;
            if (!(t0 & 8)) err("bit 3 do canal 0 em zero");
            hdr |= (uint32_t)((t0 >> 2) & 1) << pkt_pix;
            for (int k = 0; k < 4; k++) {
                sp[k] |= (uint64_t)((t1 >> k) & 1) << (2 * pkt_pix);
                sp[k] |= (uint64_t)((t2 >> k) & 1) << (2 * pkt_pix + 1);
            }
            step_pos(); next_pos();
            if (++pkt_pix == 32) { finish_packet(); pkt_pix = 0; hdr = 0; memset(sp, 0, sizeof sp); }
            return;
        }
        if (per == VIDEO) {
            if (synced && (x >= 640 || y >= 480)) err("pixel de vídeo fora da área ativa");
            if (synced && x < 640 && y < 480) {
                uint8_t *p = &frame[(y * 640 + x) * 3];
                p[2] = vdec(q0, 0); p[1] = vdec(q1, 1); p[0] = vdec(q2, 2);
                frame_pixels++;
            }
            for (int ch = 0; ch < 3; ch++)
                if (disparity[ch] > 40 || disparity[ch] < -40) { err("desequilíbrio DC"); disparity[ch] = 0; }
            next_pos();
            return;
        }
        err("símbolo inesperado em período de controle");
        step_pos(); next_pos();
    }
};
