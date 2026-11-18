# MD-VDPX — Especificação M0

VDP estendido em FPGA (Tang Nano 20K, Gowin GW2AR-18) ligado ao Mega Drive pela
porta de expansão do Mega CD, com buffers 74LVC245. Vídeo e áudio saem pelo HDMI
da Tang. O VDP original do Mega Drive não é usado para imagem.

Status: **v0.5 (M0 a M4.1)**. Tudo o que não está marcado como
**[futuro]** está implementado e verificado em simulação.

---

## 1. Visão geral

| Item | MD original | VDPX (meta) | M1 |
|---|---|---|---|
| Resolução interna | 320×224 | 320×224 | ✔ |
| Saída | analógica | HDMI 640×480@60 (pixel dobrado 2×2, borda 16 linhas em cima e embaixo) | ✔ (sinais RGB888 + sync/DE) |
| Cores na tela | 61 de 512 (RGB333) | 256 de 32768 (RGB555) | ✔ |
| Paletas | 4 × 16 | 16 × 16 | ✔ |
| Planos de tiles | A, B (+ window) | A, B (+ C/window futuro) | A, B ✔ |
| Tile | 8×8, 4bpp | 8×8, 4bpp (8bpp futuro) | ✔ |
| Entrada de nametable | 16 bits | 32 bits | ✔ |
| Scroll | por linha / por 2 colunas | plano inteiro, por linha, por coluna de 16 px | ✔ (M1.5) |
| Sprites | 80, 20/linha, até 32×32 | 128, 32/linha (máx. 64 colunas de tile = 512 px), até 64×64 | ✔ (M1.5) |
| VRAM | 64 KB | 64 KB (BSRAM) [M1]; + SDRAM 8 MB interna da GW2AR [futuro] | 64 KB |
| Áudio | YM2612 (6 FM) + PSG (4) | **mantém os 10 canais do MD** + 8 PCM + 8 wavetable/ruído, mixer estéreo 48 kHz | ✔ (M3) |

---

## 2. Interface com o 68000

A VDPX ocupa a **janela /FDC da porta de expansão: `$A12000–$A1200F`**, a mesma região dos registradores do Mega CD.

- O console decodifica o endereço e gera /DTACK **sem wait states**, então a VDPX responde dentro do ciclo normal do 68000.
- **Escritas:** entram numa FIFO e são confirmadas na hora.
- **Leituras:** vêm de valores já prontos. A porta DATA tem prefetch, como o VDP original.
- **Sinais usados (CN2):** VD0–VD15, VA1–VA3, /FDC, /FDWR, /CAS0 e FRES. A pinagem está em `board/LEIAME_placa.md`.
- **Leitura de DATA logo depois de mudar ACC_ADDR, ACC_TGT ou ACC_ADDR_HI:** precisa de pelo menos um ciclo de barramento no meio (o normal no código de um 68000). Na memória de samples, deixe ~1 µs.

Acessos são sempre de 16 bits (word). Acessos de byte são **indefinidos**.

| Offset | Nome | R/W | Descrição |
|---|---|---|---|
| +$0 | DATA | R/W | Lê/escreve na memória selecionada por ACC_TGT no endereço ACC_ADDR; depois soma ACC_INC |
| +$2 | STATUS | R | bit0 VBLANK, bit1 HBLANK, bit2 RENDER_OVERFLOW, bit3 SPRITE_LIMIT (bits 2 e 3 ficam presos até a leitura, que os limpa) |
| +$4 | REG_SEL | R/W | Índice do registrador interno (0–15) |
| +$6 | REG_DATA | R/W | Valor do registrador selecionado |
| +$8 | VCOUNT | R | Linha HDMI atual (0–524) |
| +$A | HCOUNT | R | Coluna HDMI atual (0–799) |
| +$C | ID | R | `$5658` ("VX") |
| +$E | — | — | Reservado |

### 2.1 Registradores internos (via REG_SEL / REG_DATA)

