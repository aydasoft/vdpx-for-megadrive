# Recursos (ECP5-P2): LFE5U-45F-6BG381C

Fonte: `logs/ecp5_build/report.json` (pós-P&R, idêntico nas 3 sementes) e `synth_stat.txt`.

| Recurso | Usado | Disponível | % |
|---|---|---|---|
| Lógica (TRELLIS_COMB) | 9 021 | 43 848 | **21 %** |
| ↳ síntese: LUT4 4 619, CCU2C 1 129, TRELLIS_DPR16X4 183 | | | |
| Flip-flops (TRELLIS_FF) | 3 715 | 43 848 | 8 % |
| LUT RAM (TRELLIS_RAMW) | 183 | 5 481 | 3 % |
| **EBR (DP16KD)** | **48** | 108 | **44 %** |
| DSP (MULT18X18D) | 4 | 72 | 6 % |
| PLL (EHXPLLL) | 1 | 4 | 25 % |
| Clocks globais (DCCA) | 4 | 56 | 7 % |
| E/S (TRELLIS_IO) | 83 | 245 | 34 % |
| IOLOGIC + SIOLOGIC (ODDRX1F) | 5 | 245 | 2 % |

## De onde vem o acréscimo da P2

| Item | Δ | Atribuição |
|---|---|---|
| TRELLIS_COMB | +1 366 | motor DMA (validação de 17 bits, contadores, divisor sequencial + BCD, fila), muxes da porta de escrita da VRAM e do árbitro da SDRAM, 2 linhas novas do painel |
| TRELLIS_FF | +660 | registradores de preparação (6×16), estado do motor, estatísticas (contadores de 16/24 bits), divisor |
| LUT RAM | +22 | fila do DMA (4 × 96 bits) em RAM distribuída |
| EBR | +4 | ROM do autoteste dobrada (4096 → 8192 words × 24 bits) para a demonstração do DMA. O DMA não usa EBR |
| DSP | +2 | `× 1000` do numerador da taxa (estatística) |

Atribuição por inspeção do RTL e do log de síntese (Yosys não dá a utilização por módulo depois do achatamento). Os
totais são exatos.

## Orçamento restante (a decisão da próxima fase)

- **Lógica:** 79 % livre. Não limita nada planejado.
- **EBR:** 60 blocos livres. VRAM de 128 KiB (+32) cabe (80/108). Sub-CPU com 64 KiB de RAM (+32) também cabe, mas
  não as duas juntas (112 > 108). Remover a ROM de demonstração do autoteste devolve 4 blocos. A conclusão da P1
  continua: a EBR decide.
- **Tang:** BSRAM 44/46 (95 %). O RTL comum da P2 ainda cabe, mas sem espaço para mais memória.
