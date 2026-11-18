# Arquitetura do DMA/Blitter: ECP5-P2

Arquivo: `rtl/vdpx_dma.v` (instanciado em `rtl/vdpx_top.v`). Clock único: `clk_sys` (50 MHz no ECP5, 50,4 MHz na
Tang). Sem segunda CPU, sem mudança no tamanho da VRAM.

```
 68000 ── CN2 (somente escrita) ── md_fdc_adapter (FIFO 16) ──┐
 autoteste (ROM de roteiro) ───────────────────────────────────┤ barramento interno (bus_cs/bus_we/bus_ack)
                                                               v
                                  vdpx_top: registradores, porta DATA, ACC_TGT
                       target 0..5 (P1) │               │ target 6 (P2): índice = ACC_ADDR[2:0]
                                        │               v
                                        │      vdpx_dma: registradores de preparação (6 x 16 bits)
                                        │               │ COMMAND = commit atômico + validação
                                        │               v
                                        │      fila de 4 comandos (snapshot completo de cada um)
                                        │               │
                                        │               v
                                        │      motor: IDLE -> [VWAIT] -> FILL/PATTERN ou RD<->WR
                                        │        │ escrita VRAM                │ leitura memória de samples
                                        v        v                             v
            porta de ESCRITA da VRAM: árbitro CPU > DMA       árbitro da memória de samples:
            (porta de LEITURA intocada: renderizador          porta da APU (APU > CPU, como na P1) > DMA,
             primeiro, depois leituras da CPU)                não-preemptivo -> sdram_ctrl RMW (P1)
```

## Componentes

| Bloco | Função |
|---|---|
| Registradores de preparação | `SRC_LO`, `SRC_HI`, `DST`, `LEN`, `VALUE0`, `VALUE1` + máscara "escrito desde o reset" |
| Validação | Combinacional no ciclo da escrita de `COMMAND`: op, completude, comprimento, faixa de destino, faixa de origem, fila |
| Fila | 4 entradas de 96 bits (op, VSYNC, tag, src 22 b, dst 15 b, len, VALUE0, VALUE1); push no commit, pop quando o motor está ocioso |
| Motor | `S_IDLE`, `S_VWAIT` (espera a borda de subida de vblank), `S_FILL` (FILL/PATTERN, 1 escrita por concessão), `S_RD` (pede 1 ou 2 words à memória de samples), `S_WR` (grava as words lidas) |
| Leitura em par | Fonte par e ≥ 2 words restantes → um acesso de 32 bits traz 2 words (`sm_pair`, `sm_rdata_hi`); fonte ímpar ou última word → acesso simples |
| Estatísticas | palavras do comando atual/último, ciclos de execução (sem a espera VSYNC), stalls, aceitos/rejeitados/concluídos/cancelados, último código de erro, tag, taxa |
| Taxa | `palavras × 1000 / ciclos` por divisor sequencial (1 bit por ciclo, 26 ciclos depois de cada comando) + double dabble → 4 dígitos BCD (0,1 MB/s a 50 MHz). Nenhuma divisão combinacional |
| Eventos | Pulsos para os scoreboards (`dma_events`): aceito, rejeitado + código, início, fim, fim cancelado, palavras, cancel, descartados |

## Operações

| Op | Código | Efeito | Taxa medida (50 MHz) |
|---|---|---|---|
| `DMA_FILL` | 1 | `LEN` words iguais a `VALUE0` a partir de `DST` | 1 ciclo/word (100 MB/s) sem contenção |
| `DMA_COPY` | 2 | `LEN` words da memória de samples (`{SRC_HI,SRC_LO}`, endereço de word) para a VRAM em `DST`, na ordem, big-endian como a P1 (a word de 16 bits é copiada tal qual) | 5,04 ciclos/word (19,8 MB/s) no controlador real; 5,5 ciclos/word (18,1 MB/s) na placa ECP5 simulada |
| `DMA_PATTERN` | 3 | words alternadas `VALUE0, VALUE1, VALUE0, ...` (útil para nametables: entrada = 2 words) | 1 ciclo/word |
| `DMA_CANCEL` | 4 | para o comando em execução num ponto seguro e esvazia a fila; nunca é enfileirado | — |
| `DMA_STATUS` | — | estado interno exposto ao painel HDMI e às leituras de simulação do target 6 (índices 8..15); **não é necessário ler** | — |

`DMA_PATTERN` foi implementado: custa um mux de 16 bits e um bit de fase, sem impacto mensurável no timing.

## Estados do motor e latência

| Transição | Ciclos |
|---|---|
| `COMMAND` no barramento → validação no DMA | 1 (registro `dma_cfg_we`) |
| validação → entrada na fila | mesmo ciclo |
| fila → início (`S_IDLE` → execução) | 1 ciclo, se ocioso |
| início → primeira escrita na VRAM (FILL) | 1 ciclo |
| início → primeira escrita (COPY) | 1 (pedido) + 1 (árbitro) + latência da SDRAM (≈ 8–9) |
| COPY por par de words | ≈ 10 ciclos (árbitro 1 + ACTIVE/tRCD/READ/CL/captura/tRP do controlador P1) |

Latência medida do primeiro comando: `COMMAND` → início ≤ 2 ciclos. Total por comando: `DMA_BENCHMARKS.md`.

## Reset e VBlank

- `rst` (reset do núcleo, que inclui a perda de lock do PLL) zera a fila, os registradores de preparação (máscara de
  validade), o motor e os pedidos (`sm_req`, `vw_req` caem). A VRAM fica com o que já foi escrito.
- O DMA **não** é bloqueado durante a área ativa: ele escreve sempre que tem concessão. Com `COMMAND[3]` (VSYNC), o
  comando só começa na borda de subida de vblank (linha 464 do HDMI), o que dá ~75 linhas (~120 mil ciclos) até
  o renderizador começar a primeira linha do quadro seguinte (linha 14).