| # | Nome | Bits | Descrição |
|---|---|---|---|
| 0 | MODE | [0] DISP_EN | 0 = tela inteira com a cor de fundo |
| 1 | BGCOLOR | [7:0] | Índice de CRAM usado como fundo e como borda |
| 2 | A_BASE | [15:0] | Endereço (em words) da nametable do plano A |
| 3 | B_BASE | [15:0] | Endereço (em words) da nametable do plano B |
| 4 | PSIZE | [1:0] A largura, [3:2] A altura, [5:4] B largura, [7:6] B altura | 0 = 32, 1 = 64, 2/3 = 128 tiles |
| 5 | A_SX | [15:0] | Scroll horizontal do plano A, em pixels |
| 6 | A_SY | [15:0] | Scroll vertical do plano A |
| 7 | B_SX | [15:0] | Scroll horizontal do plano B |
| 8 | B_SY | [15:0] | Scroll vertical do plano B |
| 9 | TILE_BASE | [15:0] | Endereço (em words) do tile 0 |
| 10 | SMODE | [0] A por linha, [1] B por linha, [2] A por coluna, [3] B por coluna | Modos de scroll |
| 11 | HS_BASE | [15:0] | Tabela de hscroll na VRAM: 2 words por linha (A, B), endereço `HS_BASE + 2*linha + plano` |
| 12 | ACC_TGT | [2:0] | 0 = VRAM, 1 = CRAM, 2 = VSRAM, 3 = SAT, 4 = registradores da APU, 5 = memória de samples |
| 13 | ACC_ADDR | [15:0] | Endereço da porta DATA (em words) |
| 14 | ACC_INC | [15:0] | Incremento automático depois de cada acesso a DATA |
| 15 | ACC_ADDR_HI | [15:0] | Parte alta do endereço da porta DATA (alvo 5: endereço de word = `{ACC_ADDR_HI, ACC_ADDR}`). Recebe o vai-um de ACC_ADDR em qualquer acesso a DATA. |

Convenção de scroll: o pixel de tela `x` mostra o pixel de plano
`(x + SX) mod largura`. O mesmo vale para `y`. Isso é diferente do MD original,
em que o hscroll é subtraído. Quem portar código do SGDK precisa negar o valor.

---

## 3. Formatos de memória

### 3.1 VRAM (64 KB = 32768 words)

**Tile 4bpp (16 words = 32 bytes, igual ao MD):** a linha `r` ocupa as words
`2r` e `2r+1`. Na word 0 ficam os pixels 0–3 (nibble alto primeiro). Na word 1,
os pixels 4–7. O nibble 0 é transparente.

Endereço da linha `r` do tile `t`: `TILE_BASE + t*16 + 2*r`.

**Entrada de nametable (2 words, 32 bits):**

| Word | Bits | Campo |
|---|---|---|
| 0 | [13:0] | Número do tile (0–16383; na M1 o endereço passa da VRAM de 64 KB e dá a volta) |
| 0 | [14] | HFLIP |
| 0 | [15] | VFLIP |
| 1 | [3:0] | Paleta (0–15) |
| 1 | [4] | Prioridade |
| 1 | [15:5] | Reservado (8bpp, blend etc.) |

Endereço da entrada (coluna `c`, linha `l`) com largura `W` em tiles:
`BASE + 2*(l*W + c)`.

### 3.2 Scroll por linha e por coluna

- **Por linha (SMODE bit 0/1):** o SX do plano vem de `VRAM[HS_BASE + 2*linha + plano]`. Nesse modo, o registrador A_SX/B_SX é ignorado.
- **Por coluna (SMODE bit 2/3):** o SY vem de `VSRAM[2*coluna + plano]`, onde `coluna = tile_buscado / 2`. As colunas de 16 px ficam alinhadas à grade de tiles **já deslocada** pelo scroll horizontal. Com scroll fino, a borda esquerda tem o mesmo efeito do MD.
- A VSRAM tem 64 words (até 32 colunas por plano).

### 3.3 SAT (128 sprites × 4 words = 512 words)

| Word | Bits | Campo |
|---|---|---|
| 0 | [9:0] | Y (com sinal, −512..511; linha 0 = topo da tela) |
| 0 | [12:10] | Altura − 1 (1..8 tiles) |
| 0 | [15:13] | Largura − 1 (1..8 tiles) |
| 1 | [9:0] | X (com sinal) |
| 1 | [14:11] | Paleta |
| 1 | [15] | Prioridade |
| 2 | [13:0] | Primeiro tile |
| 2 | [14] / [15] | HFLIP / VFLIP (o sprite inteiro) |
| 3 | [0] | Habilitado |
| 3 | [15:1] | Reservado (escala, blend) |

