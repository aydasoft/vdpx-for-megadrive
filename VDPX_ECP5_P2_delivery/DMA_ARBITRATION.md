# Arbitragem do DMA (ECP5-P2)

O DMA tem **dois** pontos de contato com o resto do sistema: a porta de escrita da VRAM e a memória de samples
(SDRAM). A CRAM, a VSRAM, a SAT e os registradores de vídeo não são acessados pelo DMA.

## 1. VRAM (`rtl/vdpx_top.v`, linhas 108–111)

A VRAM é uma RAM de porta dupla simples (`vdpx_sdpram`): uma porta só de **leitura** (renderizador + leituras de CPU,
esta ordem, igual à P1) e uma porta só de **escrita** (CPU + DMA, novo na P2).

```verilog
wire dma_vw_gnt = dma_vw_req && !vram_we;      // CPU tem prioridade fixa
wire vw_we      = vram_we || dma_vw_gnt;
```

| Prioridade | Mestre | Observação |
|---|---|---|
| 1 | CPU (escrita pela porta DATA, target 0) | nunca espera pelo DMA; o caminho da P1 não ganhou nenhum ciclo |
| 2 | DMA | escreve em todo ciclo em que a CPU não escreve |
| — | Renderizador | **não disputa**: só lê, na outra porta. O DMA não pode atrasar a renderização de linha |

Consequências:
- **Impacto do DMA na renderização = zero ciclos por construção.** Medido (`GRAPHICS_REGRESSION.md`): nas 17
  cenas da P1, o maior tempo de renderização de linha é **idêntico** ao da P1 em todas; nas cenas de DMA, o maior
  é 2352 de 3200 ciclos (`dma_bench`, condição de renderização pesada). Em `dma_render`, 55.459 escritas do DMA
  foram feitas com o renderizador ocupado, e os quadros conferem pixel a pixel.
- **Pior caso de espera do DMA:** cada escrita da CPU na VRAM rouba 1 ciclo do DMA. Pela CN2, o 68000 entrega no
  máximo 1 word a cada 52 ciclos (menor intervalo medido em `m2wo50`/`m2bench`, ≈ 12 clocks do 68000). Se a FIFO
  do adaptador estiver acumulada, ela pode entregar até 16 words seguidas. O limite publicado,
  `N + ⌈N/25⌉ + 20` ciclos para FILL/PATTERN, cobre isso com folga. O autoteste interno escreve mais rápido
  (até 1 word a cada 2 ciclos), mas não é usado junto com o 68000.
- **Ordem:** se CPU e DMA escrevem o mesmo endereço, vale a ordem na porta de escrita. Os scoreboards aplicam as
  escritas na ordem da porta, e o modelo de referência só prevê o fluxo do DMA. Por isso a regra de protocolo nº 4
  em `DMA_REGISTER_MAP.md`.

### Leitura durante escrita (tearing)

O renderizador lê a VRAM ao longo da linha (pré-busca de linha). Quando o DMA, ou a CPU, como já acontecia na P1,
escreve um tile ou uma entrada de nametable que o renderizador lê **no mesmo quadro**, parte do quadro mostra o valor
antigo e parte o novo, e no mesmo endereço e ciclo o valor lido depende da implementação do bloco RAM. O conteúdo
final da VRAM está sempre correto, mas **pode haver tearing**. Não declaramos ausência de tearing. A mitigação é o
bit `VSYNC` (`COMMAND[3]`): o comando espera a borda de subida de vblank. Com isso:
- FILL/PATTERN cabem no vblank até ~120 mil words (vblank ≈ 120 mil ciclos), ou seja, sempre;
- COPY cabe até ~23 mil words por vblank (≈ 5,04 ciclos/word) se for o único comando. Comandos maiores terminam
  durante a área ativa do quadro seguinte.

## 2. Memória de samples / SDRAM (`rtl/vdpx_top.v`, linhas 249–264)

```
 APU (vozes PCM, prioridade interna APU > CPU, igual à P1) ──┐
 CPU (target 5, escrita/leitura da memória de samples) ──────┘  porta "APU" ─┐
                                                                             ├─ sm_own (dono não-preemptivo) ─ sdram_ctrl
 DMA (COPY: leitura simples ou em par de 32 bits) ──────────────────────────┘
```

