# MD-VDPX na Colorlight i9 v7.2 (LFE5U-45F-6BG381C): estudo de porte

Data: 18/11/2026. Base: entrega `md-vdpx-M4.2-claude`. É um **estudo**: síntese e P&R reais, sem placa, sem
simulação do porte e sem regressão. Nada daqui muda o status físico **BLOCKED** do CN2 da M4.2.

Ferramentas: Yosys + nextpnr-ecp5 (pacotes YoWASP), `--45k --package CABGA381 --speed 6`, 3 sementes.

## 1. Resumo

| Pergunta | Resposta curta |
|---|---|
| O projeto cabe? | Sim, com folga: **19% da lógica, 39% da BRAM** (Tang: 41% e 43/46 BSRAM). |
| Fecha timing sem mudanças? | **Não.** `clk_sys` precisa de 50 MHz e fecha só **~40 MHz**. Com a correção de 1 linha incluída aqui: **~46 MHz**. Falta um registrador de pipeline no cálculo de endereço dos sprites. |
| Dá para pôr um 68000 dentro? | Dá (cabe com folga), mas ele **não acelera o 68000 do Mega Drive**. Funciona como um "sub-CPU" do lado da VDPX, como o 68000 do Mega CD. O ganho real vem de tirar trabalho do barramento CN2. |
| Dá para melhorar muito a VDPX? | Dá. As maiores vantagens são a BRAM extra (VRAM 2–3×), os 4 PLLs (clock limpo para o PCM1808) e um DMA/blitter interno. |

## 2. Medição: o mesmo núcleo M4.2 nas duas FPGAs

Topo de estudo: `colorlight_top.v` (o `vdpx_board.v` sem mudanças). PLL EHXPLLL 25 → 125/50/25 MHz,
TMDS por ODDRX1F (2 bits por ciclo de 125 MHz), SDRAM externa com clock por ODDR.

| | Tang Nano 20K (GW2AR-18) | Colorlight i9 (LFE5U-45F-6) |
|---|---|---|
| Lógica | 8532 LUT4 de 20736 (41%) | 8491 de 43848 (**19%**) |
| FF | 3713 (23%) | 2810 (6%) |
| BRAM | 43 de 46 BSRAM | 43 de 108 DP16KD (**39%**): sobram **65 blocos ≈ 146 KB** |
| Multiplicadores | 1 de 48 | 2–3 de 72 |
| PLL | 2 de 2 (todos usados) | 1 de 4 |
| `clk_sys` (precisa 50) | 57,7 MHz | **40,2 MHz (FALHA)** → 46,0 MHz com o patch (**ainda FALHA**) |
| `clk_pix` (precisa 25) | 69 MHz | 60–63 MHz |
| TMDS | OSER10 | 125 MHz DDR: 218–270 MHz |

O ECP5 grau **-6** (o mais lento) é mais lento por nível de lógica que a GW2AR nesta ferramenta. "Mais lógica"
não quer dizer "mais rápido": o porte precisa de ajustes de pipeline.

### Caminho crítico

1. **Antes:** `vdpx_render.v:142`, `d_ccxh = d_cc * d_hh` (3 × 4 bits). O Yosys colocou isso num MULT18X18D
   não registrado (3,9 ns só no bloco). Patch: `vdpx_render_mul.patch` (soma/deslocamento) → 40 → 46 MHz.
2. **Depois:** RAM distribuída `ls_w/ls_h/ls_dy` → `d_cc`/`d_dyf` → `d_tile` → `spat_addr` → mux `vaddr` →
   endereço da BRAM da VRAM, **21 ns** num ciclo de 20 ns. Correção: registrar `spat_addr` (ou `d_tile`) um
   ciclo antes de `D_E0`. A FSM de sprites ganha 1 ciclo por coluna de tile. Isso gasta um pouco do orçamento
   de 3200 ciclos/linha (hoje ~2260 no pior caso) e **exige rodar de novo a regressão pixel a pixel**
   (`make test`, `m4sim`).

