# Riscos, bloqueios e pendências: ECP5-P1

Legenda: **PASS** = aprovado em simulação/síntese com evidência no `logs/`; **PENDING** = falta hardware;
**BLOCKED** = depende de algo que não existe (hardware/medição/documento); **RISCO** = aprovado, mas com hipótese
não verificada.

| # | Item | Status | Detalhe / como fechar |
|---|---|---|---|
| 1 | Validação física na i9 + Ext-Board | **PENDING** | Nenhuma placa usada. Roteiro em `HARDWARE_TEST_GUIDE.md`. |
| 2 | VCCIO dos bancos do módulo i9 | **RISCO** | Esquema do módulo não é público. LPF assume 3,3 V (como LiteX/amaranth). Medir VCCIO2 (HDMI). |
| 3 | HDMI elétrico (`LVCMOS33D` + 0,1 µF, sem terminação/ESD, sem DDC/HPD) | **RISCO / PENDING** | Não é TMDS conforme a norma; funciona em projetos de referência, mas a compatibilidade depende do monitor. `HDMI_EXT_BOARD.md`. |
| 4 | DQM0-3 em GND | **RISCO baixo** | Duas fontes documentais concordam; a solução RMW funciona com ou sem DQM. |
| 5 | Timing de E/S da SDRAM externa | **RISCO** | O nextpnr não verifica E/S. Orçamento calculado com datasheet (grau -7) e atrasos estimados, + simulação com janela de pior caso: margens ~+5,5/+2,5 ns na leitura, +10/+1,8 ns no comando. Ajuste por fase do PLL (`CLKOS3_CPHASE/FPHASE`). `SDRAM_32BIT_REPORT.md`. |
| 6 | Latência/alinhamento real do `ODDRX1F` | **RISCO baixo** | Modelo comportamental próprio (o Yosys só tem black box). Os testes não dependem da latência absoluta, só da ordem D0→D1 e de latência igual nas lanes (todas as lanes, inclusive a de clock, passam pela mesma primitiva). |
| 7 | Divergência de pinagem D15/D16 (DQ27) | **resolvido no LPF** | wuxx/S3: D15; `amaranth_boards` do mesmo repositório: D16 (pino de PMOD). Usado D15; D16 não usado. |
| 8 | PCM1808 / MCLK limpo | **BLOCKED** | MCLK fracionário com jitter de ~20 ns segue EXPERIMENTAL. Opções em `AUDIO_CLOCK_REPORT.md` (PLL dedicada + CTS medido, ou oscilador externo não instalado). |
| 9 | CN2 com o Mega Drive | **BLOCKED** (herdado da M4.2) | Pinagem VA6, timing real de /FDC /FDWR /CAS0, leitura: tudo como na M4.2. Interface segue somente escrita. Pinos de PMOD provisórios. |
| 10 | SN74LVC4245A | **PENDING** (sem placa) | Exige 5 V no lado A: os PMODs não têm 5 V; o VCCA viria do console (A26/B26, a medir) ou de fonte local com sequenciamento. Verificar no datasheet o comportamento com uma das fontes desligada (o argumento de Ioff da M4.2 valia para o LVC245A). |
| 11 | Caminhos entre domínios | **RISCO baixo** | sys↔pix: FIFOs com Gray (M4.2). pix→125 MHz: clocks relacionados do mesmo VCO; o carregamento acontece 3 ciclos rápidos depois da mudança, com dado estável por 5 ciclos; atraso máximo reportado pelo nextpnr ~1,6–1,8 ns, contra 24 ns disponíveis. O nextpnr só reporta (não restringe) esses caminhos. |
| 12 | Entradas assíncronas do CN2 | herdado | Strobes sincronizados com 2 FFs; dados/endereço "bundled" (estáveis antes do strobe sincronizado), como na M4.2. O nextpnr lista md_d → FIFO como caminho `<async>` de ~6 ns. |
| 13 | Lint | **aceito** | Verilator `-Wall` sem avisos nos arquivos ECP5 novos. Os avisos de largura/estilo existentes nos arquivos HDMI da M4.2 foram mantidos (código não alterado nesse ponto), mais BLKSEQ em variáveis locais da função `bcd3` do overlay. Log em `logs/ecp5_unit/ecp5_lint.log`. |
| 14 | Build Tang com o RTL modificado | **PASS (P&R aberto)** | `make tang` (Yosys + nextpnr-himbaechel-gowin + apycula): exit 0, 43/46 BSRAM, timing PASS (`logs/tang_modified/`). Sem Gowin EDA e sem silício. |
| 15 | Transitório de partida do HDMI | documentado | Após reset, a primeira linha antes do `hdmi_tx` travar nas sincronias tem o blanking na posição livre do transmissor (comportamento da M4.2). |
| 16 | Perda de lock | **PASS (simulação)** | Reset assíncrono; o núcleo volta e a imagem se recupera. Os registradores da VDPX voltam ao padrão (como em qualquer reset), as memórias persistem, e o autoteste redesenha a cena. Clocks reais podem parar ou oscilar durante a perda: não modelado. |
| 17 | Ferramentas | nota | Yosys 0.71 e nextpnr 0.11.1 via YoWASP (WebAssembly). Versões diferentes podem dar Fmax diferente; os bitstreams não são garantidamente idênticos byte a byte entre versões. |