| Prioridade | Mestre | Observação |
|---|---|---|
| 1 | porta da APU (APU, depois CPU) | exatamente o caminho da P1, + 1 ciclo de registro do dono |
| 2 | DMA | só ganha quando a porta da APU não tem pedido; nunca escreve na SDRAM |

O árbitro é **não-preemptivo**: o dono só troca depois do `ack` do controlador. O pior caso para a APU é,
portanto, esperar **um** acesso do DMA em curso (leitura em par: ACT + tRCD + READ + CL + captura + 2ª word +
pré-carga, ≈ 10–11 ciclos), mais um AUTO REFRESH (`REFRESH_INT = 700` ciclos; ≈ 9 ciclos), mais o ciclo do
árbitro.

### Prazo da APU (medido)

A APU tem um quadro de amostra de 1041 ciclos a 50 MHz (48 kHz) para buscar os samples de 8 vozes e mixar. Monitor
`APU_DEADLINE` (`sim/vdpx_sim.v`, `sim/ecp5/vdpx_sim_sdram.v`): maior tempo tick → amostra pronta.

| Medição (SDRAM RMW real, 50 MHz, `logs/ecp5_sim/test50.log`) | Pior tempo tick → amostra |
|---|---|
| Cenas de áudio sem DMA (maior: `audio_rand3`) | 312 ciclos |
| `dma_bench` (condição PCM: COPY de até 32 K words com vozes PCM tocando) | 323 ciclos |
| `dma_pcm` (8 vozes PCM da SDRAM + COPY/FILL contínuos) | **387 ciclos** (37 % do quadro) |

Folga restante no pior caso medido: 654 ciclos.

Não há prova formal do pior caso: o limite publicado é o medido (387 ciclos). Uma conta simples (mistura 224 +
8 buscas + 1 par do DMA + refresh ≈ 340) fica **abaixo** do medido, porque as escritas da CPU na memória de samples
são RMW (leitura + escrita) e as vozes podem buscar mais de uma vez por quadro. Por isso só o número medido é usado.
Risco R-P2-2 em `RISKS_AND_BLOCKERS.md`. O áudio é bit a bit igual ao modelo de referência (`AUDIO_INTEGRITY_REPORT.md`).

### Pior caso do DMA (para o protocolo sem leitura)

Por word copiada, o DMA espera no máximo: a APU busca 8 vozes por quadro de 1041 ciclos (≤ 8 acessos de ≈ 9 ciclos
cada) + escritas da CPU na memória de samples + refresh. O limite conservador publicado em `DMA_REGISTER_MAP.md`
(`16·N + 64` ciclos) é ~3× o medido em repouso (5,04) e ~3× o medido com 8 vozes PCM (5,3).

## 3. Fila e overflow

- 4 entradas; o comando em execução não ocupa entrada (até 5 comandos pendentes).
- Fila cheia → **REJECT** com código 4. Não há WAIT, porque a CN2 não tem backpressure e o adaptador perderia
  dados. Não há sobrescrita.
- `CANCEL` nunca é enfileirado: age imediatamente sobre a fila e o comando ativo.

## 4. CANCEL e ponto seguro

| Estado no CANCEL | Comportamento |
|---|---|
| `S_VWAIT` | termina no próximo ciclo, 0 words |
| `S_FILL` / `S_WR` | a escrita do ciclo atual (se concedida) acontece; nenhuma outra |
| `S_RD` com pedido pendente sem `ack` | espera o `ack` (o controlador SDRAM não aceita abortar no meio) e descarta os dados |
| Fila | todas as entradas descartadas (`ev_flushed` = quantidade, conferida pelo scoreboard) |

Nenhum acesso à SDRAM fica pela metade, e a fila nunca fica num estado inconsistente.

## 5. Reset

`rst` zera fila, motor, máscara de validade e o dono do árbitro (`sm_own = 0`). Um acesso da SDRAM em curso é
finalizado pelo próprio controlador, que tem o seu próprio reset/inicialização no `rst` do PLL.