## 3. O que muda no porte (lista de trabalho)

1. **Clocks:** não há 50,4/25,2 MHz exatos a partir de 25 MHz (PFD mínimo do EHXPLLL). Use **25,0 / 50,0 /
   125 MHz** (VCO 500 MHz). Resultado: 640×480 a 59,5 Hz (as TVs aceitam).
   - `vdpx_i2s.v` e o MCLK em `vdpx_board.v`: o quadro de 48 kHz passa de 1050 ciclos para 1041,67. Use um
     acumulador fracionário (3125 ciclos para 3 quadros).
   - `hdmi_tx.v`: ACR **CTS = 25000** (N = 6144). Continua exato.
   - `SDRAM_INIT` e o refresh: recalcular para 50 MHz (a folga atual cobre).
2. **HDMI:** OSER10/TLVDS_OBUF → ODDRX1F + `LVCMOS33D`, como na ULX3S. Já está em `colorlight_top.v`. O módulo
   i9 não tem conector HDMI: precisa da placa de extensão ou de uma placa base própria.
3. **SDRAM M12L64322A (8 MB, 32 bits)**, mesma geometria da SDRAM da GW2AR. Segundo a página da i9, porém,
   **CS, CKE e DQM0–3 estão fixos na placa** (CS/DQM em GND). O `sdram_ctrl.v` usa DQM para gravar 16 bits.
   Sem DQM, uma escrita de 16 bits apaga a outra metade. Escolha uma das saídas:
   - leitura-modifica-escrita no controlador (escritas em samples são raras, custo pequeno); ou
   - 1 word por endereço de 32 bits (sobram 4 MB úteis). **Confirmar no esquema da i9 antes.**
4. **Timing:** aplicar o patch e o registrador de pipeline da seção 2.
5. **Pinos:** a i9 expõe ~106 I/O no conector SODIMM-200, separados da SDRAM, dos PHYs e da flash (o pino 41/L2
   é compartilhado com o LED). A página não informa a tensão dos bancos. Confirme 3,3 V no esquema. O
   `colorlight_i9_parcial.lpf` só tem clock (P3), SDRAM e LED. Os pinos do CN2, áudio e HDMI dependem da placa
   base.
6. **Placa base recomendada:** um soquete SODIMM-200 com o CN2, os 74LVC4245A, o HDMI, o PCM1808 + oscilador de
   áudio, botões e alimentação. Assim não há fios soltos entre placas.

## 4. Placa adaptadora com SN74LVC4245A

O 4245A é diferente do LVC245A da M4.2. É um **tradutor com duas alimentações**: lado A em 5 V (VCCA),
lado B em 3,3 V (VCCB), 24 pinos.

| Pino (SOIC/TSSOP-24) | Função |
|---|---|
| 1 | VCCA (5 V) |
| 2 | DIR (H = A→B) |
| 3–10 | A1–A8 (console) |
| 11, 12, 13 | GND |
| 14–21 | B8–B1 (FPGA) |
| 22 | /OE |
| 23, 24 | VCCB (3,3 V) |

**Confira essa pinagem e a tabela de função no datasheet da TI antes de desenhar a placa.**

Proposta (mantém a filosofia somente escrita da M4.2):

- **U1:** VD0–VD7. **U2:** VD8–VD15. DIR fixo A→B. Deixe um jumper ou trilha cortável para, no futuro, a
  FPGA controlar o DIR. **Não habilite leitura** até medir /CAS0 e provar que não há contenção.
- **U3:** /FDC, /FDWR, /CAS0, FRES, **/LWR, /UWR** (agora cabem: dá para aceitar escrita de byte), mais 2 livres.
- **U4 (opcional):** VA1–VA7. Com 7 bits de endereço, a VDPX tem 128 registradores na janela $A12000–$A120FF
  (hoje são 8). Dá para ter portas DATA diretas por alvo (VRAM, SAT, APU…) e eliminar a troca de
  REG_SEL/ACC_TGT, o que reduz o tráfego no CN2. Isso é ganho de desempenho real.
