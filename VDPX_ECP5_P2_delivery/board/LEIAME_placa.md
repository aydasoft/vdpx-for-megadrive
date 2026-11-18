# MD-VDPX na Tang Nano 20K: montagem e primeiro teste

## 1. Teste só com a Tang (sem o Mega Drive)

1. Grave o bitstream:
   - **Gowin EDA:** `cd board && gw_sh gowin_build.tcl`, depois grave `impl/pnr/md_vdpx.fs` com o Gowin Programmer ou com `openFPGALoader -b tangnano20k md_vdpx.fs`.
   - **Fluxo aberto:** `make tang`, depois `openFPGALoader -b tangnano20k build_tang/md_vdpx.fs`.
   - **Histórico M4.1:** `board/prebuilt/md_vdpx.fs` não é write-only; NÃO usar conectado ao CN2.
2. Ligue um monitor ou TV pelo HDMI. Deve aparecer:
   - **imagem:** céu em degradê, "VDPX OK", amostra de cores, chão de tijolos e 6 bolas girando;
   - **som:** arpejo e um "blip" a cada 16 quadros. O blip sai da SDRAM; se ele tocar, o controlador da SDRAM está funcionando.
3. O som sai pelo HDMI e também pelo alto-falante da placa (MAX98357A).
4. O LED 6 (pino 20) pisca devagar no autoteste, fica aceso com o MD ativo e pisca rápido se houver erro (SDRAM não pronta, FIFO de vídeo vazia, áudio estourado ou escrita perdida na FIFO do CN2). Os LEDs 1–5 viraram pinos do MD e do ADC.
5. **Botões:**
   - S1 (pino 88) = reset (religa o autoteste e zera a sonda).
   - S2 (pino 87) = mostra/esconde o painel de diagnóstico (overlay) no HDMI. Começa ligado.
   - A primeira escrita do 68000 aceita na janela da VDPX desliga o autoteste sozinho.

### 1.1 Painel de diagnóstico (sonda CN2, M4.2 Claude)

A Tang mede os próprios sinais do CN2 (cada unidade = 1 ciclo de 50,4 MHz = **19,84 ns**) e escreve o resultado
na parte de baixo da imagem HDMI. Serve de analisador lógico enquanto não houver um de verdade.

| Linha | Significado | Esperado com a ROM `m68k/diag/diag_md.bin` |
|---|---|---|
| `AUTOTESTE:S/N MD:S/N` | autoteste ativo / já houve escrita do MD | `N` / `S` |
| `ESCRITAS ACEITAS` | palavras que entraram na FIFO | igual a "WORDS+BYTES" na tela do MD |
| `PERDIDAS` | palavras rejeitadas com FIFO cheia | `0000` |
| `FIFO MAX` | maior ocupação da FIFO (de 16) | baixo (01–02) |
| `ULTIMA A120xx=dddd` | último endereço/dado aceito | muda com a animação |
| `CICLO C/ FDWR … C/ CAS0` | ciclos de /FDC com /FDWR, e quantos deles também tiveram /CAS0 | o 2.º deveria ser 0 |
| `CICLO S/ FDWR … C/ CAS0` | ciclos de /FDC **sem** /FDWR (leituras), e quantos tiveram /CAS0 | se os dois forem iguais (≥64), /CAS0 marca leitura em $A12000 |
| `FDC BAIXO: ESC min-max SEM FDWR min-max` | largura de /FDC em escrita e em leitura | ~18 unidades (≈ 360 ns) |
| `FDC>FDWR min-max` / `LARGURA FDWR` | atraso /FDC→/FDWR e largura de /FDWR | define a janela de captura |
| `FDC>CAS0` | atraso /FDC→/CAS0 nas leituras | só para o estudo de leitura |
| `FRES:S/N PULSOS` | FRES agora / quantos pulsos de reset | `N` / 1 por reset do console |
| `CAS0 FORA` | /CAS0 fora de ciclos de /FDC | grande é normal (/CAS0 também serve à RAM) |

Os números da simulação (`out/m42_overlay.png`) vêm de strobes **hipotéticos**; só a medição real vale.

### 1.2 ROM de diagnóstico para o Mega Drive

`make diagrom` gera `m68k/diag/diag_md.bin` (header SEGA, checksum, desbloqueio do TMSS). Ela usa o VDP do
próprio console só para escrever o que emitiu, e na CN2 faz: 64 leituras (só para a sonda), 32 escritas de byte
no offset reservado $A1200E/F, a cena, rajadas de escrita no pior caso do 68000 e a animação com música.
Nunca depende de ler a VDPX. Gravar num flashcart só **depois** do checklist de pinagem e das medições.

## 2. CN2 — M4.2 write-only, físico BLOCKED

A montagem vigente está em [CN2_WRITE_ONLY_SCHEMATIC.md](../M4_2_delivery/CN2_WRITE_ONLY_SCHEMATIC.md). Dados e controles são unidirecionais MD→Tang, com três SN74LVC245A alimentados a 3V3, DIR fixo em A→B. md_d é input; md_d_oe fica zero. Não existe fallback USE_CAS0=0 no RTL de produção; /CAS0 não é evidência de leitura em $A12000. Não usar /DTACK nem 74HC688.

A pinagem VA6 japonesa NÃO foi confirmada. Consultar [candidatos e checklist](../M4_2_delivery/PINOUT_VA6_TO_CONFIRM.md) antes de qualquer ligação. Não usar automaticamente esquemas de outro modelo. A FIFO tem 16 entradas, overflow sticky com rejeição da palavra nova e não oferece backpressure. Somente escritas word alinhadas; protocolo limitado em [relatório técnico](../M4_2_delivery/RELATORIO_TECNICO.md).

Pinos FPGA permanecem no CST. Deixar SD sem cartão (80/85); verificar carga dos LEDs/RGB reaproveitados. Não usar 52/53 (DDC) nem 25/26 (1V8) para CN2. Alimentar Tang via USB com GND comum verificado; fontes não interligadas, /DISK e alimentação não regulada desconectados.

## 3. Clocks

| Clock | Origem | Uso |
|---|---|---|
| 27 MHz | cristal | — |
| 126 MHz | PLL A | serializador TMDS (DDR) |
| 25,2 MHz | 126 MHz ÷ 5 | pixel |
| 151,2 MHz | PLL B | — |
| 50,4 MHz | 151,2 MHz ÷ 3 | sistema |

Os domínios de sistema e de pixel só se comunicam por uma FIFO assíncrona (vídeo) e por um sincronizador com toggle (áudio).

MCLK ADC: média 12.288 MHz por divisor fracionário, com jitter de 1 clock do sistema. PCM1808 físico BLOCKED; testes e redesign de clock descritos no relatório M4.2.

## 4. Bitstream histórico (não aprovado para CN2) (`board/prebuilt/md_vdpx.fs`, M4.1)

- **Gerado com:** Yosys 0.71+ (git e419c4eef), nextpnr-himbaechel (git 5e2718b) e apycula 0.35.
- **Timing (nextpnr):** clk_sys fecha a ~58 MHz (precisa de 50,4) e clk_pix a ~69 MHz (precisa de 25,2).
- **Uso da FPGA:** 6.719 LUT4 (32%), 3.541 FF (22%), 43 de 46 BSRAM (93%), 2 PLLs.
- **Gravar:** `openFPGALoader -b tangnano20k board/prebuilt/md_vdpx.fs` (só na SRAM) ou `-f` (na flash).
