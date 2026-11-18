# Guia de teste em hardware: ECP5-P2 (Colorlight i9 v7.2 + Ext-Board)

**HARDWARE VALIDATION: PENDING.** Nada abaixo foi executado: é o roteiro para quando houver a placa.
As etapas 0–4 do guia da P1 (`docs/p1/HARDWARE_TEST_GUIDE.md`: material, VCCIO do banco 2, programação, vídeo,
áudio/fase da SDRAM) valem sem mudanças, trocando o arquivo por `artifacts/vdpx_ecp5_p2.bit`.
**Não ligar o CN2 nesta fase.**

## 1. Programação

```sh
sha256sum artifacts/vdpx_ecp5_p2.bit     # deve bater com SHA256SUMS e logs/ecp5_build/report.md
openFPGALoader -c cmsisdap artifacts/vdpx_ecp5_p2.bit          # SRAM (volátil)
```

Sugestão: validar **primeiro a P1** (`git checkout` da entrega P1, `VDPX_ECP5_P1_delivery/artifacts/`) para
separar problemas de placa (VCCIO, fase da SDRAM, monitor) de problemas da P2.

## 2. O que muda na tela em relação à P1

| Elemento | P1 | P2 |
|---|---|---|
| Painel de diagnóstico | 9 linhas a partir da linha de texto 21 | **11 linhas a partir da linha 19** (2 linhas de DMA no fim) |
| Linhas 5 e 6 do plano A | vazias | **faixa animada** de tiles 0x60/0x61, escrita por DMA PATTERN (na 1ª com VSYNC) |
| Tiles 0x60/0x61 | não usados | limpos por DMA FILL e trocados a cada quadro por DMA COPY (SDRAM → VRAM, 32 words) |

Resultado esperado das linhas de DMA (valores da simulação da placa inteira, `logs/ecp5_sim/ecp5_boardsim.log`):

```
DMA DONE OP COPY FILA 0 ERROS 0000
PAL 0020 CIC 0000B0 018.1MB/S ST xxxx
```

- `DONE` / `COPY` / `FILA 0` / `ERROS 0000`: o último comando foi um COPY que terminou, e nenhum foi rejeitado.
- `PAL 0020`: 32 words por COPY. `CIC`: ciclos de 50 MHz do último comando, em hexadecimal (0xB0 = 176 na simulação).
- `MB/S`: taxa do último comando. Na placa real ela depende da fase da SDRAM aprovada na etapa 4 da P1. **Anotar o
  valor exibido**: esta é a primeira medição física de desempenho do DMA.
- `ST`: ciclos em que o DMA esperou o árbitro ou a SDRAM (a simulação da placa não confere este campo; anotar).

## 3. Verificações da P2

| # | Verificação | Critério de aprovação |
|---|---|---|
| 1 | Faixa animada nas linhas 5–6 | Tiles mudam a cada quadro, sem lixo; as cores da linha 5 (paleta 3) e da linha 6 (paleta 5) são diferentes |
| 2 | `ERROS` | Permanece `0000` por ≥ 10 minutos |
| 3 | `PAL`, `CIC`, `MB/S` | `PAL 0020`; `CIC` estável (variação de poucos ciclos por causa do refresh e da APU) |
| 4 | Áudio | Música e kick PCM idênticos ao bitstream P1 (o DMA divide a SDRAM com a APU); sem estalos |
| 5 | Resto da tela | Igual à P1: degradê, "VDPX OK", amostras de cor, bolas, chão |
| 6 | Tearing na faixa | O COPY roda logo depois do WAITVB do roteiro, portanto no vblank: **não deve** haver tearing visível. Se houver, anotar (é risco R-P2-3 em `RISKS_AND_BLOCKERS.md`) |
| 7 | LED L2 | Pisca lento (autoteste ativo), como na P1 |

## 4. Diagnóstico

- **Faixa congelada com `ERROS 0000` e `IDLE`:** o roteiro do autoteste não chega ao DMA. Confirmar o hash (o
  bitstream da P1 não tem DMA).
- **Faixa com lixo e áudio PCM também ruidoso:** janela de leitura da SDRAM (fase); repetir a varredura da P1.
- **Faixa com lixo e áudio limpo:** suspeitar da leitura em par (`rdata_hi`). Registrar uma foto do padrão. Os
  tiles 0x60/0x61 em quadros alternados devem ser os 4 quadros de `scripts/gen_selftest.py --dma`.
- **`MB/S` muito abaixo do simulado (< 15):** anotar a fase da SDRAM; o controlador acrescenta ciclos de captura
  conforme a configuração R2/R3.

## 5. O que registrar

Tudo da etapa 6 da P1, mais: foto do painel com as duas linhas de DMA, valor de `CIC` e `MB/S` (mín./máx. em
1 minuto), presença de tearing na faixa, tempo sem `ERROS`. Só com esse registro **DMA PERFORMANCE** pode passar de
"simulado" para "medido em hardware".

## 6. Testes com Mega Drive (fase futura)

O benchmark com o 68000 (`m68k/bench/`) só existe em co-simulação (fx68k). Um ROM real de benchmark depende da
interface CN2 validada (pendências da M4.2/P1) e não faz parte desta fase.