- **VCCA:** precisa de 5 V no lado A. O mais seguro é tirar do **Vcc do próprio console** (A26/B26, a medir na
  VA6). Com o console desligado, o lado A fica sem alimentação e não há como alimentar o console de volta pelos
  dados. Hoje A26/B26 estão NC: isso muda a regra da M4.2 e precisa de medição.
- **Pontos a verificar no datasheet:** sequência de alimentação VCCA/VCCB, comportamento com uma das fontes
  desligada (Ioff/desligamento parcial) e a qual alimentação /OE e DIR se referem. A prova de segurança da M4.2
  usava o Ioff do LVC245A e **precisa ser refeita** para o 4245A. Mantenha /OE com pull-up para desabilitar
  sem console.
- Vantagem do 4245A: quando a leitura for liberada, a saída para o console sai com nível CMOS de 5 V, sem
  depender da margem TTL.

## 5. Um 68000 dentro da FPGA: o que ganha de verdade

### O que ele NÃO faz

- **Não acelera o 68000 do console nem os jogos existentes.** O CN2 não tem /AS, R/W nem barramento de
  endereço completo. Um CPU na FPGA não consegue assumir o barramento do Mega Drive (seção 8 da especificação).
- **Não aumenta a banda do CN2.** O MD continua a no máximo 1 word a cada ~516 ns (≈3,9 MB/s de pico teórico).
  Com laços reais (`MOVE.W (An)+,(Am)`, 12 ciclos), fica em ~1,3 MB/s, **~20 KB por quadro**.

### O que ele faz: sub-CPU como o do Mega CD

O Mega CD já faz isso: um segundo 68000 de 12,5 MHz fala com o principal pelos registradores em $A12000,
a mesma janela que a VDPX usa. Do lado da VDPX, um 68000:

1. **Resolve a limitação mais grave da M4.2: o jogo não lê a VDPX.** O sub-CPU lê STATUS, VCOUNT e as
   interrupções de vblank/hblank da própria VDPX. Ele faz raster effects, troca de paleta por linha e aplica
   as mudanças no vblank certo, coisas que o MD não consegue sem leitura.
2. **Troca o tráfego de baixo nível por comandos.** Em vez de 2000 escritas de SAT/scroll/tiles por quadro, o MD
   manda um pacote pequeno (estado do jogo, câmera, entradas, ~50–200 words). O sub-CPU monta a SAT, as tabelas
   de scroll e as transferências.
3. **Tem acesso direto aos dados.** Ele lê a flash SPI de 8 MB da i9 (tiles, músicas, samples: um "cartucho" do
   lado da VDPX) e a SDRAM, e descomprime dentro da FPGA. O CN2 deixa de ser o gargalo para os assets.
4. **Roda o driver de som da APU.** Os envelopes de volume, hoje "por software" (o 68000 do MD escreve VOL), e o
   sequenciador de música saem do MD.

### Números (estimativas: o fx68k não passou pelo Yosys sem sv2v e o TG68K é VHDL; meça antes de decidir)

| Opção | Custo estimado no LFE5U-45F | Velocidade | Observação |
|---|---|---|---|
| **fx68k** (exato por ciclo, GPL-3) | ~5–7 mil LUT4 + 3–4 EBR (micro/nanoROM) | 12,5 MHz (clk_sys/4) ≈ **1,6×** o 68000 do MD | Comportamento idêntico ao 68000; GPL-3 contamina o bitstream distribuído. |
| **TG68K.C** (LGPL) | ~3–4 mil LUT4 | 25–50 MHz, poucos wait states em BRAM ≈ **4–8×** o MD | Não é exato por ciclo, o que não importa para um coprocessador. |
| RAM de programa | 64 KB = 32 EBR | – | Cabe nos 65 EBR livres, mas compete com a VRAM maior (seção 6). Alternativa: rodar da SDRAM com cache pequena. |

