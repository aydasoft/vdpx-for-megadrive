# Comparação P1 × P2

| Item | P1 | P2 | Δ |
|---|---|---|---|
| TRELLIS_COMB | 7 655 (17 %) | 9 021 (21 %) | +1 366 (+17,8 %) |
| ↳ LUT4 / CCU2C / DPR16X4 (síntese) | 3 927 / 932 / 161 | 4 619 / 1 129 / 183 | +692 / +197 / +22 |
| TRELLIS_FF | 3 055 (7 %) | 3 715 (8 %) | +660 |
| EBR (DP16KD) | 44 (41 %) | 48 (44 %) | +4 (ROM do autoteste) |
| DSP (MULT18X18D) | 2 | 4 | +2 |
| E/S, PLL, ODDRX1F, DCCA | 83, 1, 5, 4 | 83, 1, 5, 4 | 0 |
| Fmax clk_sys s1/s2/s3 | 69,30 / 71,19 / 70,25 MHz | 68,18 / 65,47 / 65,33 MHz | −1,1 / −5,7 / −4,9 MHz |
| Margem mínima clk_sys | +38,6 % | +30,7 % | −7,9 p.p. |
| Fmax clk_pix / clk_x5 (pior semente) | 72,0 / 251,5 MHz | 71,6 / 257,2 MHz | ≈ |
| Caminho crítico clk_sys | renderizador / painel | estatística do DMA (`× 1000` → `r_num`) | ver `TIMING_REPORT.md` |
| Bitstream | `vdpx_ecp5_p1.bit` | `vdpx_ecp5_p2.bit` (1 143 589 bytes) | — |
| Tang: BSRAM / clk_sys | 43/46 / 117,98 MHz | 44/46 / 82,30 MHz | +1 / −35,7 MHz (meta 50,4) |
| Cenas de regressão | 17 | 24 (+7 de DMA) | +7 |
| Tempo de renderização (17 cenas da P1) | referência | idêntico em todas | 0 |
| Pior prazo da APU | (monitor inexistente) | 387 / 1041 ciclos | — |
| Cópia para a VRAM sem CPU | — | FILL/PATTERN 100 MB/s; COPY 19,8 MB/s | novo |
| Interface com o console | somente escrita | somente escrita (inalterada) | 0 |
| Validação em hardware | PENDING | PENDING | — |

Não alterados: renderizador, APU, adaptador CN2, sonda, HDMI/TMDS, PLL, LPF, os 16 registradores de `REG_SEL`, o
target 7 e os offsets `$A1200E/F`. A P1 original está preservada em `VDPX_ECP5_P1_delivery/`, sem alterações.
