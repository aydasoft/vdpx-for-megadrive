# M4.2 (versão Claude): conferência do relatório recebido e melhorias

Data: 16/11/2026. Tudo abaixo é **simulação e síntese**. Nenhum item físico (pinagem VA6, timing real do CN2,
PCM1808, leitura) passou a PASS: continuam **BLOCKED** até haver medição no console.

## 1. O relatório recebido procede?

Rodei as fontes da entrega **sem modificar** num ambiente separado (Verilator 5.020, Icarus 12, gcc 68000 do
Fedora, Yosys/nextpnr/apycula compilados aqui).

| Item do relatório | Deles | Aqui | Procede? |
|---|---|---|---|
| m42test (adaptador) | 491 entregues, 20 rejeitadas, 441 bins, 32 padrões | idêntico | sim |
| LVC245 / auditoria de pinos | PASS | PASS | sim |
| make test (17 cenas) | OK | OK | sim |
| M2 (legado, com leitura) | 3/3 frames, 1890 leituras, 0 erros | idêntico | sim |
| M4 integrado | 19 escritas, 6/6 frames, 33600 amostras, 0 erros | idêntico | sim |
| Autoteste sem MD | 3/3 frames, 14400 amostras | idêntico | sim |
| make tang | 5430 LUT4, 2851 FF, 42 BSRAM; 62,65/70,18 MHz | 5422 LUT4, 2851 FF, 42 BSRAM; 57,26/67,41 MHz | sim (Fmax varia com a versão do nextpnr; ambos fecham 50,4/25,2 MHz com folga) |

Não precisei dos contornos `CFG_CXXFLAGS_PCH_I` e `--no-assert-case` que eles usaram: são do pacote do Verilator
na máquina deles, não do projeto.

**Conclusão:** os números procedem. As decisões de segurança também estão corretas e foram mantidas: CN2
somente escrita, `md_d` só entrada, /CAS0 sem uso, prebuilt M4.1 proibido no CN2, +9 V e /DISK desligados,
pinos 52/53 e 25/26 livres.

## 2. Lacunas encontradas na entrega

1. **A co-simulação com o 68000 ainda usava o adaptador antigo com leitura** (`legacy_read_adapter.v`). O
   adaptador somente escrita que vai para a FPGA nunca rodou com um 68000 real em simulação, só com estímulo
   dirigido.
2. **Faltava um programa 68000 somente escrita.** O `main.c` lê a VDPX (status, autoteste de leitura), o que
   não funciona na placa M4.2.
3. **Nenhuma forma de medir o CN2 sem analisador lógico.** Os itens BLOCKED dependem de capturas que o usuário
   talvez não consiga fazer.
4. **O prefetch de leitura continuava ativo** no núcleo da placa, gastando ciclos depois de cada escrita em DATA
   sem que ninguém fosse ler.
5. "Transferência sustentada" ficou sem um número.

## 3. O que esta versão acrescenta

### 3.1 Sonda CN2 + painel no HDMI (`rtl/board/cn2_probe.v`, `vdpx_overlay.v`)

A própria Tang mede cada ciclo de /FDC (resolução 19,84 ns): largura em escrita e em leitura, atraso
/FDC→/FDWR, largura de /FDWR, atraso /FDC→/CAS0, /CAS0 fora da janela, pulsos de FRES, escritas aceitas e
perdidas, ocupação máxima da FIFO e a última escrita. O resultado aparece como texto sobre a imagem HDMI (S2
liga/desliga). Assim as medições que estavam BLOCKED podem ser feitas **sem analisador**, só com a TV.

- O testbench da placa decodifica o HDMI, faz OCR do painel e confere os 24 campos com os sinais que aplicou:
  **24/24**. A imagem fica em `out/m42_overlay.png`.
- A comparação dos quadros com o modelo ignora a faixa do painel, então a regressão continua pixel a pixel.

### 3.2 Prefetch desligado na placa

`vdpx_top` ganhou o parâmetro `PREFETCH`; a placa usa `PREFETCH=0`. Sem leituras não há o que antecipar.

### 3.3 Co-simulação fx68k com o adaptador somente escrita real (`make m2wo`)

`sim/m2/md_sim_top.sv` agora pode usar o `md_fdc_adapter.v` sintetizável (`-DM2WO`). O novo testbench
`tb_m2wo.cpp` exige que nenhuma leitura encontre o barramento dirigido (tem que ler FFFF), que nenhuma palavra
se perca e que **escritas do 68000 = escritas no núcleo**.

