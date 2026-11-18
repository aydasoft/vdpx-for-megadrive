# Segurança de memória do DMA (ECP5-P2)

Regra geral: **todo comando é validado inteiro no commit, antes da primeira escrita.** Um comando aceito é sempre
executado sem sair dos limites. Um comando inválido não escreve nada. Não existe *wraparound*: os endereços do
motor nunca dão a volta, porque a validação garante `DST + LEN ≤ 32768` e `SRC + LEN ≤ 2^22`, comparados em
aritmética com 1 bit a mais.

| # | Caso | Política | Código | Onde é testado |
|---|---|---|---|---|
| 1 | `LEN = 0` | REJECT | 1 `ZERO_LEN` | unitário, `dma_errors` |
| 2 | `DST ≥ 0x8000` | REJECT | 2 `DST_RANGE` | unitário, `dma_errors` |
| 3 | `DST + LEN > 0x8000` (cruza o fim da VRAM de 64 KiB) | REJECT, sem truncar (sem CLAMP) | 2 | unitário, `dma_errors` |
| 4 | `DST + LEN = 0x8000` (termina exatamente no fim) | ACCEPT | — | unitário, `dma_errors` |
| 5 | COPY `SRC + LEN > 2^SMEM_AW` (fim da memória de samples: 2^22 words = 8 MiB no ECP5; 2^20 no modelo das cenas; 2^16 no unitário) | REJECT | 3 `SRC_RANGE` | unitário, `dma_errors` |
| 6 | COPY com bits de `SRC` acima de `SMEM_AW` (ECP5: `SRC_HI ≥ 0x40`) | REJECT | 3 | unitário, `dma_errors` |
| 7 | Origem ímpar (não alinhada a 32 bits) | ACCEPT: 1 leitura simples, depois em par | — | unitário (aleatório), `dma_basic` |
| 8 | Comprimento ímpar | ACCEPT: última word com leitura simples | — | unitário, `dma_basic` |
| 9 | Parâmetro necessário nunca escrito desde o reset | REJECT | 5 `INCOMPLETE` | unitário, `dma_errors` |
| 10 | Op desconhecida (0, 5, 6, 7) | REJECT | 6 `BAD_OP` | unitário, `dma_errors` |
| 11 | Fila cheia | REJECT | 4 `QUEUE_FULL` | unitário, `dma_errors` |
| 12 | Parâmetros alterados depois do commit | ignorado pelo comando já aceito (snapshot) | — | unitário, `dma_errors` |
| 13 | Escrita no índice 6 (reservado) ou com `ACC_ADDR ≥ 8` | ignorada | — | unitário (índice 6); RTL (`ACC_ADDR[15:3] = 0`) |
| 14 | CANCEL com fila vazia e motor ocioso | ACCEPT, sem efeito | — | unitário, `dma_errors` |
| 15 | Reset durante a transferência | aborta; VRAM com as words já escritas; saídas inativas | — | unitário |
| 16 | Destino sobreposto à origem | não se aplica: origem (SDRAM) e destino (VRAM) são memórias diferentes | — | — |
| 17 | DMA e CPU escrevendo o mesmo endereço | ordem da porta de escrita (CPU primeiro no mesmo ciclo) | — | `dma_cpu` (scoreboard na ordem da porta) |
| 18 | DMA tocando CRAM, VSRAM, SAT, registradores, APU | **impossível**: o motor só tem a porta de escrita da VRAM e a porta de leitura da SDRAM | — | revisão do RTL |
| 19 | DMA escrevendo na SDRAM (samples da APU) | **impossível**: `sm_we` só é ativado pelo dono 1 (APU/CPU) | — | revisão do RTL, `dma_pcm` |

Não há política **CLAMP**, porque esconderia um erro de software. **WAIT** só existe para o bit `VSYNC`, que é
uma espera pedida pelo software. **ERROR** é registrado em todo REJECT: `último_erro`, contador `REJECTED` e painel.

## Verificações estruturais

- O teste unitário (`sim/p2/tb_dma_unit.sv`) confere cada escrita do DMA na VRAM contra o comando em execução:
  o endereço tem de ser exatamente `DST + k` (em ordem), o dado tem de ser o previsto e nenhuma escrita pode passar
  de `LEN`. Também confere as regras de handshake da SDRAM (pedido mantido até o `ack`, endereço estável, par só
  em endereço par). Qualquer escrita fora de `[DST, DST+LEN)` falha o teste.
- As mutações de `make dma_unit` precisam **falhar** (`expect_fail`), e falham:
  1. PATTERN sempre `VALUE0`;
  2. fonte do par avançando 1 em vez de 2;
  3. validação sem a checagem `DST + LEN > 32768` (o comando daria a volta na VRAM).
- Em todas as cenas, o `DmaCheck` confere cada escrita do DMA (endereço e dado) contra o fluxo previsto pelo
  modelo de referência: nenhuma escrita sobra ou falta.
