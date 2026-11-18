# Recursos: LFE5U-45F-6BG381C

Fonte: `logs/ecp5_build/report.json` (utilização pós-P&R, idêntica nas 3 sementes) e `synth_stat.txt`.

| Recurso | Usado | Disponível | % |
|---|---|---|---|
| Lógica (TRELLIS_COMB: LUT4 + carry + LUT RAM) | 7 655 | 43 848 | **17%** |
| ↳ síntese: LUT4 3 927, CCU2C 932 (2 LUT cada), TRELLIS_DPR16X4 161 | | | |
| Flip-flops (TRELLIS_FF) | 3 055 | 43 848 | 7% |
| LUT RAM (TRELLIS_RAMW) | 161 | 5 481 | 3% |
| **EBR (DP16KD, 18 Kbit)** | **44** | 108 | **41%** |
| DSP (MULT18X18D) | 2 | 72 | 3% |
| PLL (EHXPLLL) | 1 (4 saídas) | 4 | 25% |
| Clocks globais (DCCA) | 4 | 56 | 7% |
| E/S (TRELLIS_IO) | 83 | 245 | 34% |
| IOLOGIC/SIOLOGIC (ODDRX1F) | 5 | 245 | 2% |

## EBR por memória (mapeamento do Yosys)

VRAM 64 KiB (32 blocos), SAT, CRAM, 3 line buffers (A, B, sprites), 2 ROMs do painel e a ROM do autoteste (4096 ×
24) ficam em DP16KD. VSRAM, lista de sprites, FIFOs, registradores da APU e posições/fases ficam em RAM distribuída.
A VRAM continua **SDP com latência de 1 ciclo**, como na M4.2. O renderizador tem prioridade na porta de leitura e
a CPU usa os ciclos livres; os estados novos (`T_AD`, `D_AD`) só dão à CPU mais ciclos livres.

## Viabilidade de VRAM maior (só análise, nada implementado)

| Configuração | EBR da VRAM | EBR total | Endereçamento | Viável? |
|---|---|---|---|---|
| 64 KiB (atual) | 32 | 44 / 108 (41%) | 15 bits de word | sim |
| **128 KiB** | 64 | **76 / 108 (70%)** | 16 bits de word: `ACC_ADDR`, bases e `vaddr` do renderizador já têm 16 bits; o número de tile (14 bits × 16 words) já endereça 512 KiB | **Sim.** Exige alargar `vaddr`/`r_vaddr` para 16 bits e a VRAM para AW=16. O mux de leitura de 64 blocos acrescenta 1 nível de lógica no caminho BRAM → registrador (há folga de ~5,5 ns). |
| 192 KiB | 96 | **108 / 108 (100%)** | 17 bits (≥ 64K words): `ACC_ADDR_HI` para a VRAM, bases > 16 bits | **Não só em EBR**: esgota a FPGA (sem espaço para ROMs, DMA ou CPU). Alternativas: tirar a ROM do autoteste da EBR (−6, carregar da flash SPI), ou VRAM híbrida EBR + SDRAM/cache. |

## Estimativas para fases futuras (não estão no RTL da P1)

| Recurso futuro | Lógica estimada | EBR | Observação |
|---|---|---|---|
| DMA/blitter (cópia SDRAM/flash → VRAM, fill) | ~400–800 LUT | 0–1 | maior ganho por custo |
| Sub-CPU TG68K | ~3–4 mil LUT | +32 para 64 KiB de RAM de programa | conflita com VRAM de 128 KiB (76 + 32 = 108) |
| Sub-CPU fx68k | ~5–7 mil LUT | +3–4 (micro/nanoROM) + RAM | GPL-3 |
| Plano C / tiles 8bpp | ~1–2 mil LUT | +2 (line buffer) | orçamento por linha: 2349 de 3200 ciclos hoje |

Estimativas, não medições. A lógica (17% usados) não limita; a EBR é o recurso que decide entre VRAM maior e
RAM de CPU.
