# Caminhos críticos: antes e depois

Formato: tipo, atraso do elemento, acumulado (ns), célula. Trechos de roteamento omitidos. Extraído dos logs do
nextpnr (`logs/baseline_m42/`, `logs/timing_progression/`, `logs/ecp5_build/pnr_s*.log`).

## 0. Baseline M4.2 sem modificação: clk_sys 40,16 MHz (24,9 ns)

`rtl/vdpx_render.v`, desenho de sprite:
```
clk-to-q   0.52   0.52  u_ren.j (índice da lista)
logic      0.24   2.04  ls_w (RAM distribuída da lista)
logic      ...    4.59  d_cc (coluna, hflip)
logic      3.93   9.81  MULT18X18D  d_ccxh = d_cc * d_hh      <- produto 3x4 num DSP combinacional
logic      ...   13.03  CCU2C  d_tile = w2r + d_ccxh + dyf
logic      ...   ~24.9  spat_addr -> mux vaddr -> endereço da BRAM da VRAM
```
**Ação 1:** produto por soma/deslocamento (3 parcelas), sem DSP. Conta idêntica.

## 1. clk_sys ≈ 46 MHz (21,3 ns)

O mesmo caminho, sem o DSP: `ls_*[j]` → `d_cc`/`d_dyf` → `d_tile` (14 bits) → `spat_addr` (16 bits) → mux `vaddr`
→ BRAM.
**Ação 2:** estado `D_AD` em `vdpx_render.v`: `spat_r <= spat_addr` um ciclo antes de `D_E0`; `D_E0/D_E1` endereçam
a VRAM a partir do registrador. +1 ciclo por coluna de tile de sprite (máx. 64/linha).

## 2. clk_sys 47,8 MHz (20,9 ns)

`rtl/vdpx_apu.v`, mixer:
```
clk-to-q   0.52   0.52  u_apu.st (estado)
logic      ...    4.85  mux de mul_a/mul_b pelo estado
logic      3.93  11.07  MULT18X18D (21 x 8 bits, combinacional)
logic      ...   20.93  >>> 7 / soma com o acumulador / clip -> tx_r
```
**Ação 3:** `mul_a_r`/`mul_b_r` e produto registrados; cada estado que usa o produto espera 2 ciclos (`mwait`).
Aritmética e ordem iguais; +72 ciclos por amostra (de ~1042).

## 3. clk_sys 47,95 MHz (20,85 ns)

`vdpx_render.v`, planos:
```
clk-to-q   0.52   0.52  r_vsaddr/ti
logic      ...    3.93  VSRAM (RAM distribuída) -> sy_t
logic      ...    9.83  py = cur_line + sy_t ; row
logic      ...   13.97  row_off + col ; base + (...)<<1 = ent_addr
logic      ...   20.85  mux vaddr -> endereço da VRAM
```
**Ação 4:** estado `T_AD`: `ent_r <= ent_addr` e `fy_t <= py[2:0]` um ciclo antes de `T_E0`. +1 ciclo por tile
(41 por plano).

## 4. clk_sys 50,5 MHz (19,8 ns)

`rtl/board/vdpx_overlay.v` (gerado por `scripts/gen_overlay.py`): `f_f2c_min` → `n / 100`, `(n / 10) % 10`, `n % 10`
(divisores por constante viram cadeias de subtração) → registrador do snapshot.
**Ação 5:** `bcd3()` por double dabble (soma de 3 em grupos de 4 bits, sem divisão), registrado a cada ciclo
(`d_*`); o snapshot copia os registradores.

## 5. Topo real, clk_sys 52,9–56,8 MHz (17,6–18,9 ns)

```
clk-to-q   5.61   5.61  u_ovl.code1  DP16KD (ROM do template, saída sem registrador)
logic      ...   14.45  slotg(): mux de 99 slots -> glifo (gl2)
logic      ...   18.92  endereço da ROM de fonte (DP16KD.ADA)
```
**Ação 6:** estágio 1b no overlay (`code1b <= code1`, posições e vídeo atrasados juntos). O painel avança 1
estágio por pixel; o vídeo que passa pelo overlay ganha 1 pixel de latência, com os syncs juntos (imagem
idêntica: OCR 26/26 e quadros pixel a pixel).

## 6. Final: clk_sys 69,3–71,2 MHz

Semente 1 (14,43 ns, slack +5,57 ns), APU, carga do sample/wavetable:
```
clk-to-q   0.52   0.52  u_apu.restart_w
logic      ...    3.60  lfsr[wc] (RAM distribuída) / w_lfsr
logic      ...    5.74  phase[wc]
logic      ...   10.68  areg[ra] (registrador de onda)
logic      ...   13.43  wnib / t_wave
setup      0.00  14.43  u_apu.s
```
Semente 3: endereço da SDRAM vindo da APU (12,5 ns + roteamento). Não há caminho de vídeo/renderização entre os
mais lentos.

clk_pix (13,1 ns): FIFO de vídeo (LUT RAM) → codificador TMDS (contagem de disparidade).
clk_x5 (3,5 ns): sincronizador `ts` → carga dos registradores de deslocamento.

## Funcionalidade preservada

Nenhuma etapa mudou formato, ordem, prioridade ou posição de pixel: as 17 cenas comparam pixel a pixel com o modelo
de referência nos dois planos de clock. O orçamento por linha ficou em no máximo **2349 de 3200** ciclos
(`RENDER_BUDGET` nos logs), sem nenhum RENDER_OVERFLOW.