- Os tiles do sprite ficam em **ordem de coluna**, como no MD (`tile + coluna*altura + linha`). Isso é compatível com a saída do rescomp do SGDK.
- Diferente do MD, não há lista encadeada: a SAT inteira é varrida a cada linha. O índice menor fica na frente.
- **Limites por linha:** 32 sprites **e** 64 colunas de tile (512 px). Ao atingir qualquer um dos dois, os sprites seguintes da linha são descartados e STATUS bit3 é ligado.

### 3.4 CRAM (256 words)

Cada word é `0RRRRRGGGGGBBBBB` (RGB555). O índice de cor é
`paleta*16 + nibble`. A expansão para 8 bits é feita assim: `c8 = {c5, c5[4:2]}`.

---

## 4. Composição (ordem de prioridade)

Do mais alto para o mais baixo (igual ao MD):

1. Sprite com prioridade 1
2. Plano A com prioridade 1
3. Plano B com prioridade 1
4. Sprite com prioridade 0
5. Plano A com prioridade 0
6. Plano B com prioridade 0
7. BGCOLOR

Pixel com nibble 0 é transparente.

---

## 5. Timing de vídeo

- Saída 640×480@60 (VESA): total 800×525, H front porch/sync/back porch = 16/96/48, V front porch/sync/back porch = 10/2/33, sync negativos. O clock de pixel é 25,2 MHz (na Tang, PLL a partir de 27 MHz; 25,175 também serve).
- Área interna: linhas HDMI 16–463, com cada linha interna exibida duas vezes e cada pixel interno duas vezes na horizontal.
- `VBLANK = (vc < 16) || (vc >= 464)`.
- **Clock do sistema = 2× o clock de pixel (50,4 MHz).** A saída de vídeo avança com um clock enable.
- **Renderização por linha com buffer duplo:** enquanto a linha interna `y` aparece na tela (2 linhas HDMI = 3200 ciclos de sistema), o renderizador monta a linha `y+1` em três buffers (A, B e sprites). A composição é feita na saída.
- Orçamento por linha (pior caso): plano A 534 + plano B 534 + varredura da SAT 384 + desenho de sprites ~800 = **~2260 de 3200 ciclos**. Se estourar, o bit RENDER_OVERFLOW é ligado; isso nunca aconteceu nos testes.
- O buffer de sprites é zerado durante a passada do plano A, no mesmo ciclo em que cada pixel do plano A é escrito. Os sprites são desenhados de trás para frente, sem leitura-modificação-escrita.

---

## 6. Interface de barramento interna

**Barramento síncrono** (autoteste e testbenches): `bus_cs, bus_we, bus_addr[2:0], bus_wdata → bus_rdata, bus_ack`. A requisição fica ativa até o ack, e o mestre baixa `bus_cs` antes da próxima.

**Leitura imediata** (usada pelo adaptador da porta):
- `peek_addr → peek_data/peek_valid`, um ciclo depois;
- `rd_commit` aplica os efeitos colaterais da leitura: na porta DATA, endereço += INC e novo prefetch; no STATUS, limpa as flags presas.

O `md_fdc_adapter` M4.2 é somente escrita: sincroniza strobes, captura uma palavra por ciclo, limita FIFO a 16 incluindo pedido em voo e rejeita palavra nova em overflow. md_d_oe e rd_commit permanecem zero. /CAS0 não é usado para detectar leitura. Não há fallback temporal de leitura. O modelo legado M2 é hipotético e isolado do RTL sintetizável. Ver [relatório M4.2](../M4_2_delivery/RELATORIO_TECNICO.md) para CDC, protocolo de software e limites de evidência.

## 6.1 Memórias e recursos (medido na M1)

