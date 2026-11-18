# Regressão gráfica (ECP5-P2)

**Resultado: PASS (simulação).** Nenhuma diferença de imagem em relação ao modelo de referência em nenhum banco
de teste, e o tempo de renderização das cenas da P1 é idêntico.

## 1. O DMA não compete com o renderizador

O renderizador usa só a porta de **leitura** da VRAM. O DMA usa só a porta de **escrita** (`DMA_ARBITRATION.md`
§1). Por isso o tempo de renderização de linha não depende do DMA. Isso é confirmado pelo monitor
`RENDER_BUDGET` (maior tempo de renderização de uma linha dupla, de 3200 ciclos disponíveis), comparando o log da P1
(`logs/p1_history/ecp5_sim/test50.log`) com o da P2 (`logs/ecp5_sim/test50.log`):

| Cena | Render máx P1 | Render máx P2 | APU P1 | APU P2 | erros de áudio P2 | resultado P2 |
|---|---|---|---|---|---|---|
| audio_md | 1535 | 1535 | — | 236 | 0 | OK |
| audio_musica | 1535 | 1535 | — | 261 | 0 | OK |
| audio_rand0 | 1535 | 1535 | — | 298 | 0 | OK |
| audio_rand1 | 1535 | 1535 | — | 291 | 0 | OK |
| audio_rand2 | 1535 | 1535 | — | 306 | 0 | OK |
| audio_rand3 | 1535 | 1535 | — | 312 | 0 | OK |
| audio_smem | 1535 | 1535 | — | 224 | 0 | OK |
| demo | 1856 | 1856 | — | 224 | 0 | OK |
| dma_basic | — | 1535 | — | 224 | 0 | OK |
| dma_bench | — | 2352 | — | 323 | 0 | OK |
| dma_cpu | — | 1535 | — | 224 | 0 | OK |
| dma_errors | — | 1535 | — | 224 | 0 | OK |
| dma_pcm | — | 1535 | — | 387 | 0 | OK |
| dma_render | — | 2319 | — | 224 | 0 | OK |
| dma_vsync | — | 1535 | — | 224 | 0 | OK |
| fx | 1539 | 1539 | — | 224 | 0 | OK |
| limites | 2138 | 2138 | — | 224 | 0 | OK |
| rand0 | 1924 | 1924 | — | 224 | 0 | OK |
| rand1 | 2343 | 2343 | — | 224 | 0 | OK |
| rand2 | 2344 | 2344 | — | 224 | 0 | OK |
| rand3 | 1960 | 1960 | — | 224 | 0 | OK |
| rand4 | 2190 | 2190 | — | 224 | 0 | OK |
| rand5 | 2349 | 2349 | — | 224 | 0 | OK |
| readback | 0 | 0 | — | 224 | 0 | OK |

- Nas 17 cenas da P1, o pior tempo de renderização é **igual, ciclo a ciclo**, ao da P1.
- O maior valor com DMA é 2352 de 3200 ciclos (`dma_bench`, cena de renderização pesada com sprites no limite e
  COPY/FILL simultâneos). A folga é de 848 ciclos por linha dupla, a mesma das cenas pesadas da P1 (2349).
- APU: a coluna P1 está vazia porque o monitor `APU_DEADLINE` é novo na P2 (`AUDIO_INTEGRITY_REPORT.md`).

## 2. Quadros comparados pixel a pixel

| Banco de teste | Quadros iguais ao modelo |
|---|---|
| `test50` (24 cenas, SDRAM RMW, 50 MHz) | 42 quadros, 0 diferenças (cada cena reporta `-> OK`) |
| `all_tests` (modelo comportamental, parâmetros Tang) | todos (cenas + M2 3/3, 2/2 + M4 6/6 HDMI) |
| `m2wo50` (fx68k) | 2/2 |
| ECP5 placa inteira, TMDS serial decodificado | 6/6, 3/3, 14/14 (perda de lock: 8 depois da recuperação) |

O modelo de referência aplica as escritas na VRAM **na ordem da porta**, a mesma que o renderizador vê. Portanto,
"quadro igual ao modelo" prova que o conteúdo da VRAM e a renderização estão corretos para aquele instante. Isso
**não** prova ausência de tearing: um quadro pode mostrar metade do conteúdo antigo e metade do novo, e o modelo
reproduz o mesmo.

## 3. Tearing

**Não declaramos ausência de tearing.** Quando um comando DMA (ou a CPU, como já ocorria na P1) altera tiles ou
nametables que estão sendo exibidos no mesmo quadro, a imagem pode misturar o conteúdo antigo e o novo. Em
`dma_render`, 55.459 escritas do DMA ocorreram com o renderizador ocupado, de propósito.

Mitigação disponível: o bit `VSYNC`. Em `dma_vsync`, **0 escritas** ocorreram com o renderizador ocupado: os
comandos começaram na borda do vblank e terminaram antes da primeira linha ativa. Isso vale enquanto o comando
couber no vblank (~120 mil ciclos: qualquer FILL/PATTERN da VRAM inteira; COPY até ~23 mil words com a fila vazia).

## 4. Mudança visível: painel de diagnóstico

O painel HDMI ganhou duas linhas de DMA e passou a começar na linha de texto 19 (era 21). Consequência nos bancos
de teste de placa (`sim/m4/tb_m4.cpp`, `sim/ecp5/tb_ecp5.cpp`): a área comparada pixel a pixel com o painel ligado
é a das linhas de texto 0..18 (era 0..20). O conteúdo do painel continua conferido, campo a campo, por OCR. Os
campos DMA são novos e esperados: `IDLE ---- 0` na Tang (autoteste sem DMA) e `DONE COPY 32 ... 18.1 MB/s` no ECP5.

A demonstração do DMA ocupa as linhas 5 e 6 do plano A (tiles 0x60/0x61), que estavam vazias no autoteste da P1.
O resto do autoteste é igual.