Programa: `m68k/diag/diag.c` (build SIM), que inclui rajadas no pior caso de velocidade do 68000:
64× `MOVE.W Dn,(An)` em VRAM, 64× `MOVE.W` na memória de samples (o caminho mais lento, pela SDRAM/árbitro da
APU) e 32× `MOVE.L` em REG_SEL/REG_DATA (duas words coladas), repetidas 4 vezes.

| | PREFETCH=0 (placa) | PREFETCH=1 |
|---|---|---|
| escritas 68000 / núcleo | 19707 / 19707 | 19707 / 19707 |
| leituras (barramento solto) | 64, todas FFFF | 64, todas FFFF |
| FIFO máxima | **1 de 16** | 1 de 16 |
| perdidas | 0 | 0 |
| menor intervalo entre escritas | 26 ciclos (516 ns) | 26 ciclos |
| frames / áudio | 2/2 iguais, 30877 amostras, 0 erros | idem |

**Taxa sustentada:** o 68000 a 7,67 MHz não escreve mais rápido que uma word a cada 4 clocks de barramento
(≈ 516 ns = 26 ciclos de 50,4 MHz). O núcleo absorve cada escrita antes da seguinte, inclusive na memória de
samples, então a FIFO nunca passou de 1. Isso é um limite **de simulação**: depende de os strobes reais do CN2
se parecerem com os hipotéticos. A sonda (3.1) mostra o `FIFO MAX` real.

### 3.4 ROM de diagnóstico para o Mega Drive (`m68k/diag`, `make diagrom`)

`diag_md.bin`: header SEGA com checksum, desbloqueio do TMSS (o Model 1 japonês com TMSS também funciona), texto
no VDP do console mostrando quantas words, bytes e leituras emitiu. Na CN2:

1. 64 leituras de $A12000–$A1200E: o resultado é ignorado; servem para a sonda dizer se /CAS0 acompanha
   leituras na janela /FDC.
2. 32 escritas de **byte** no offset reservado $A1200E/F (registrador inexistente, inofensivo): mostram se /FDWR
   aparece em escrita de byte.
3. Cena, rajadas no pior caso e animação com música e kick de PCM.

Na TV do Mega Drive aparece o que foi emitido; na TV da Tang, o que foi recebido. Basta comparar.

## 4. Regressão final

`make all_tests` (m42test + 17 cenas + M2 legado + **M2WO** + M4 com overlay): **exit 0**.
Autoteste sem MD (com o painel): 4/4 frames, 17600 amostras, 0 erros HDMI/SDRAM, LEDs autoteste=1 MD=0.
`make tang`: exit 0 (seção 5).

## 5. Bitstream

`board/m42_claude/md_vdpx.fs` (M4.2 Claude): somente escrita, PREFETCH=0, sonda + painel.

- Pós-route: clk_sys **57,71 MHz**, clk_pix **69,04 MHz** (precisam de 50,4 e 25,2).
- 8532 LUT4 (41%), 3713 FF (23%), 43/46 BSRAM, 2 PLL, 1 MULT18X18. A sonda + o painel custam ~3100 LUT4 e
  1 BSRAM em relação à entrega recebida (5422 LUT4); sobra espaço.
- Netlist: todas as portas `md_*` são **input** (conferido no JSON do Yosys); nenhum driver para o CN2. Continua **sem autorização para ligar ao CN2** até o checklist de pinagem VA6 da entrega recebida
ser cumprido. Primeiro teste seguro: só a Tang + TV (autoteste com o painel mostrando `MD:N`).

## 6. Ainda BLOCKED

- Pinagem VA6 japonesa (conferir com multímetro, checklist da entrega).
- Timing real de /FDC, /FDWR, /CAS0 (agora mensurável pela sonda).
- PCM1808 físico (clock com jitter de 1 ciclo).
- Leitura física: segue desabilitada. Se a sonda mostrar /CAS0 = leituras, uma leitura futura precisaria ainda de
  prova de não-contenção no barramento.

## 7. Limitação conhecida e ideia futura

Sem leituras o jogo não sabe quando a VDPX está em vblank. Hoje o jogo deve sincronizar pelo vblank do VDP do
próprio Mega Drive. Ideia para a M5: registradores "sombra" com commit automático no vblank da VDPX (o jogo
escreve a qualquer momento; a VDPX aplica tudo de uma vez no início do quadro), eliminando a necessidade de ler
status.
