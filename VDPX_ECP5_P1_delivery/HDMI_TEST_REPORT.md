# Testes de HDMI: ECP5-P1

| Camada | Status |
|---|---|
| **Vídeo DVI/TMDS** (símbolos, serialização ODDRX1F, alinhamento, imagem decodificada) | **VIDEO PASS (simulação)** |
| **HDMI com áudio** (data islands, Audio Sample Packets, ACR, AVI/Audio InfoFrames) | **HDMI_AUDIO PASS (simulação)** |
| Compatibilidade física com monitor real | **PENDING** (sem placa) |

Nenhum teste abaixo aceita sinais RGB antes do serializador como prova. Nos testes de link, o testbench só vê os
**4 pinos de saída** (Q dos ODDRX1F), amostrados a cada meio período de 125 MHz (250 Mbit/s por lane). Ele
reconstrói os símbolos de 10 bits pela lane de clock e alimenta um receptor HDMI em C++ (`sim/m4/hdmi_dec.h`, o
"modelo de TV" da M4, que confere guard bands, preâmbulos, TERC4, BCH, paridade, checksums, N/CTS e balanço DC).

## Testes e resultados (`logs/ecp5_unit/ecp5_unit.log`, `logs/ecp5_sim/ecp5_boardsim.log`)

| # | Exigência | Teste | Resultado |
|---|---|---|---|
| 1 | Encoder TMDS com vetores conhecidos | `tb_hdmi_unit` parte 1: `tmds_enc` × implementação C++ **independente** do algoritmo DVI 1.0 §3.3.3 (com disparidade), 4 tokens de controle, 16 códigos TERC4 e guard bands (tabelas HDMI 1.4, q[9:0], bit 0 primeiro) | **300 000 símbolos, 0 errados** (256 valores × 4 passadas + aleatórios) |
| 2 | Blanking horizontal e vertical | Receptor: nenhum pixel de vídeo fora de 640×480, exatamente 640×480 pixels por quadro, preâmbulos e guard bands nas posições certas | 0 erros do receptor |
| 3 | Polaridade HSYNC/VSYNC | `tb_hdmi_unit`: largura dos pulsos medida no fluxo decodificado (nível 1 em repouso = polaridade negativa); posição da queda (x=656 / y=490) pelo receptor | **HSYNC baixo 96 px em 11546/11546 linhas; VSYNC baixo 2 linhas em 22/22 quadros** |
| 4 | Ordem dos dez bits TMDS | Cada símbolo reconstruído do serial (bit 0 primeiro) comparado com o símbolo paralelo do transmissor | **0 diferenças em 9,2 M (unitário) e 17,6 M (placa) símbolos**, latência fixa de 2 pixels |
| 5 | Alinhamento das três lanes e do clock | Mesma comparação, por lane; lane de clock conferida como 1111100000 em cada símbolo; exatamente 10 bits entre bordas de subida do clock | **0 desalinhados, 0 clocks errados** |
| 6 | Reconstrução dos pixels após serialização | Quadros do receptor comparados pixel a pixel | ver 7–9 |
| 7 | Barras coloridas | `tb_hdmi_unit` parte 2: 8 barras + degradê gerados pelo TB → `hdmi_tx` → `ecp5_tmds_ser` → pinos → receptor | **21/21 quadros iguais** (`out/ecp5_colorbars.ppm`) |
| 8 | Cena original da VDPX | `tb_ecp5`: autoteste + CN2, núcleo completo a 50/25/125 MHz, comparação com o modelo de referência | **6/6 quadros iguais** (40 quadros simulados) |
| 9 | Painel da sonda CN2 | OCR do painel no quadro decodificado do serial × sinais aplicados no CN2 | **26/26 campos** (inclui "UNIDADE 20.0 NS") |
| 10 | Milhares de linhas, vários quadros | 40 + 12 + 16 quadros na placa, 22 no unitário | 0 desalinhamentos em 38 M símbolos |
| – | ACR e InfoFrames | todos os pacotes | **N=6144, CTS=25000**; AVI VIC=1; Audio InfoFrame; BCH/checksums OK |
| – | Áudio no HDMI | `tb_hdmi_unit`: 17 740 amostras injetadas a 48 kHz → 17 735 recebidas, contínuas (as 5 primeiras saem antes do receptor ligar); `tb_ecp5`: 33 869 amostras = saída do mixer = modelo da APU | **0 erros** |
| – | Reset na inicialização / perda de lock | lock oscilando durante o power-up da SDRAM; perda de lock de 40 µs após o quadro 8 | 3/3 e 8 quadros pós-recuperação iguais; 0 desalinhamentos |

## Serializador ECP5 (`rtl/ecp5/ecp5_tmds_ser.v`)

- 10 bits por pixel a 25 MHz = 5 ciclos de 125 MHz × 2 bits (ODDRX1F: D0 primeiro, D1 depois; FPGA-TN-02035
  tabela 8.12).
- Carga autoalinhada: o domínio de pixel inverte um bit a cada pixel; o domínio de 125 MHz detecta a borda após 2
  FFs e carrega os registradores de deslocamento uma vez a cada 5 ciclos, 3 ciclos depois da mudança dos símbolos
  (dado estável por 5 ciclos). Não depende da fase exata entre os clocks.
- A lane de clock passa pela mesma primitiva e pelo mesmo registrador que as lanes de dados (mesma latência).
- Modelo de simulação do ODDRX1F escrito a partir da nota técnica (o Yosys só tem black box). Os testes não usam a
  latência absoluta.

## Limitações

- Simulação digital: não modela níveis, amplitude, terminação, jitter nem o acoplamento AC da Ext-Board.
- O receptor C++ é o mesmo modelo da M4 (não é um monitor real). Monitores que exigem EDID/HPD ou que não aceitam
  59,52 Hz não estão cobertos.
- Transitório documentado: após o reset, a primeira linha antes de o `hdmi_tx` travar nas sincronias tem o
  blanking na posição livre do transmissor; o receptor do teste unitário só começa duas linhas depois do lock.
