# MD-VDPX: fase ECP5-P1 (Colorlight i9 v7.2 + Ext-Board HDMI)

Porte da VDPX M4.2 Claude (Tang Nano 20K) para a **Colorlight i9 v7.2 (LFE5U-45F-6BG381C, grau -6)** com a
Ext-Board i5/i9. Esta pasta é uma árvore completa e independente. A M4.2 original fica intacta em
`../m42_reference/md-vdpx-M4.2-claude/`.

## Status

| Item | Status |
|---|---|
| **P1 SIMULATION PASS** | sim (critérios do §14, ver `RELATORIO_TECNICO.md`) |
| Timing 50 MHz (3 sementes) | **PASS**, margem ≥ 10% em todas (`TIMING_REPORT.md`) |
| Vídeo DVI/TMDS (serial decodificado) | **VIDEO PASS** |
| HDMI com áudio | **HDMI_AUDIO PASS (simulação)** |
| SDRAM 32 bits sem DQM | **PASS (simulação, atrasos de placa de pior caso)** |
| CN2 somente escrita, sonda, autoteste | **PASS** |
| PCM1808 (clock limpo) | **BLOCKED** |
| **HARDWARE VALIDATION** | **PENDING** (nenhuma placa usada) |
| Bitstream | `artifacts/vdpx_ecp5_p1.bit` (hash em `SHA256SUMS` e `logs/ecp5_build/report.md`) |

## Documentos

| Arquivo | Conteúdo |
|---|---|
| `RELATORIO_TECNICO.md` | Visão geral, critérios de aprovação, decisões |
| `TIMING_REPORT.md` / `CRITICAL_PATHS.md` | Fmax/slack por domínio e semente; caminhos críticos antes e depois |
| `HDMI_EXT_BOARD.md` / `HDMI_PINOUT.md` | Análise elétrica da Ext-Board, pinagem, bancos, variantes de placa |
| `HDMI_TEST_REPORT.md` | Testes de TMDS/HDMI decodificados do serial |
| `AUDIO_CLOCK_REPORT.md` | 48 kHz a 50 MHz, ACR, PCM1808 |
| `SDRAM_32BIT_REPORT.md` | RMW sem DQM, temporização da SDRAM externa |
| `RESOURCE_REPORT.md` / `COMPARISON_TANG_ECP5.md` | Uso da FPGA, VRAM 128/192 KiB, comparação com a Tang |
| `REGRESSION_REPORT.md` | Todos os testes executados e resultados |
| `HARDWARE_TEST_GUIDE.md` | Roteiro para a placa real |
| `RISKS_AND_BLOCKERS.md` | Pendências classificadas |
| `CHANGELOG.md` | O que mudou em relação à M4.2 |

## Reproduzir

Ferramentas: Verilator (5.020 usado), Icarus Verilog (12), gcc 68000 (`m68k-linux-gnu-` ou `m68k-elf-`), Python 3
+ Pillow, Yosys / nextpnr-ecp5 / ecppack (nativos ou YoWASP: `pip install yowasp-yosys yowasp-nextpnr-ecp5`).

```sh
./scripts/run_p1_all.sh            # tudo: regressão M4.2, testes ECP5, síntese, P&R x3, bitstream, relatórios
YOWASP=1 ./scripts/run_p1_all.sh   # com as ferramentas YoWASP no PATH

# ou passo a passo
make all_tests          # regressão M4.2 (parâmetros da Tang) com o RTL modificado
make ecp5_test          # unitários (SDRAM, HDMI) + 17 cenas a 50 MHz + M2WO a 50 MHz + placa ECP5
make ecp5               # = ecp5_synth ecp5_pnr ecp5_bitstream ecp5_report
python3 scripts/ecp5_audit.py
```

O fx68k (GPL-3) é baixado em `ext/fx68k` pelos alvos M2 e não faz parte da entrega. Os logs da execução que gerou
esta entrega estão em `logs/` (`logs/RUN_SUMMARY.txt`, `logs/versions.txt`).

## Estrutura

```
rtl/            núcleo VDPX (comum), rtl/board (placa), rtl/hdmi, rtl/ecp5 (topo, núcleo e serializador ECP5)
board/          colorlight_i9_v72_extboard.lpf, tabela de bancos, baseline_study/; arquivos da Tang preservados
sim/            testbenches M1–M4.2; sim/ecp5 (placa ECP5, HDMI unitário, SDRAM RMW, modelo ODDRX1F)
scripts/        geradores, auditoria, relatório, execução completa
m68k/, scenes/  programas 68000 e cenas de teste (como na M4.2)
logs/           saídas com comandos e exit codes; baseline_m42/ e timing_progression/
artifacts/      vdpx_ecp5_p1.bit
docs/           especificação M0, relatórios M4.2, README da M4.2, evidências do esquema
M4_2_delivery/  entrega M4.2 original (histórico)
```
