# Relatório de testes do DMA (ECP5-P2)

**P2 SIMULATION: PASS. HARDWARE VALIDATION: PENDING.**

Execução completa e reprodutível: `scripts/run_p2_all.sh`. Resumo em `logs/RUN_SUMMARY.txt`: 14 etapas, todas
com exit 0.

| Etapa | Comando | Log | Resultado |
|---|---|---|---|
| Regressão M4.2 (parâmetros Tang, RTL modificado) | `make all_tests` | `logs/regression/all_tests_tangparams.log` | **PASS** (`== TODOS OS TESTES OK ==`) |
| Lint ECP5 (Verilator `-Wall`) | `make ecp5_lint` | `logs/ecp5_unit/ecp5_lint.log` | exit 0; os mesmos 25 avisos da P1 (HDMI/painel herdados da M4.2), **nenhum em `vdpx_dma.v`** nem novo |
| Unitários ECP5 (SDRAM RMW, HDMI, auditoria LPF/PLL) | `make ecp5_unit` | `logs/ecp5_unit/ecp5_unit.log` | PASS (inclui 2 testes negativos) |
| 24 cenas a 50 MHz com a SDRAM RMW real | `make test50` | `logs/ecp5_sim/test50.log` | **24/24 OK** |
| fx68k + adaptador somente escrita a 50 MHz | `make m2wo50` | `logs/ecp5_sim/m2wo50.log` | PASS |
| Placa ECP5 inteira (3 execuções) | `make ecp5_boardsim` | `logs/ecp5_sim/ecp5_boardsim.log` | PASS (inclui o painel DMA) |
| **Unitário do DMA + 3 mutações** | `make dma_unit` | `logs/p2/dma_unit.log` | **PASS**; as 3 mutações falham como esperado |
| **Benchmark fx68k** | `make m2bench` | `logs/p2/m2bench.log` | PASS |
| Síntese + P&R × 3 + bitstream + auditoria | `make ecp5` etc. | `logs/ecp5_build/` | PASS (`TIMING_REPORT.md`) |
| Tang (RTL P2, fora do script) | `make tang` | `logs/tang_p2/` | exit 0, timing PASS, 44/46 BSRAM |

## 1. Teste unitário (`sim/p2/tb_dma_unit.sv`, Icarus)

Semente fixa `0x0DA00001`.

Ambiente:
- CPU concorrente com prioridade na porta de escrita, com probabilidade de bloqueio variável (30–98 %);
- memória de samples com latência aleatória e espera atrás de "outro dono";
- espaço de 2^16 words, para exercitar o fim da memória.

Scoreboard independente do RTL:
- validação por especificação (código esperado para cada commit);
- fluxo de escrita esperado (endereço, dado e ordem);
- words por comando, contabilidade de cancel/flush;
- regras de handshake.

| Item | Valor |
|---|---|
| Comandos dirigidos | 32 (19 aceitos, 13 rejeitados), mais os testes de índice 6 e CANCEL ocioso |
| Comandos totais | 2657 aceitos, 1375 rejeitados, 2411 concluídos, 226 cancelados/descartados |
| Rejeições por código | ZERO 508, DST 522, SRC 18, FILA 209, INCOMPLETO 3, OP 115 |
| Words escritas pelo DMA / escritas de CPU concorrentes | 393.722 / 691.821 |
| Erros | 0 |
| Mutação 1: PATTERN sempre VALUE0 | detectada (falha) |
| Mutação 2: fonte do par avança 1 | detectada (falha) |
| Mutação 3: sem a checagem `DST + LEN > 32768` | detectada (falha) |

## 2. Integração: scoreboard `DmaCheck` nas cenas (`test50`, SDRAM RMW real)

`RefDMA` (dentro de `sim/refmodel.h`) é o modelo de referência. Ele recebe as mesmas escritas que a CPU fez, prevê
aceitação/rejeição e o fluxo de escrita de cada comando. O `DmaCheck` confere cada escrita do DMA na porta da VRAM
(endereço e dado) e cada evento (aceito, rejeitado + código, fim, cancelado, descartados). As escritas da CPU na
VRAM são conferidas na ordem da porta. Por fim, os quadros HDMI são comparados pixel a pixel com o modelo.

