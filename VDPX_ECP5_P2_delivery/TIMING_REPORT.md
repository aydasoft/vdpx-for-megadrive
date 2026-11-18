# Relatório de timing (ECP5-P2): LFE5U-45F-6BG381C

Ferramentas: Yosys 0.71 + nextpnr-ecp5 0.11.1 (YoWASP), `--45k --package CABGA381 --speed 6`, sementes 1, 2 e 3,
restrição `FREQUENCY PORT clk25 25 MHZ` (domínios derivados do EHXPLLL). Fontes: `logs/ecp5_build/report.md`,
`report.json`, `pnr_s{1,2,3}.log`.

## Resultado: **TIMING PASS** (3/3 sementes, margem ≥ 10 % em todos os domínios)

| Semente | clk_sys (meta 50 MHz) | clk_pix (meta 25 MHz) | clk_x5 (meta 125 MHz) | exit | avisos P&R |
|---|---|---|---|---|---|
| 1 | **68,18 MHz** (+36,4 %, slack +5,33 ns) | 73,14 MHz (+192,6 %) | 257,2 MHz (+105,8 %, slack +4,11 ns) | 0 | 0 |
| 2 | **65,47 MHz** (+30,9 %, slack +4,73 ns) | 71,63 MHz (+186,5 %) | 285,0 MHz (+128,0 %) | 0 | 0 |
| 3 | **65,33 MHz** (+30,7 %, slack +4,69 ns) | 73,83 MHz (+195,3 %) | 282,5 MHz (+126,0 %) | 0 | 0 |

Bitstream gerado da semente 1. P1 (mesmas ferramentas): clk_sys 69,30 / 71,19 / 70,25 MHz. A P2 perde de 1 a 5 MHz
em clk_sys e continua com ≥ 30 % de margem.

## Caminho crítico de clk_sys (novo, no DMA)

Nas 3 sementes, o caminho crítico termina em `u_dma.r_num` (numerador da taxa do painel):

`st` / `vram_we` (FF) → `wrote` (concessão da escrita na VRAM) → `words_cur + wrote` → **× 1000** (MULT18X18D +
cadeia CCU2C) → `r_num`.

Tempo: 14,7–15,3 ns (≈ 7 ns de lógica, 7,4–8,3 ns de roteamento). É um caminho **só de estatística**: a taxa
exibida no painel. Não afeta a função do DMA nem a VRAM.

Otimização possível, não aplicada nesta fase porque a margem já passa de 30 %: registrar `words_cur` final num ciclo
e multiplicar no ciclo seguinte. Isso tiraria o DMA do caminho crítico e voltaria ao patamar da P1, cujo caminho
crítico era o renderizador/painel.

## Caminhos entre domínios (reportados, não restringidos)

| De → para | s1 / s2 / s3 (ns) | Mecanismo | P1 (ns) |
|---|---|---|---|
| clk_pix → clk_x5 | 1,77 / 1,80 / 1,61 | toggle + 2 FFs, mesmo VCO | 1,68 / 1,80 / 1,80 |
| clk_sys → clk_pix | 1,51 / 1,48 / 1,28 | FIFO de vídeo Gray | 1,52 / 1,47 / 1,48 |
| clk_pix → clk_sys | 1,26 / 1,24 / 1,22 | sincronizadores | 1,25 / 1,60 / 1,24 |
| clk_sys → `<async>` | 9,45 / 9,96 / 9,77 | saídas (LED, SDRAM) | 9,61 / 8,65 / 10,25 |
| `<async>` → clk_sys | 5,72 / 5,56 / 5,10 | entradas CN2 → FIFO do adaptador | 6,27 / 6,49 / 5,98 |
| clk_pix → `<async>` | 7,39 / 7,92 / 7,77 | I2S/LED registrados | 8,78 / 8,47 / 9,04 |

O DMA está inteiramente em clk_sys e não criou nenhum cruzamento de domínio novo.

## E/S da SDRAM (fora da STA)

| Grupo | Roteamento máximo s1 / s2 / s3 (ns) | Orçamento da P1 (`docs/p1/SDRAM_32BIT_REPORT.md` §4) |
|---|---|---|
| Comando | 2,89 / 2,98 / 2,98 | ≤ 3,5 |
| DQ saída | 2,72 / 2,89 / 2,50 | ≤ 3,5 |
| DQ entrada / OE | 6,04 / 5,99 / 5,98 | ≤ 7 (buffer + roteamento) |

Continua dentro do orçamento calculado na P1. **Status: cálculo + simulação, não STA.**

## Tang (comparação, RTL P2)

`make tang` (Yosys 0.71 + nextpnr-himbaechel-gowin 0.11.1 + apycula), `--freq 50.4`: **exit 0**, clk_sys
**82,30 MHz** e clk_pix 86,74 MHz após o roteamento (P1 modificada: 117,98 / 83,76 MHz), BSRAM 44/46
(`logs/tang_p2/`). Sem validação em silício.
