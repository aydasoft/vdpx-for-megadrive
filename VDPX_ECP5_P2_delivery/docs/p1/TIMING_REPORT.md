# Relatório de timing: LFE5U-45F-6BG381C

Ferramentas: Yosys 0.71 + nextpnr-ecp5 0.11.1 (YoWASP), `--45k --package CABGA381 --speed 6`, sementes 1, 2 e 3
(determinísticas), restrição `FREQUENCY PORT clk25 25 MHZ`. O nextpnr deriva os domínios das saídas do EHXPLLL.
Fonte: `logs/ecp5_build/report.json`, `report.md`, `pnr_s{1,2,3}.log`.

## Resultado: **TIMING = PASS** (3/3 sementes, margem ≥ 10% em todos os domínios)

| Semente | clk_sys (meta 50 MHz) | clk_pix (meta 25 MHz) | clk_x5 (meta 125 MHz) | exit nextpnr | avisos |
|---|---|---|---|---|---|
| 1 | **69,30 MHz** (+38,6%, slack +5,57 ns) | 76,32 MHz (+205%, +26,9 ns) | 283,5 MHz (+127%, +4,47 ns) | 0 | 0 |
| 2 | **71,19 MHz** (+42,4%, slack +5,95 ns) | 74,26 MHz (+197%, +26,5 ns) | 251,5 MHz (+101%, +4,02 ns) | 0 | 0 |
| 3 | **70,25 MHz** (+40,5%, slack +5,77 ns) | 72,01 MHz (+188%, +26,1 ns) | 279,5 MHz (+124%, +4,42 ns) | 0 | 0 |

Bitstream gerado da semente 1. O clock da SDRAM (CLKOS3, 50 MHz a 288°) só alimenta um `ODDRX1F` (pino) e não tem
lógica síncrona.

## Evolução do clock de sistema (caminhos em `CRITICAL_PATHS.md`)

| Etapa | clk_sys | Topo usado | Log |
|---|---|---|---|
| M4.2 sem modificação | 40,16 / 39,54 / 39,50 MHz (**FAIL**) | estudo (LPF parcial) | `logs/baseline_m42/ecp5_m42_unmodified_pnr_s*.log.gz` |
| 1. Produto 3×4 por soma/deslocamento | 45,96 / 46,86 / 44,92 MHz | estudo | `logs/timing_progression/step1_*` |
| 2. Estado `D_AD` (sprite) | 47,78 MHz (s1) | estudo | `step2_*` |
| 3. Multiplicador da APU com registros | 47,95 MHz (s1) | estudo | `step3_*` |
| 4. Estado `T_AD` (planos) | 50,51 MHz (s1) | estudo | `step4_*` |
| 5. Painel: double dabble registrado | 61,95 / 59,07 / 63,95 MHz | estudo | `step5_*` |
| (topo real, LPF completo, antes da etapa 6) | 56,75 / 54,62 / 52,87 MHz | real | — |
| 6. Painel: registro ROM → mux | 66,9 / 72,5 / 68,9 MHz | real | — |
| **Final** (+ SDRAM RMW, CLKOS3, RD_CAPTURE 3) | **69,30 / 71,19 / 70,25 MHz** | real | `logs/ecp5_build/` |

O topo de estudo (`board/baseline_study/`) só restringia clock, SDRAM e HDMI. O topo real, com todas as E/S
fixadas, perdeu ~8 MHz até a etapa 6 corrigir o caminho do painel.

## Caminhos entre domínios (não restringidos pelo nextpnr: só reportados)

| De → para | Atraso máximo (s1/s2/s3) | Mecanismo | Avaliação |
|---|---|---|---|
| clk_pix → clk_x5 | 1,68 / 1,80 / 1,80 ns | toggle + 2 FFs; símbolo estável 5 ciclos, carga 3 ciclos depois | clocks do mesmo VCO; 24 ns disponíveis → OK |
| clk_sys → clk_pix | 1,52 / 1,47 / 1,48 ns | FIFO de vídeo com ponteiros Gray (M4.2) | OK por construção |
| clk_pix → clk_sys | 1,25 / 1,60 / 1,24 ns | idem (sincronizadores) | OK |
| clk_sys → `<async>` (saídas) | 9,61 / 8,65 / 10,25 ns | pior caso: LED; SDRAM em `SDRAM_32BIT_REPORT.md` | LED irrelevante |
| `<async>` → clk_sys (entradas) | 6,27 / 6,49 / 5,98 ns | md_d → FIFO do adaptador ("bundled data" capturado após o strobe sincronizado) | como na M4.2 |
| clk_pix → `<async>` | 8,78 / 8,47 / 9,04 ns | I2S/LED (registrados) | OK |

O fechamento global não se baseia só na Fmax de clk_sys: os três domínios síncronos passam com margem, e os
cruzamentos são por construção (FIFO Gray, toggle + sincronizador, clocks relacionados).

## E/S da SDRAM (fora da STA)

Roteamento máximo no FPGA (s1/s2/s3): comando 2,83/3,19/3,06 ns, DQ saída 3,36/2,88/2,91 ns, DQ entrada/OE
4,99/5,56/5,86 ns. O orçamento com o datasheet usa 3,5 ns (comando) e 6 ns (+1 ns de buffer) de entrada:
`SDRAM_32BIT_REPORT.md` §4. **Status: cálculo + simulação com janela de pior caso; não é STA.**

## Tang (comparação, mesmo RTL comum modificado)

`make tang` (Yosys 0.71 + nextpnr-himbaechel-gowin 0.11.1 + apycula), `--freq 50.4` para os dois clocks:
**exit 0**, clk_sys 117,98 MHz e clk_pix 83,76 MHz após o roteamento, 43/46 BSRAM (`logs/tang_modified/`). A
versão do nextpnr Gowin é mais nova que a da M4.2 (57,7 MHz lá): os números não são diretamente comparáveis, mas
o RTL modificado continua cabendo e fechando na Tang. **Sem validação em silício.**