**Ganho total de CPU:** de 1 (só o MD) para ~2,6× (com fx68k) ou ~5–9× (com TG68K). O ganho maior, porém, está
em **atualizar a VRAM sem passar pelo CN2**: o sub-CPU escreve direto no barramento interno (até 1 word/ciclo
de 50 MHz). Com o TG68K, um `MOVE.L (A0)+,(A1)+` em laço dá ~5–10 MB/s, contra ~1,3 MB/s pelo CN2.

### Mas antes do 68000: um DMA/blitter

Para mover dados, um **DMA** (cópia SDRAM/flash → VRAM, fill, cópia VRAM→VRAM) custa ~300–600 LUT, contra
milhares de um CPU. Ele chega a 25–50 MB/s, **20–40× o CN2**, e o MD dispara com 3–4 escritas. Recomendo esta
ordem:

1. DMA/blitter + registradores sombra com commit no vblank (já proposto na M4.2 §7).
2. Sub-CPU (TG68K) se o jogo precisar de lógica do lado da VDPX (raster, música, descompressão).

Uma alternativa ao 68000 é um RISC-V pequeno (VexRiscv/PicoRV32, ~1,5–3 mil LUT, 50 MHz). Ele é mais rápido e
mais barato, mas exige outro compilador. O 68000 tem a vantagem de usar o mesmo gcc/SGDK do jogo.

## 6. Outras melhorias que a lógica extra permite

Por valor/custo:

1. **VRAM de 64 KB → 128–192 KB em EBR** (a M0 diz que a BSRAM é o recurso escasso; no ECP5 sobram ~146 KB).
   A nametable já tem 14 bits de tile (16384 tiles = 512 KB): o formato aguenta crescer.
2. **Clock limpo para o PCM1808** (item BLOCKED na M4.2): os 4 PLLs e um oscilador de 24,576 MHz na placa base
   formam um domínio de áudio próprio. O HDMI precisa então de CTS medido (é para isso que o ACR existe) em vez
   da constante. Isso fecha o risco de jitter de ~20 ns do MCLK atual.
3. **Escrita de byte e janela de 128 registradores** (/LWR, /UWR, VA4–VA7 na placa 4245A).
4. **Plano C/window, tiles de 8bpp, mais sprites por linha.** Hoje o orçamento é ~2260 de 3200 ciclos.
   Para dobrar camadas é preciso mais ciclos por linha (`clk_sys` 3× o pixel = 75 MHz não fecha no -6 sem
   muito pipeline) ou buscas mais largas (BRAM de 32 bits: 2 words por acesso). A segunda saída é a realista.
5. **Plano afim (rotação/escala tipo "modo 7")** usando os 72 multiplicadores.
6. **Resolução de saída maior (720p):** exige TMDS a 742,5 Mb/s, acima do especificado para o ODDRX1F no -6.
   Funciona em placas como a ULX3S, mas fica fora da especificação. Não recomendo como base.

## 7. Próximos passos sugeridos

1. Aplicar o patch e o registrador de pipeline no `vdpx_render.v`, depois rodar `make test`/`m4sim` (pixel a
   pixel) e o P&R no ECP5 até fechar 50 MHz.
2. Ajustar os clocks para 25/50/125 (I2S fracionário, CTS 25000) e a SDRAM sem DQM.
3. Obter o esquema da i9 v7.2: tensões dos bancos, DQM/CS e o mapa SODIMM → site.
4. Desenhar a placa base com os 4245A conforme a seção 4 e manter a qualificação física da M4.2 (VA6, sonda CN2).
5. Só depois: DMA → sub-CPU.

## Arquivos

- `colorlight_top.v`: topo ECP5 de estudo (PLL, TMDS DDR, SDRAM sem DQM). Não validado em placa.
- `colorlight_i9_parcial.lpf`: clock, SDRAM e LED conforme a página da i9 v7.x. CN2/HDMI/áudio a definir.
- `vdpx_render_mul.patch`: troca o multiplicador 3×4 por soma/deslocamento (equivalente em lógica; regressão não
  executada aqui).
