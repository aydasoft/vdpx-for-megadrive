# CHANGELOG: M4.2 Claude → ECP5-P1

A M4.2 Claude está preservada sem alterações em `../m42_reference/md-vdpx-M4.2-claude/`. Esta árvore parte dela.
Todos os parâmetros novos têm como padrão o comportamento da M4.2/Tang. A regressão M4.2 completa
(`make all_tests`) passa com o RTL modificado (`logs/regression/all_tests_tangparams.log`).

## RTL comum (Tang e ECP5)

| Arquivo | Mudança | Motivo | Efeito funcional |
|---|---|---|---|
| `rtl/vdpx_render.v` | Produto 3×4 (`d_ccxh`) por soma/deslocamento | Yosys o colocava num MULT18X18D combinacional (3,9 ns) no caminho crítico | nenhum (mesma conta) |
| `rtl/vdpx_render.v` | Estado `D_AD`: endereço do padrão do sprite registrado (`spat_r`) antes de `D_E0` | caminho lista de sprites → endereço da VRAM em 1 ciclo (21 ns) | +1 ciclo por coluna de tile de sprite |
| `rtl/vdpx_render.v` | Estado `T_AD`: endereço da entrada da nametable registrado (`ent_r`) e `fy_t` | caminho VSRAM → linha → endereço da VRAM | +1 ciclo por tile de plano. Pior linha medida: 2349 de 3200 ciclos |
| `rtl/vdpx_apu.v` | Multiplicador compartilhado com entradas e produto registrados; cada uso espera 2 ciclos (`mwait`) | mux → MULT18X18D → acumulador em 1 ciclo | mesma aritmética e ordem; +72 ciclos por amostra (de ~1042) |
| `rtl/vdpx_i2s.v` | Quadro por acumulador fracionário (`FR_NUM/FR_DEN`); o quadro começa quando o índice de meio-período volta a 0 | 48 kHz exatos a 50 MHz (3125/3 ciclos) | padrão (1/1050) idêntico ciclo a ciclo à M4.2 |
| `rtl/vdpx_top.v` | Parâmetros `I2S_NUM`, `I2S_DEN` repassados | idem | — |
| `rtl/hdmi/hdmi_tx.v` | Parâmetro `ACR_CTS_VAL` (25200 padrão; 25000 no ECP5) | CTS correto para 25,0 MHz | — |
| `rtl/board/vdpx_board.v` | Parâmetros `CLK50`, `SDRAM_RMW`, `SDRAM_RD_CAPTURE`; MCLK com passo/módulo do I2S; unidade do painel (19.8/20.0 ns) | plano de clock de 50 MHz e SDRAM da i9 | padrões = M4.2 |
| `rtl/board/sdram_ctrl.v` | `RMW = 1`: escrita de 16 bits = READ + merge + WRITE; `rd_pipe` de 4 bits (`RD_CAPTURE` 2..4); comando inicial NOP | DQM em GND na i9; SDRAM externa (captura na 3ª borda com clock defasado) | `RMW = 0`, `RD_CAPTURE = 2`: M4.2 |
| `scripts/gen_overlay.py` → `rtl/board/vdpx_overlay.v` | Conversão binário→decimal por double dabble registrada (sem divisores); estágio extra entre a ROM do template e o mux de slots; unidade do painel como campo | divisores e ROM→mux→ROM no caminho crítico | painel idêntico; vídeo +1 pixel de latência (syncs juntos) |

## Novo para o ECP5

| Arquivo | Conteúdo |
|---|---|
| `rtl/ecp5/colorlight_i9_top.v` | Topo: EHXPLLL 25 → 125/50/25 MHz + 50 MHz a 288° (SDRAM), reset por lock, tristate da SDRAM |
| `rtl/ecp5/vdpx_ecp5_core.v` | Núcleo da placa (tudo menos PLL e pads): `vdpx_board` (CLK50=1, RMW=1, RD_CAPTURE=3), sincronizador de reset de 125 MHz, serializador, clock da SDRAM por ODDRX1F |
| `rtl/ecp5/ecp5_tmds_ser.v` | Serializador TMDS 10:1 por ODDRX1F (2 bits por ciclo de 125 MHz), carga autoalinhada por toggle do domínio de pixel, lane de clock 1111100000 |
| `board/colorlight_i9_v72_extboard.lpf` | Restrições com fontes e bancos documentados |
| `board/lfe5u45_cabga381_pins_subset.json` | Bancos/pares das esferas usadas (do prjtrellis-db) |
| `board/baseline_study/` | Topo e LPF parciais do estudo usado para medir o baseline sem modificações |

## Verificação nova

| Arquivo | Conteúdo |
|---|---|
| `sim/ecp5/ecp5_prims_sim.v` | Modelo comportamental do ODDRX1F (D0 depois D1) |
| `sim/ecp5/tmds_deser.h` | Deserializador TMDS pela lane de clock + comparação serial × paralelo |
| `sim/ecp5/tb_ecp5.cpp`, `ecp5_board_sim.v` | Placa ECP5 inteira com decodificação do TMDS **serial**, SDRAM sem DQM com janela de pior caso, CN2, OCR do painel, reset na inicialização e perda de lock |
| `sim/ecp5/tb_hdmi_unit.cpp`, `hdmi_unit_top.v` | Encoder TMDS × modelo DVI 1.0 independente; barras coloridas; sincronismo; áudio |
| `sim/ecp5/tb_sdram_rmw.sv` | SDRAM RMW com atrasos reais de placa + testes negativos |
| `sim/ecp5/vdpx_sim_sdram.v` | As 17 cenas a 50 MHz através do controlador RMW |
| `sim/m4/sdram_model.v` | `HONOR_DQM`, contenção de DQ, `ref_relaxed`, `dq_drv`, contador de escritas |
| `sim/apumodel.h`, `sim/audio_tb.h` | Reset do núcleo no modelo da APU/ADC (para os testes de reset) |
| `sim/vdpx_sim.v` | Monitor do orçamento de renderização; define `VDPX_CLK50` |
| `scripts/ecp5_audit.py`, `ecp5_report.py`, `ecp5_io_paths.py`, `expect_fail.py`, `run_p1_all.sh` | Auditoria, relatório, E/S da SDRAM, testes negativos, execução completa |
| `Makefile` | `test50`, `ecp5_unit`, `ecp5_boardsim`, `ecp5_lint`, `ecp5_test`, `ecp5_synth`, `ecp5_pnr`, `ecp5_bitstream`, `ecp5_report`, `ecp5` |
