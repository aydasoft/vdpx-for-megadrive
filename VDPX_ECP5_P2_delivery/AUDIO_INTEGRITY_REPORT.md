# Integridade de áudio com DMA (ECP5-P2)

**AUDIO INTEGRITY: PASS (simulação).** Em hardware: PENDING.

## Por que o DMA pode afetar o áudio

A APU busca os samples PCM na mesma SDRAM de onde o DMA COPY lê. O árbitro (`DMA_ARBITRATION.md` §2) dá
prioridade à porta da APU, mas é não-preemptivo: um acesso do DMA em curso atrasa a APU em até um acesso. O risco é
a APU não terminar a mistura dentro do quadro de amostra (1041 ciclos a 48 kHz). FILL/PATTERN não usam a SDRAM.

## Prazo da APU (monitor `APU_DEADLINE`, maior tempo tick 48 kHz → amostra pronta)

| Cena (SDRAM RMW real, 50 MHz) | DMA na SDRAM? | Pior caso | % do quadro |
|---|---|---|---|
| Cenas da P1 sem vozes PCM / sem DMA | não | 224 ciclos | 22 % |
| `audio_rand0..3`, `audio_musica`, `audio_md` (P1, sem DMA) | não | 236–312 ciclos | ≤ 30 % |
| `dma_bench`, condição PCM (vozes PCM + COPY de até 64 KiB) | sim | 323 ciclos | 31 % |
| **`dma_pcm`** (8 vozes PCM em loop + 8 wavetable + escritas da CPU na memória de samples + COPY/FILL contínuos) | sim | **387 ciclos** | **37 %** |

Pior caso medido com DMA: 387 de 1041 ciclos, com folga de 654 ciclos. O monitor não existia na P1, portanto não há
coluna "P1" com o mesmo instrumento. As cenas da P1 foram medidas agora, com o RTL da P2 e sem DMA ativo.

## Áudio bit a bit

Toda amostra produzida pelo RTL é comparada com o modelo de referência da APU (mixer em C++). Qualquer amostra
atrasada, perdida ou com o sample errado da SDRAM faria a comparação falhar.

| Banco de teste | Amostras conferidas | Erradas |
|---|---|---|
| `test50`, 24 cenas (inclui `dma_pcm`, `dma_bench`, `dma_render`) | 358.727 | **0** |
| `dma_pcm` sozinha | 17.687 | 0 |
| `all_tests` (modelo comportamental, parâmetros Tang) | todas as cenas | 0 |
| `m2wo50` (fx68k) | 30.877 | 0 |
| `m2bench` (fx68k, DMA de até 64 KiB) | 22.927 | 0 |
| ECP5 placa inteira, HDMI serial decodificado: MD + autoteste / autoteste (DMA COPY a cada quadro) | 33.869 / 11.290 | 0 / 0 |

Pacotes HDMI: ACR N = 6144, CTS = 25000 (exato para 25 MHz); 0 erros HDMI; `áudio_ovf = 0` nas 3 execuções da
placa. A taxa medida do mixer é 48.000,000 Hz (47.995 Hz na execução com perda de lock do PLL, que inclui o reset).

## Conclusão

- **AUDIO INTEGRITY PASS:** nenhuma amostra errada em nenhum banco de teste com DMA ativo, e o prazo da APU usa no
  máximo 37 % do quadro.
- **Limite:** a medição cobre os padrões de acesso das cenas; não há prova formal de pior caso (ver
  `DMA_ARBITRATION.md` §2 e o risco R-P2-2).
