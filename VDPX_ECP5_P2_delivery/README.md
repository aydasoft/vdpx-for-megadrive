# MD-VDPX: fase ECP5-P2 (DMA/Blitter)

Motor de DMA/Blitter interno para a VDPX na Colorlight i9 v7.2 (LFE5U-45F-6BG381C) + Ext-Board HDMI, sobre a
entrega ECP5-P1. A P1 original fica intacta em `../VDPX_ECP5_P1_delivery/`, e a M4.2 em `../m42_reference/`.
Esta pasta é uma árvore completa e independente.

Limites desta fase:
- sem segunda CPU;
- VRAM continua com 64 KiB;
- interface com o console continua somente escrita (sem /DTACK, sem leitura por /CAS0);
- `$A1200E/F` sem uso;
- o target 7 e os 16 registradores de `REG_SEL` continuam inalterados.

## Status

| Item | Status |
|---|---|
| **DMA FUNCTIONAL** | **PASS** (simulação: unitário + 3 mutações, 7 cenas com scoreboard, placas Tang/ECP5, fx68k). `DMA_TEST_REPORT.md` |
| **DMA PERFORMANCE** | **MEASURED (simulação)**: FILL/PATTERN 100 MB/s; COPY 19,8 MB/s (18,9 MB/s com PCM; 18,2 MB/s na placa ECP5 simulada); 68000 pela CN2 1,27 MB/s. `DMA_BENCHMARKS.md` |
| **TIMING** | **PASS**, 3/3 sementes, clk_sys ≥ 65,33 MHz (+30,7 %). `TIMING_REPORT.md` |
| **AUDIO INTEGRITY** | **PASS** (0 amostras erradas; prazo da APU ≤ 387/1041 ciclos). `AUDIO_INTEGRITY_REPORT.md` |
| Regressão gráfica | PASS: tempo de renderização idêntico à P1 nas 17 cenas da P1, todos os quadros iguais ao modelo. **Tearing possível** fora do vblank. `GRAPHICS_REGRESSION.md` |
| **P2 SIMULATION** | **PASS** |
| **HARDWARE VALIDATION** | **PENDING** (nenhuma placa usada) |
| Bitstream | `artifacts/vdpx_ecp5_p2.bit`, sha256 `7eda4c78c020d2e0e899b6754d0fc38a6890ef75b28358f144e5764f6f81f986` |

## Documentos

| Arquivo | Conteúdo |
|---|---|
| `RELATORIO_TECNICO.md` | Visão geral, decisões, conclusões |
| `DMA_ARCHITECTURE.md` | Blocos, operações, estados, latências, reset/VBlank |
| `DMA_REGISTER_MAP.md` | Target 6, registradores, commit atômico, validação, protocolo somente-escrita |
| `DMA_ARBITRATION.md` | VRAM (CPU > DMA, renderizador na outra porta), SDRAM (APU > DMA), fila, CANCEL, tearing |
| `DMA_MEMORY_SAFETY.md` | Tabela de políticas ACCEPT/REJECT por caso, sem wraparound |
| `DMA_TEST_REPORT.md` | Testes, scoreboards e resultados |
| `DMA_BENCHMARKS.md` | 68000 × DMA, 256 B a 64 KiB, repouso, renderização pesada, PCM |
| `AUDIO_INTEGRITY_REPORT.md` / `GRAPHICS_REGRESSION.md` | Impacto na APU e no renderizador |
| `TIMING_REPORT.md` / `RESOURCE_REPORT.md` / `P1_P2_COMPARISON.md` | Síntese, timing e recursos |
| `RISKS_AND_BLOCKERS.md` | Pendências (mais as da P1) |
| `HARDWARE_TEST_GUIDE.md` | Roteiro para a placa |
| `CHANGELOG.md` | Mudanças em relação à P1 |
| `docs/p1/` | Documentos da P1, para referência (HDMI, SDRAM, áudio, pinagem) |

## Reproduzir

Ferramentas: Verilator (5.020), Icarus Verilog (12), gcc 68000 (`m68k-linux-gnu-` ou `m68k-elf-`), Python 3 +
Pillow, Yosys / nextpnr-ecp5 / ecppack (nativos ou YoWASP).

```sh
./scripts/run_p2_all.sh            # tudo: regressão P1, DMA, benchmarks, síntese, P&R x3, bitstream, auditoria
YOWASP=1 ./scripts/run_p2_all.sh   # com as ferramentas YoWASP no PATH

# ou passo a passo
make all_tests          # regressão M4.2 (parâmetros da Tang) com o RTL da P2 (inclui as 7 cenas de DMA)
make ecp5_test          # unitários ECP5 + 24 cenas a 50 MHz + M2WO50 + placa ECP5 + dma_unit + m2bench
make dma_unit           # só o teste unitário do DMA + mutações
make m2bench p2_bench_report   # benchmark 68000 x DMA e tabelas
make ecp5               # síntese, P&R (3 sementes), bitstream, relatório
python3 scripts/ecp5_audit.py
make tang YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-himbaechel-gowin GWPACK=gowin_pack   # build da Tang
```

Execução usada nesta entrega: `logs/RUN_SUMMARY.txt` (14 etapas, todas com exit 0) e `logs/versions.txt`. O
build da Tang está em `logs/tang_p2/`. O fx68k (GPL-3) é baixado em `ext/fx68k` e não faz parte da entrega.

## Estrutura

```
rtl/            núcleo VDPX (+ vdpx_dma.v), rtl/board, rtl/hdmi, rtl/ecp5
board/          LPF da i9 + Ext-Board, arquivos da Tang
sim/            testbenches; sim/p2 (unitário do DMA, modelo de referência e scoreboard do DMA)
scripts/        geradores (cenas, autoteste, painel), relatórios, execução completa
m68k/           programas 68000; m68k/bench (benchmark P2)
scenes/         24 cenas (17 da P1 + 7 de DMA)
logs/           saídas da execução (logs/p1_history: logs da P1)
artifacts/      vdpx_ecp5_p2.bit
docs/           especificação, relatórios M4.2, docs/p1
M4_2_delivery/  entrega M4.2 original (histórico)
```
