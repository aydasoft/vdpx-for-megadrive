# Regressão: ECP5-P1

Execução única e completa: `scripts/run_p1_all.sh` (YoWASP). Resumo com exit codes em `logs/RUN_SUMMARY.txt`,
versões em `logs/versions.txt` (Verilator 5.020, Icarus 12.0, m68k-linux-gnu-gcc 13.3.0, Yosys 0.71, nextpnr
0.11.1, fx68k 0602ee46). **Todas as etapas: exit 0.** Nenhum teste da M4.2 foi enfraquecido.

| Etapa | Log | Exit |
|---|---|---|
| Baseline: M4.2 **sem modificação** (`make all_tests`) | `logs/baseline_m42/all_tests_m42_unmodified.log.gz` | 0 |
| M4.2 `all_tests` com o RTL modificado (parâmetros Tang) | `logs/regression/all_tests_tangparams.log` | 0 |
| Lint ECP5 | `logs/ecp5_unit/ecp5_lint.log` | 0 (avisos listados em RISKS #13) |
| Unitários ECP5 + auditoria | `logs/ecp5_unit/ecp5_unit.log` | 0 |
| 17 cenas a 50 MHz via SDRAM RMW | `logs/ecp5_sim/test50.log` | 0 |
| fx68k + adaptador somente escrita a 50 MHz | `logs/ecp5_sim/m2wo50.log` | 0 |
| Placa ECP5 (3 execuções) | `logs/ecp5_sim/ecp5_boardsim.log` | 0 |
| Síntese, P&R ×3, bitstream, relatório, auditoria | `logs/ecp5_build/` | 0 |
| (extra) `make tang` com o RTL modificado | `logs/tang_modified/make_tang.log` | 0 |

## Gráficos

| Exigência | Evidência | Resultado |
|---|---|---|
| 17 cenas, pixel a pixel | `tb_main` × `refmodel.h` (modelo escrito da especificação), com **parâmetros Tang** e a **50 MHz** | 17/17 OK nos dois |
| Prioridades, transparência, sprites sobrepostos, scroll H/V (plano, linha, coluna), clipping | cenas `rand0..5` (aleatórias), `fx`, `demo`, `limites` | OK |
| Limite de sprites (flag SPR_OVF igual ao modelo) | `limites`, `rand2`, `rand5` | OK (1 + 4 + 4 quadros com limite) |
| Quadros completos / bordas / sincronismo | M4/ECP5: quadros 640×480 decodificados do HDMI; receptor confere posições de sync | OK |
| Orçamento por linha | monitor `RENDER_BUDGET` | máx. **2349 de 3200 ciclos**; RENDER_OVERFLOW = 0 |

## CPU e comunicação

| Exigência | Resultado |
|---|---|
| Co-simulação fx68k com o adaptador somente escrita **real** | M2WO (50,4 MHz) e **M2WO50 (50 MHz)**: **19 707 escritas do 68000 = 19 707 escritas no núcleo** nos dois; mesma contagem da M4.2 |
| FIFO sem perda | nível máximo 1/16, 0 perdidas; menor intervalo 26 ciclos (516 ns a 50,4; 520 ns a 50) |
| Leituras não dirigidas | 64 leituras do 68000, todas FFFF (barramento solto) |
| Ordem dos comandos | escritas aplicadas = emitidas, na ordem (scoreboard M4.2: 491 entregues, 20 rejeitadas em cheio) |
| ROM de diagnóstico compilada | `make diagrom` dentro de `m2wo`/`m2wo50` (diag_md.bin e diag_sim.hex) |
| Placa ECP5 com CN2 | 19 escritas aplicadas, 15 leituras sem drive/commit, OCR do painel 26/26 |

## Memória

| Exigência | Resultado (`ecp5_unit.log`) |
|---|---|
| SDRAM 32 bits, escritas parciais, vizinho preservado | 2000 escritas alternadas nas duas metades com leitura do vizinho; `chk_word` no modelo |
| Walking 1/0 | 1024 operações (8 words × 16 bits × 2 metades) |
| Endereços extremos | 12 (0, 1, 3FFFFE/F, limites de coluna/banco/linha) |
| Rajadas | 4000 operações seguidas numa região de 64 words |
| Integridade após muitas operações | 60 000 aleatórias em 8 MiB + varredura final: **0 falhas** |
| Refresh sob carga | ~870 intervalos sob carga, 0 violações (REF_MAX 800 ciclos) |
| Atrasos de placa de pior caso | clock 288°, tAC 8 ns, tOH 2 ns, tIN 1–7 ns: **PASS** |
| Testes negativos | esquema M4.2 na i9 → **FALHA**, como esperado; controlador sem RMW → **FALHA**, como esperado |
| Arbitragem APU × CPU sob carga | 17 cenas pela SDRAM RMW (`audio_smem`: 301 leituras de volta; `audio_musica`: 10 532 escritas RMW com PCM tocando): áudio bit a bit |

## Vídeo e áudio

Ver `HDMI_TEST_REPORT.md`:
- encoder: 300 000 símbolos, 0 erros;
- link serial: 38 M símbolos, 0 desalinhamentos, serial = paralelo;
- barras: 21/21 quadros;
- cena da VDPX: 6/6 quadros;
- painel: 26/26 campos;
- áudio do HDMI = mixer = modelo da APU (33 869 amostras);
- ACR 6144/25000;
- mixer medido em 48 000,000 Hz;
- overflow da FIFO de áudio = 0.

## Clocks e reset

| Exigência | Resultado |
|---|---|
| Reset durante a inicialização | lock cai nos ciclos 150–169 (SDRAM em power-up): 3/3 quadros, áudio bit a bit, 0 erros de SDRAM |
| PLL lock / sequência de reset | lock 0 até o ciclo 40; reset assíncrono, liberação sincronizada por domínio (50/25/125 MHz) |
| CDC | FIFO Gray (vídeo), toggle (áudio, TMDS); caminhos reportados pelo nextpnr ≤ 1,8 ns |
| Recuperação após perda de lock | perda de 2000 ciclos após o quadro 8: o receptor relocka e **8/8 quadros** posteriores são iguais ao modelo; 0 desalinhamentos |

## Diferenças de contagem em relação à M4.2 (rastreáveis)

- Cenas de áudio com parâmetros Tang: `audio_md` passa de 30 001 para 30 000 amostras e o número de ciclos muda
  em +72 por amostra. Causa: a APU entrega cada amostra 72 ciclos depois (multiplicador com registros) e a cena
  termina por número de ciclos. Todas as amostras conferem com o modelo.
- A 50 MHz o número de amostras por cena muda (quadro de 1041,67 em vez de 1050 ciclos), sempre com 0 erradas.
- M2WO50: 32 163 296 ciclos contra 32 420 600 (clock de 50 contra 50,4 MHz); escritas iguais (19 707).
