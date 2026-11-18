# MD-VDPX ECP5-P1: relatório técnico

Data: 18/11/2026. Alvo: Colorlight i9 v7.2 (LFE5U-45F-6BG381C, grau -6) + Ext-Board i5/i9 com HDMI.
Escopo: análise, simulação, síntese, P&R e bitstream. **Nenhum hardware físico foi usado.**
Base: M4.2 Claude, preservada sem alterações em `../m42_reference/md-vdpx-M4.2-claude/`.

## 1. Resumo

| Critério (§14 da especificação) | Resultado |
|---|---|
| Sintetizada para LFE5U-45F-6BG381C | **PASS** |
| 50 MHz fechando em todas as sementes | **PASS** nas 3 sementes, com margem ≥ 10% em todas (`TIMING_REPORT.md`) |
| Demais domínios (25 / 125 MHz) | **PASS** com folga |
| Renderização pixel a pixel equivalente à M4.2 | **PASS**: 17 cenas, com parâmetros da Tang e a 50 MHz; quadros do HDMI decodificados |
| HDMI TMDS serializado no ECP5 | **PASS (simulação)**, decodificado dos pinos |
| Fluxo de vídeo decodificado e validado | **VIDEO PASS** |
| SDRAM 32 bits sem DQM | **PASS (simulação)**, inclusive com atrasos de placa de pior caso |
| APU / áudio | **HDMI_AUDIO PASS (simulação)**; PCM1808 **BLOCKED** (clock) |
| CN2 estritamente somente escrita | **PASS** (netlist: `md_*` só entradas; nenhum commit/drive em todos os testes) |
| Sonda e autoteste | **PASS** (OCR 26/26; autoteste independente) |
| Regressões sem falhas | **PASS** (`REGRESSION_REPORT.md`) |
| Bitstream corresponde às fontes | **PASS**: `SHA256SUMS`, hashes do netlist/config/bitstream no relatório do build |
| Pinagem HDMI e bancos documentados com evidência | **PASS** (esquema da Ext-Board, prjtrellis-db, LiteX) |
| **HARDWARE VALIDATION** | **PENDING** |

Conclusão: **P1 SIMULATION PASS**. Validação física pendente, PCM1808 bloqueado por clock e CN2 ainda bloqueado
pelas pendências herdadas da M4.2.

## 2. O que foi portado

- **Núcleo VDPX inteiro** (planos A/B, sprites, prioridades, scroll, paletas RGB555, VRAM de 64 KiB), **APU** (8
  PCM + 8 wavetable, mixer 48 kHz), **HDMI com áudio**, **sonda CN2 + painel**, **adaptador somente escrita** com
  FIFO protegida e **autoteste**. Nada foi removido nem simplificado.
- **Primitivas Gowin → ECP5**: `rPLL`×2 + `CLKDIV` → 1 `EHXPLLL` (125/50/25 MHz + 50 MHz a 288° para a SDRAM);
  `OSER10` + `TLVDS_OBUF` → `ODDRX1F` + `LVCMOS33D`; SDRAM interna → SDRAM externa M12L64322A com clock por
  `ODDRX1F`; distribuição de clock pelos DCCA globais do nextpnr.
- **Plano de clock de 50,0 MHz** (25 MHz de cristal): I2S, MCLK, ACR e a unidade do painel parametrizados; os
  totais VGA não foram mudados (59,52 Hz).

## 3. Timing closure

Baseline sem modificações no ECP5: **~40 MHz** (FAIL). Passos, cada um com o caminho crítico que o motivou
(`CRITICAL_PATHS.md`):
1. Produto 3×4 do endereço de sprite tirado do DSP (soma/deslocamento): 40 → 46 MHz.
2. Endereço do padrão de sprite registrado (estado `D_AD`): ~48 MHz.
3. Multiplicador da APU com registros de entrada/saída: ~48 MHz (o crítico mudou).
4. Endereço da nametable registrado (estado `T_AD`): ~50,5 MHz.
5. Painel: binário→decimal sem divisores (double dabble registrado): ~59–64 MHz.
6. Painel: registro entre a ROM do template e o mux de slots: 67–73 MHz.

Funcionalidade gráfica inalterada: os 2 estados novos do renderizador só acrescentam ciclos dentro do orçamento
da linha (pior caso medido: 2349 de 3200 ciclos; RENDER_OVERFLOW nunca acionado), e a comparação pixel a pixel das
17 cenas continua passando.

## 4. HDMI

`ecp5_tmds_ser.v`: 2 bits por ciclo de 125 MHz por `ODDRX1F`, carga autoalinhada pelo domínio de pixel, lane de
clock 1111100000. Pinagem do esquema da Ext-Board (G19/E20/C20/J19 + complementares, banco 2, pares verdadeiros),
`LVCMOS33D`. A Ext-Board acopla em AC (0,1 µF), não tem terminação nem ESD, e **não liga DDC, HPD nem CEC**: nenhum pino do
FPGA foi atribuído a eles. Análise elétrica em `HDMI_EXT_BOARD.md`; testes em `HDMI_TEST_REPORT.md`.

## 5. Áudio

48 kHz exatos com quadro I2S de 3125/3 ciclos; ACR N=6144/CTS=25000 (exatos). PCM, wavetable e mixer conferidos
bit a bit com o modelo da APU, inclusive pelo HDMI decodificado do serial. O MCLK do PCM1808 continua fracionário
(EXPERIMENTAL). Um clock limpo exige PLL dedicada com CTS medido ou oscilador externo (`AUDIO_CLOCK_REPORT.md`).

## 6. SDRAM

DQM em GND (duas fontes) → escrita de 16 bits por leitura-modificação-escrita. Além disso, a SDRAM agora é
**externa**: a captura em 2 bordas com clock invertido (válida na Tang) não funciona com tAC de 6–8 ns. A P1 usa
clock da SDRAM a 288° (CLKOS3) e captura na 3ª borda, com orçamento calculado e verificado em simulação com janela de
pior caso. Testes negativos mostram que o esquema antigo falharia (`SDRAM_32BIT_REPORT.md`).

## 7. VRAM

Mantida em 64 KiB (32 EBR). Análise para 128/192 KiB em `RESOURCE_REPORT.md`: 128 KiB cabe (+32 EBR); 192 KiB
esgotaria os 108 EBR e não é viável só em EBR.

## 8. CN2

Arquitetura M4.2 intacta: entradas somente, sem driver, sem /DTACK, /CAS0 sem função, FIFO com rejeição em
overflow, sonda e painel. Pinos provisórios nos PMODs (sem placa adaptadora). Revisão para SN74LVC4245A em
`HDMI_PINOUT.md` e `HARDWARE_TEST_GUIDE.md` §5.

## 9. Pendências

Ver `RISKS_AND_BLOCKERS.md`. Principais: validação em placa (PENDING), VCCIO do banco 2 (inferido), E/S da SDRAM
(cálculo, não STA), PCM1808 (BLOCKED), CN2 com o console (BLOCKED, herdado).