| Cena | Aceitos | Rejeitados (fila) | Concluídos | Cancelados (da fila) | Words DMA conferidas | Escritas CPU na porta | Escritas DMA com render ocupado | Fila máx. | Quadros | Erros | Resultado |
|---|---|---|---|---|---|---|---|---|---|---|---|
| dma_basic | 50 | 0 (0) | 50 | 0 (0) | 9.789 | 0 | 4.394 | 2 | 2 | 0 | OK |
| dma_bench | 54 | 0 (0) | 54 | 0 (0) | 540.288 | 12.736 | 283.226 | 1 | 0 | 0 | OK |
| dma_cpu | 2 | 0 (0) | 2 | 0 (0) | 8.192 | 2.548 | 4.131 | 1 | 1 | 0 | OK |
| dma_errors | 13 | 17 (2) | 9 | 4 (2) | 25.649 | 1.024 | 2.985 | 4 | 1 | 0 | OK |
| dma_pcm | 40 | 0 (0) | 40 | 0 (0) | 71.680 | 1.024 | 27.390 | 3 | 1 | 0 | OK |
| dma_render | 20 | 0 (0) | 20 | 0 (0) | 81.904 | 12.736 | 55.459 | 4 | 5 | 0 | OK |
| dma_vsync | 3 | 0 (0) | 3 | 0 (0) | 1.536 | 8.704 | **0** | 1 | 3 | 0 | OK |

As 7 cenas de DMA também passam no modelo de memória comportamental (`make test`, dentro de `all_tests`).

O que cada cena cobre:
- **dma_basic:** FILL/COPY/PATTERN de vários tamanhos e alinhamentos, origem ímpar e comprimento ímpar.
- **dma_render:** comandos lançados no meio do quadro, sobrepostos à renderização (55.459 escritas com o
  renderizador ocupado). Os 5 quadros conferem pixel a pixel.
- **dma_pcm:** 8 vozes PCM + 8 wavetable, com escritas da CPU na memória de samples e COPY/FILL em paralelo. O áudio
  confere bit a bit (`AUDIO_INTEGRITY_REPORT.md`).
- **dma_errors:** todos os códigos de rejeição, fila cheia, CANCEL durante COPY e durante FILL, CANCEL ocioso,
  parâmetros alterados depois do commit.
- **dma_cpu:** CPU e DMA escrevendo na VRAM ao mesmo tempo (ordem da porta).
- **dma_vsync:** comandos com o bit VSYNC. **0 escritas** com o renderizador ocupado: os comandos só começaram no
  vblank e terminaram antes da primeira linha.
- **dma_bench:** os benchmarks (`DMA_BENCHMARKS.md`).

## 3. Placas

| Banco de teste | Resultado DMA |
|---|---|
| Tang (M4, `tb_m4`, autoteste da Tang sem DMA) | painel `IDLE ---- 0`, conforme esperado; 6/6 quadros iguais ao modelo |
| ECP5 (`tb_ecp5`, 3 execuções: MD + autoteste, autoteste, perda de lock do PLL) | 15 / 17 / 24 comandos aceitos, 0 rejeitados, 672 / 736 / 1152 words conferidas, 0 erros. Painel lido por OCR: `DONE COPY palavras 32 ciclos 176 taxa 18.1 MB/s fila 0 erros 0` (esperado 18.1) |
| fx68k (`tb_m2wo`, M2WO50) | regressão da M4.2 com o 68000 real: OK |
| fx68k benchmark (`M2_BENCH`) | 6 comandos, 60.032 words conferidas, 0 erros. O TB falha se o DMA ainda estiver ocupado no marcador B8 (espera fixa); não falhou |

## 4. Regressão P1

Todos os testes da P1 continuam passando com o RTL da P2: `all_tests`, `ecp5_unit`, `test50`, `m2wo50` e
`ecp5_boardsim`. Detalhes em `GRAPHICS_REGRESSION.md` e `AUDIO_INTEGRITY_REPORT.md`. Nenhuma assertiva foi
enfraquecida e nenhum modelo de referência foi alterado para passar. As alterações em modelos e TBs da P1 são
acréscimos:
- o target 6 no modelo;
- as escritas de CPU na VRAM conferidas na ordem da porta, o que é mais estrito que antes;
- a área de comparação do painel da placa reduzida de 21 para 19 linhas de texto, porque o painel ficou 2 linhas
  mais alto (`GRAPHICS_REGRESSION.md`).

## Conclusões

- **DMA FUNCTIONAL PASS** (simulação: unitário, integração, placas, fx68k).
- **P2 SIMULATION PASS.**
- **HARDWARE VALIDATION PENDING.**