- **VRAM:** SDP BSRAM (1 porta de escrita para a CPU, 1 de leitura). O renderizador tem prioridade na leitura e a CPU usa os ciclos livres (o renderizador ocupa 4 de cada 13 ciclos).
- **CRAM:** duas cópias de 256×16, uma para o display e outra para a leitura pela CPU.
- **Line buffers:** 2 × 1024×9 (planos A e B, buffer duplo).
- **SAT:** 512×16 em BSRAM, com a porta de leitura compartilhada da mesma forma que a VRAM. A **VSRAM** usa RAM distribuída.
- **Yosys `synth_gowin` (M3, estimativa antes do P&R):** ~4.400 LUT + 892 ALU + 197 LUT-RAM (cerca de 30% da GW2AR-18) e **38 de 46 blocos BSRAM**. A APU usa ~2.800 LUTs com um único multiplicador compartilhado; o Yosys 0.33 ainda não usa os DSPs da Gowin, mas o Gowin EDA usa. O timing a 50,4 MHz só vai ser conhecido no P&R, na M4.
- ⚠️ **A BSRAM é o recurso escasso.** Sobram 8 blocos. Uma VRAM maior que 64 KB terá que ir para a SDRAM embutida.

## 7. Hardware M4.2

Três SN74LVC245A a 3V3, todos em direção fixa MD→Tang; nenhum driver FPGA→console. Sem 74HC688, /DTACK ou controle de direção por /CAS0. Pinagem VA6 a confirmar, /DISK desconectado. Ver [esquema vigente](../M4_2_delivery/CN2_WRITE_ONLY_SCHEMATIC.md). Alegações de leitura M4.1 são históricas e não autorizam ligação física.

## 7.1 Áudio na placa (M3/M5)

- **O som original do Mega Drive (YM2612 + PSG) continua sendo gerado no console.** Como a imagem e o som saem pelo HDMI da Tang, esse áudio analógico precisa entrar na placa: um **ADC I2S** (PCM1808) digitaliza o sinal, e a APU o mistura com os canais novos (registrador EXTVOL).
- **De onde vem o sinal (corrigido na M4.1, pelos esquemas):**
  - **Model 2:** **SL3/SR3 (B27/A27)** da porta de expansão. É a saída do áudio do console, já misturado com o áudio do cartucho.
  - **Model 1:** SL3/SR3 são N.C. Use a **saída estéreo do fone de ouvido** (frente) com um cabo P2–P2, como o "mixing cable" do Mega CD.
  - **SL2/SR2 (B29/A29) são entrada** para o mixer do console. Ficam livres para uma futura saída analógica da VDPX.
  - A placa adaptadora tem uma chave/jumper entre "fone" e "SL3/SR3", e as duas fontes vão para o mesmo PCM1808.
- **Saída:** no M4 vai pelo HDMI (pacotes de áudio). A mesma amostra também sai em I2S, para o amplificador MAX98357A da Tang Nano 20K ou para um DAC.
- **Entrada analógica:** nível de linha, com acoplamento AC e divisor/bias para a faixa do ADC. ⚠️ Os níveis exatos do Model 2 ainda precisam ser medidos.
- **Pinos da FPGA:** BCLK, LRCK, DOUT (DAC) e DIN (ADC), mais o SCK do ADC se ele não for mestre. São 4 ou 5 pinos.

## 8. Compatibilidade com jogos antigos (descartada pela porta de expansão)

Os esquemas mostram que o CN2 **não** permite espionar o VDP original:
- só existem VA1–VA17 (VA18/VA19 no Model 2);
- não há /AS nem R/W;
- nenhum dos sinais decodificados (/ROM, /RAS2, /ASEL, /FDC) cobre `$C00000`.

Rodar jogos antigos pela VDPX exigiria ligar fios dentro do console, nos pinos do VDP, como fazem os mods de HDMI. Isso foge do escopo deste projeto.

## 10. APU (M3)

### 10.1 Visão geral

- **Saída:** 48 kHz estéreo, 16 bits. Um tick a cada 1050 ciclos de 50,4 MHz (exatamente 48 kHz).
- **8 canais PCM (0–7):** amostras de 8 bits com sinal, lidas da memória de samples (SDRAM da Tang no M4). Têm loop, pitch 4.12 (até ~16×) e volume L/R.
- **8 canais wavetable (8–15):** onda de 32 passos × 4 bits (estilo PC Engine/Namco) ou ruído (LFSR de 15 bits). Têm frequência e volume L/R. A onda do canal 8+k é a onda k.
- **Entrada externa:** o áudio do Mega Drive pelo ADC I2S, com volume próprio (EXTVOL, 0x80 = 1,0).
- **Envelopes:** feitos por software (escrevendo VOL), como no PSG do MD.

