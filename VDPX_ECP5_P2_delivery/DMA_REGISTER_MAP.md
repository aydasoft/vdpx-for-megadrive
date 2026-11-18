# Mapa de registradores e protocolo somente-escrita do DMA

## Acesso

O DMA é o **target 6** da porta DATA (`ACC_TGT = 6`). O índice do registrador é `ACC_ADDR[2:0]`, com
`ACC_ADDR[15:3] = 0`, e `ACC_INC` funciona como nos outros targets. Uma rajada de 8 escritas em DATA, começando em
`ACC_ADDR = 0` com `ACC_INC = 1`, programa tudo e dispara.

Compatibilidade:
- **Targets 0..5:** inalterados.
- **Target 7:** continua sem efeito.
- **Os 16 registradores de `REG_SEL`:** inalterados.
- **Offsets `$A1200E/F`:** não são usados (a ROM de diagnóstico continua escrevendo bytes lá sem efeito).
- **Escritas no target 6 com `ACC_ADDR ≥ 8`:** ignoradas.

| Índice | Nome | Largura útil | Descrição |
|---|---|---|---|
| 0 | `DMA_SRC_LO` | 16 | bits 15..0 do endereço de **word** de origem na memória de samples (COPY) |
| 1 | `DMA_SRC_HI` | 16 | bits 31..16. A memória tem 2^22 words (8 MiB); bits acima disso fazem o COPY ser rejeitado |
| 2 | `DMA_DST` | 15 (+1) | endereço de word na VRAM (0..0x7FFF). Bit 15 = 1 → rejeitado |
| 3 | `DMA_LENGTH` | 16 | número de words (1..32768) |
| 4 | `DMA_VALUE0` | 16 | valor do FILL / primeira word do PATTERN |
| 5 | `DMA_VALUE1` | 16 | segunda word do PATTERN |
| 6 | — | — | reservado: escrita ignorada (permite a rajada 0..7) |
| 7 | `DMA_COMMAND` | 16 | **commit**: `[2:0]` op (1 FILL, 2 COPY, 3 PATTERN, 4 CANCEL), `[3]` VSYNC, `[7:4]` 0, `[15:8]` tag |

Leituras (só em simulação: o 68000 não lê a VDPX), target 6, índices 8..15:

| 8 STATUS | 9 WORDS | 10 CYCLES_LO | 11 CYCLES_HI | 12 ACCEPTED | 13 REJECTED | 14 DONE | 15 CANCELLED |
|---|---|---|---|---|---|---|---|

STATUS = `{busy, 0000, fila[2:0], estado[1:0], op[1:0], último_erro[3:0]}`.

## Commit atômico

Os índices 0..5 são **registradores de preparação**. Só a escrita em `DMA_COMMAND` valida o conjunto e copia
**todos** os valores para uma entrada da fila no mesmo ciclo. Consequências:
- um comando nunca começa com parâmetros pela metade, porque a cópia é feita só no commit;
- alterar parâmetros depois do commit não afeta o comando na fila (testado em `dma_errors` e no teste unitário);
- os parâmetros persistem: dois FILLs seguidos só precisam reescrever o que mudou.

## Validação e políticas

| Caso | Política | Código |
|---|---|---|
| op ∉ {1, 2, 3, 4} | **REJECT** | 6 `BAD_OP` |
| parâmetro necessário nunca escrito desde o reset (FILL: DST, LEN, VALUE0; PATTERN: + VALUE1; COPY: SRC_LO, SRC_HI, DST, LEN) | **REJECT** | 5 `INCOMPLETE` |
| `LEN = 0` | **REJECT** | 1 `ZERO_LEN` |
| `DST[15] = 1` ou `DST + LEN > 32768` (ultrapassa a VRAM) | **REJECT** (sem truncar, sem dar a volta) | 2 `DST_RANGE` |
| COPY com `SRC + LEN > 2^22` (origem fora da memória) | **REJECT** | 3 `SRC_RANGE` |
| fila cheia (1 em execução + 4 na fila) | **REJECT** | 4 `QUEUE_FULL` |
| DMA ocupado e fila com espaço | **ACCEPT** (vai para a fila, ordem FIFO) | 0 |
| uma word, último endereço da VRAM (`DST = 0x7FFF, LEN = 1`), últimas words da memória | **ACCEPT** | 0 |
| endereço "desalinhado" | não se aplica: endereçamento em words de 16 bits; origem ímpar é aceita (1 leitura simples e depois pares) | — |
| `CANCEL` | **ACCEPT** imediato: comando em execução para no próximo ponto seguro, fila esvaziada | evento de cancelamento |
| reset durante transferência | aborta tudo; VRAM fica com as words já escritas | — |

Rejeição: nada é escrito, `REJECTED++` e `último_erro` recebem o código, e o painel mostra `ERRO` se o DMA estiver
ocioso. Nenhum caso usa CLAMP nem WAIT. CLAMP esconderia o erro, e WAIT travaria o barramento e acabaria
estourando a FIFO da CN2, que não tem backpressure.

## Protocolo somente-escrita (sem polling)

O 68000 não lê a VDPX, e o vblank da VDPX não é sincronizado com o do VDP do Mega Drive. Regras para o software:

1. **Conte os comandos.** No máximo 5 podem estar pendentes (1 em execução + 4 na fila). O software só pode emitir o
   6º depois de provar, pelo limite de tempo abaixo, que o primeiro terminou.
2. **Limite de pior caso** (`DMA_ARBITRATION.md` §4), em ciclos de `clk_sys`, para N words:
   - FILL/PATTERN: `N + ⌈N/25⌉ + 20`, com escritas de CPU na VRAM no ritmo máximo do 68000;
   - COPY: `16·N + 64`, conservador, com APU, CPU na memória de samples e refresh no pior caso.
   Esperar esse tempo (contado pelo próprio 68000, por exemplo em linhas do VDP do console) é a única garantia sem
   leitura.
3. **Para trocar o que está na tela sem tearing,** use `VSYNC` (bit 3): o comando começa no vblank da VDPX, que o 68000
   não enxerga.
4. **Não escreva pela porta DATA numa região que um DMA pendente vai escrever.** A ordem efetiva é a da porta de
   escrita, com a CPU antes (`DMA_ARBITRATION.md`), e o resultado depende do tempo.
5. **Se o limite foi violado** (comando rejeitado por fila cheia), o efeito é só a ausência daquele comando: o painel
   mostra `ERROS` > 0. Para recomeçar de um estado conhecido, use `CANCEL`.

O benchmark com fx68k (`DMA_BENCHMARKS.md`) segue exatamente essas regras: espera fixa após cada comando, e o
testbench prova que o DMA já tinha terminado.