### 10.2 Registradores (alvo 4 da porta DATA, 256 words)

| Endereço | PCM c (0–7), base c·8 | Wavetable c (8–15), base c·8 |
|---|---|---|
| +0 | CTRL: [0] KEY (1 = começa do início, 0 = para), [1] LOOP | CTRL: [0] EN, [1] NOISE. Qualquer escrita zera a fase e o LFSR |
| +1 | START_L | FREQ (fase de 20 bits: f = FREQ·48000/2²⁰ Hz, máx. ~3 kHz) |
| +2 | START_H [6:0] (START = endereço de **byte** de 23 bits) | VOL ([15:8] L, [7:0] R) |
| +3 | LEN (amostras) | — |
| +4 | LOOPST (offset do loop) | — |
| +5 | PITCH (4.12; 0x1000 = 48 kHz) | — |
| +6 | VOL ([15:8] L, [7:0] R) | — |

| Endereço | Conteúdo |
|---|---|
| 128 + w·8 + i | Onda w (0–7): a word i guarda as amostras 4i..4i+3 (nibble alto primeiro) |
| 192 | MASTER ([15:8] L, [7:0] R) |
| 193 | EXTVOL (reset = 0x8080 = unidade, assim o som do MD passa sem configurar nada) |
| 194 | STATUS (leitura): bits [7:0] = canais PCM tocando |

- As escritas entram numa FIFO de 32 posições e são aplicadas **no início do próximo tick**, na ordem em que chegaram. Assim, mudanças de registrador sempre caem alinhadas a uma amostra.
- Um 68000 consegue no máximo ~13 escritas por tick, então a FIFO nunca enche na prática. Se encher, o /DTACK espera o próximo tick.
- A leitura de registradores da APU mostra o valor já aplicado.

### 10.3 Aritmética exata (o modelo `sim/apumodel.h` segue isto bit a bit)

Para cada tick:

1. Aplica a FIFO.
2. Para cada canal PCM tocando, se `pos.int ≥ LEN`:
   - com LOOP e `LEN > LOOPST`: `pos −= (LEN − LOOPST)·4096`; se ainda `≥ LEN`, `pos = LOOPST·4096`;
   - senão, o canal para.
3. `s` = byte com sinal em `START + pos.int` (big-endian: byte par = bits [15:8]) e, em seguida, `pos += PITCH`.
4. Wavetable habilitado:
   - `s = (nibble[fase ≫ 15] − 8)·16`, ou `±96` no modo ruído;
   - `fase += FREQ` (20 bits); no modo ruído, o estouro da fase avança o LFSR: `novo bit14 = b0 ⊕ b1`.
5. Acumula `acc_L += s·VOL_L` e `acc_R += s·VOL_R` (s com sinal, VOL sem sinal).
6. Saída: `out = sat16((acc·MASTER) ≫ 10 + (ext·EXTVOL) ≫ 7)`, com deslocamentos aritméticos.
7. O `ext` usado num tick é o quadro I2S recebido no quadro anterior.

### 10.4 Memória de samples (alvo 5)

- Endereço de word de 23 bits = `{ACC_ADDR_HI, ACC_ADDR}`, com incremento ACC_INC. A memória é big-endian.
- Escritas e leituras passam pelo árbitro da APU; a APU tem prioridade.
- Na simulação, a memória é um modelo de 2 MB com 6 ciclos de latência. No M4 entra a SDRAM de 8 MB.

### 10.5 I2S

- Philips, 64 BCLK por quadro, LRCK baixo = esquerdo.
- **TX:** 16 bits.
- **RX:** 24 bits, dos quais se usam os 16 de cima.
- **BCLK:** 3,072 MHz com jitter de ±1 ciclo de 50,4 MHz. No M4 pode vir de uma PLL de áudio.

## 11. Placa (M4)

### 11.1 Estrutura

- **`rtl/board/vdpx_board.v`**: núcleo independente de tecnologia. Inclui:
  - adaptador 68000;
  - autoteste;
  - VDPX + APU;
  - controlador da SDRAM;
  - FIFO de vídeo e sincronizador de áudio entre os domínios;
  - transmissor HDMI.
- **`rtl/board/tang_top.v`**: primitivas Gowin. São 2 rPLL, CLKDIV, 4 OSER10 e 4 ELVDS_OBUF, além dos tristates do barramento do MD e da SDRAM.

### 11.2 HDMI

- 640×480@60 (VIC 1), RGB 4:3.
- **Uma data island por linha**, entre x = 644 e 719 (preâmbulo, guard, 2 pacotes, guard):
  - **Slot 0:** Audio Sample Packet com até 4 amostras estéreo de 24 bits (os 16 de cima vêm do mixer). O channel status IEC 60958 indica 48 kHz.
  - **Slot 1:**
    - AVI InfoFrame na linha 480;
    - Audio InfoFrame na linha 481;
    - Audio Clock Regeneration (N = 6144, CTS = 25200) a cada 4 linhas;
    - pacote nulo nas demais.
- **Formato dos pacotes:** segue a especificação HDMI 1.4 e a implementação de referência hdl-util/hdmi (MIT), sem copiar o código dela.

### 11.3 SDRAM (memória de samples)

- A SDRAM de 64 Mbit dentro da GW2AR-18 (2M × 32) roda a 50,4 MHz, com clock invertido e CAS latency 2.
- Cada acesso de 16 bits é ACTIVE + READ/WRITE com auto-precharge (7 ciclos). Há AUTO REFRESH a cada 700 ciclos.
- A APU faz ~8 leituras por tick de 48 kHz, ou seja, menos de 6% da banda.

### 11.4 Autoteste

- Um ROM de 4096 × 24 bits com um roteiro de operações de barramento: WRITE, WAITVB, JUMP e FILL2. É gerado por `scripts/gen_selftest.py`.
- Desenha uma cena, anima 6 sprites e toca som (incluindo um sample lido da SDRAM).
- Com isso, a placa pode ser testada sem o Mega Drive.

### 11.5 Verificação (`make m4sim`)

- A placa inteira é simulada com dois clocks e um modelo da SDRAM que confere protocolo e timing (tRCD, tRC, tRP, refresh, CL).
- Um **modelo de TV em C++** decodifica os símbolos TMDS. Ele confere:
  - guard bands, preâmbulos e TERC4;
  - BCH de cada pacote;
  - paridade e channel status IEC;
  - checksums das InfoFrames;
  - N/CTS;
  - equilíbrio DC do 8b/10b.
- Depois ele reconstrói:
  - **os frames**, comparados com o modelo de vídeo;
  - **o áudio**, comparado amostra a amostra com o mixer, que por sua vez é comparado com o modelo da APU.

## 9. Roadmap

| Fase | Conteúdo |
|---|---|
| **M0** | Esta especificação |
| **M1** | Núcleo: timing, planos A/B, CRAM, composição, porta DATA, testbench Verilator com modelo de referência em C++ e cenas aleatórias |
| **M1.5** | Sprites (SAT, limites por linha, buffer de sprites), scroll por linha e por coluna, clock 2× |
| **M2** | adaptador do barramento + co-simulação com fx68k rodando um programa em C para 68000 |
| **M3** | APU: 8 PCM + 8 wavetable/ruído, mixer com o áudio do MD (ADC), I2S, memória de samples |
| **M4** | Placa: HDMI com áudio, SDRAM, autoteste, topo Tang Nano 20K, .cst/.sdc, fluxos Gowin EDA e Yosys/nextpnr |
| **M4.1** | Interface corrigida pelos esquemas: janela /FDC ($A12000) sem /DTACK, FIFO de escrita, leitura com prefetch, /CAS0, FRES; ADC em SL3/SR3 ou no fone; pinos do HDMI DDC liberados |
| M2.5 [futuro] | Interrupção de VBlank para o 68000 (linha a confirmar na porta), DMA/fill interno da VRAM |
| M3 | Áudio: canais extras (PSG/PCM), saída I2S/HDMI |
| M4 | Síntese Gowin (Yosys + nextpnr-himbaechel ou Gowin EDA), PLL, TMDS/HDMI, padrão de teste na Tang |
| M5 | Placa adaptadora com 74LVC245, testes com analisador lógico, depois o Mega Drive real |
