# Benchmarks do DMA (ECP5-P2): números de simulação

**Tudo aqui é medido em simulação, ciclo a ciclo, a 50 MHz. Nenhum número é medição física.**
O desempenho em hardware está PENDENTE (`HARDWARE_TEST_GUIDE.md` §2).

Fontes:
- `logs/p2/m2bench.log`: `make m2bench`, co-simulação fx68k + adaptador CN2 somente escrita, programa
  `m68k/bench/bench.c`;
- `logs/ecp5_sim/test50.log`: cena `dma_bench` com o controlador SDRAM RMW real;
- `logs/ecp5_sim/ecp5_boardsim.log`: placa ECP5 inteira.

As tabelas abaixo são geradas por `scripts/p2_bench_report.py` (`logs/p2/bench_tables.md`). Nenhum valor foi
digitado à mão.

## Duas larguras de banda diferentes

| Caminho | O que limita | Valor medido |
|---|---|---|
| **Mega Drive → CN2 → VDPX** (método A, e também a carga da memória de samples) | o 68000: ≈ 12 clocks de 7,67 MHz por `MOVE.W (A0)+,(A1)` | **1,27 MB/s** (78,8 ciclos de 50 MHz por word, 64 KiB) com cópia desenrolada; 0,69 MB/s com laço DBRA |
| **SDRAM local → VRAM** (DMA COPY) | controlador SDRAM RMW da P1 (abre/fecha página a cada acesso), 2 words por acesso | **19,8 MB/s** (5,04 ciclos/word), em repouso e com renderização; 18,9 MB/s com 8 vozes PCM; 18,2 MB/s na placa ECP5 simulada (captura R3) |
| **Geração local → VRAM** (DMA FILL/PATTERN) | 1 escrita por ciclo na porta da VRAM | **100 MB/s** (1 ciclo/word), em todas as condições medidas |

A faixa de 25–50 MB/s **não** foi atingida pelo COPY. O limite é o controlador SDRAM de página fechada da P1, não o
motor do DMA. Ver "Próximos passos".

## O DMA não elimina a carga inicial

O COPY lê da memória de samples (SDRAM). Os dados chegam lá **pela CN2, ao mesmo custo do método A**: a coluna
"Carga" abaixo é praticamente igual à A1. O ganho do DMA existe quando:
1. os dados são **reutilizados** (carregados uma vez, por exemplo no boot, e copiados muitas vezes: quadros de
   animação, tiles de troca de cenário, etc.), ou
2. não há dado de origem (FILL/PATTERN).

### Método A (68000 copia pela CN2) e custo de CPU do método B — fx68k a 7,67 MHz, ciclos de 50 MHz

| Tamanho | A1 desenrolado | A1 MB/s | ciclos/palavra | A2 laço DBRA | A2 MB/s | Carga da memória de samples (A1) | Envio do comando DMA (CPU) | Escritas CN2 do comando |
|---|---|---|---|---|---|---|---|---|
| 256 B | 10860 (217 µs) | 1.18 | 84.8 | 19348 (387 µs) | 0.66 | 10808 (216 µs) | 1956 (39.1 µs) | 14 |
| 1024 B | 41343 (827 µs) | 1.24 | 80.7 | 74745 (1495 µs) | 0.68 | 41291 (826 µs) | 1956 (39.1 µs) | 14 |
| 4096 B | 162360 (3247 µs) | 1.26 | 79.3 | 296363 (5927 µs) | 0.69 | 162308 (3246 µs) | 1956 (39.1 µs) | 14 |
| 16384 B | 646428 (12929 µs) | 1.27 | 78.9 | 1182829 (23657 µs) | 0.69 | 646376 (12928 µs) | 1956 (39.1 µs) | 14 |
| 32768 B | 1291851 (25837 µs) | 1.27 | 78.8 | 2364785 (47296 µs) | 0.69 | 1291800 (25836 µs) | 1956 (39.1 µs) | 14 |
| 65536 B | 2582698 (51654 µs) | 1.27 | 78.8 | 4728696 (94574 µs) | 0.69 | 2582646 (51653 µs) | 1955 (39.1 µs) | 14 |

### Execução do DMA COPY na co-simulação fx68k (memória de samples comportamental, latência 6)

| Palavras | Ciclos | ciclos/palavra | MB/s |
|---|---|---|---|
| 128 | 832 | 6.50 | 15.38 |
| 512 | 3328 | 6.50 | 15.38 |
| 2048 | 13312 | 6.50 | 15.38 |
| 8192 | 53248 | 6.50 | 15.38 |
| 16384 | 106496 | 6.50 | 15.38 |
| 32768 | 212992 | 6.50 | 15.38 |

### Método B: execução do DMA com o controlador SDRAM RMW real (cena dma_bench, 50 MHz, captura R2)

| Condição | Operação | Palavras | Ciclos | ciclos/palavra | MB/s | Ciclos de espera (stalls) |
|---|---|---|---|---|---|---|
| repouso | FILL | 128 | 128 | 1.000 | 100.00 | 0 |
| repouso | FILL | 512 | 512 | 1.000 | 100.00 | 0 |
| repouso | FILL | 2048 | 2048 | 1.000 | 100.00 | 0 |
| repouso | FILL | 8192 | 8192 | 1.000 | 100.00 | 0 |
| repouso | FILL | 16384 | 16384 | 1.000 | 100.00 | 0 |
| repouso | FILL | 32768 | 32768 | 1.000 | 100.00 | 0 |
| repouso | PATTERN | 128 | 128 | 1.000 | 100.00 | 0 |
| repouso | PATTERN | 512 | 512 | 1.000 | 100.00 | 0 |
| repouso | PATTERN | 2048 | 2048 | 1.000 | 100.00 | 0 |
| repouso | PATTERN | 8192 | 8192 | 1.000 | 100.00 | 0 |
| repouso | PATTERN | 16384 | 16384 | 1.000 | 100.00 | 0 |
| repouso | PATTERN | 32768 | 32768 | 1.000 | 100.00 | 0 |
| repouso | COPY | 128 | 646 | 5.047 | 19.81 | 64 |
| repouso | COPY | 512 | 2579 | 5.037 | 19.85 | 256 |
| repouso | COPY | 2048 | 10324 | 5.041 | 19.84 | 1024 |
| repouso | COPY | 8192 | 41314 | 5.043 | 19.83 | 4096 |
| repouso | COPY | 16384 | 82630 | 5.043 | 19.83 | 8192 |
| repouso | COPY | 32768 | 165257 | 5.043 | 19.83 | 16384 |
| render | FILL | 128 | 128 | 1.000 | 100.00 | 0 |
| render | FILL | 512 | 512 | 1.000 | 100.00 | 0 |
| render | FILL | 2048 | 2048 | 1.000 | 100.00 | 0 |
| render | FILL | 8192 | 8192 | 1.000 | 100.00 | 0 |
| render | FILL | 16384 | 16384 | 1.000 | 100.00 | 0 |
| render | FILL | 32768 | 32768 | 1.000 | 100.00 | 0 |
| render | PATTERN | 128 | 128 | 1.000 | 100.00 | 0 |
| render | PATTERN | 512 | 512 | 1.000 | 100.00 | 0 |
| render | PATTERN | 2048 | 2048 | 1.000 | 100.00 | 0 |
| render | PATTERN | 8192 | 8192 | 1.000 | 100.00 | 0 |
| render | PATTERN | 16384 | 16384 | 1.000 | 100.00 | 0 |
| render | PATTERN | 32768 | 32768 | 1.000 | 100.00 | 0 |
| render | COPY | 128 | 646 | 5.047 | 19.81 | 64 |
| render | COPY | 512 | 2578 | 5.035 | 19.86 | 256 |
| render | COPY | 2048 | 10330 | 5.044 | 19.83 | 1024 |
| render | COPY | 8192 | 41314 | 5.043 | 19.83 | 4096 |
| render | COPY | 16384 | 82629 | 5.043 | 19.83 | 8192 |
| render | COPY | 32768 | 165257 | 5.043 | 19.83 | 16384 |
| pcm | FILL | 128 | 128 | 1.000 | 100.00 | 0 |
| pcm | FILL | 512 | 512 | 1.000 | 100.00 | 0 |
| pcm | FILL | 2048 | 2048 | 1.000 | 100.00 | 0 |
| pcm | FILL | 8192 | 8192 | 1.000 | 100.00 | 0 |
| pcm | FILL | 16384 | 16384 | 1.000 | 100.00 | 0 |
| pcm | FILL | 32768 | 32768 | 1.000 | 100.00 | 0 |
| pcm | PATTERN | 128 | 128 | 1.000 | 100.00 | 0 |
| pcm | PATTERN | 512 | 512 | 1.000 | 100.00 | 0 |
| pcm | PATTERN | 2048 | 2048 | 1.000 | 100.00 | 0 |
| pcm | PATTERN | 8192 | 8192 | 1.000 | 100.00 | 0 |
| pcm | PATTERN | 16384 | 16384 | 1.000 | 100.00 | 0 |
| pcm | PATTERN | 32768 | 32768 | 1.000 | 100.00 | 0 |
| pcm | COPY | 128 | 696 | 5.438 | 18.39 | 104 |
| pcm | COPY | 512 | 2700 | 5.273 | 18.96 | 353 |
| pcm | COPY | 2048 | 10823 | 5.285 | 18.92 | 1425 |
| pcm | COPY | 8192 | 43384 | 5.296 | 18.88 | 5814 |
| pcm | COPY | 16384 | 86735 | 5.294 | 18.89 | 11583 |
| pcm | COPY | 32768 | 173515 | 5.295 | 18.88 | 23200 |

Placa ECP5 (simulação da placa inteira, SDRAM com atraso de placa e captura R3): COPY de 32 palavras do autoteste em 176 ciclos = 5.50 ciclos/palavra = 18.18 MB/s.

## Comparação A × B (derivada dos ciclos acima)

"B total" = envio do comando pela CPU (1956 ciclos, 14 escritas na CN2) + execução do DMA com a SDRAM real
(condição repouso). "B + carga" soma a carga inicial dos dados pela CN2.

| Tamanho | A1 (CPU copia) | B total (dados já na SDRAM) | Ganho de tempo | Tempo de CPU A1 / B | B + carga inicial |
|---|---|---|---|---|---|
| 256 B | 217 µs | 52,0 µs | 4,2× | 6× | 269 µs (pior que A1) |
| 1 KiB | 827 µs | 90,7 µs | 9,1× | 21× | 918 µs |
| 4 KiB | 3,25 ms | 0,246 ms | 13,2× | 83× | 3,49 ms |
| 16 KiB | 12,9 ms | 0,865 ms | 14,9× | 330× | 13,8 ms |
| 32 KiB | 25,8 ms | 1,69 ms | 15,3× | 660× | 27,5 ms |
| 64 KiB | 51,7 ms | 3,34 ms | 15,4× | 1320× | 55,0 ms |

Leitura:
- **Tempo de CPU:** o 68000 gasta 39,1 µs para disparar qualquer comando, independentemente do tamanho, e fica livre
  enquanto o DMA executa. É o principal ganho. Para 64 KiB, isso libera ~51,6 ms de CPU, ou seja, ~3 quadros de
  60 Hz do Mega Drive.
- **Tempo até a VRAM ficar pronta:** até 15,4× mais rápido, mas só com os dados já na SDRAM.
- **Dados usados uma vez só:** o DMA é **mais lento** que A1 (carga + cópia). Para esse caso, o método A continua
  sendo o certo.
- **FILL/PATTERN de 64 KiB:** 0,69 ms (comando + execução). O método A1 mede uma **cópia**; um preenchimento feito
  pela CPU (`MOVE.W Dn,(A1)`, sem ler a fonte) seria um pouco mais rápido que A1 e **não foi medido**. Portanto
  não publicamos um fator de ganho para FILL.

## Condições

| Condição | Como foi criada (`scripts/gen_dma_scenes.py`, `scene_bench`) | Efeito medido |
|---|---|---|
| repouso | logo após o reset: tela ainda não configurada, sem vozes PCM | COPY 5,04 ciclos/word |
| render | `heavy_display`: planos A/B com scroll por linha e coluna + 128 sprites grandes (limite por linha), renderizador ocupado durante os comandos | **igual ao repouso**: o renderizador usa a outra porta da VRAM |
| pcm | a mesma tela pesada + 8 vozes PCM em loop lendo a SDRAM em pitch 1,9 | COPY 5,27–5,44 ciclos/word (−4 a −7 %); APU no prazo (pior 323 de 1041 ciclos) |

## Co-simulação fx68k: execução do DMA

Na co-simulação com o 68000, a memória de samples é um modelo comportamental com latência fixa de 6 ciclos, sem o
controlador SDRAM. Isso dá 6,5 ciclos/word (15,4 MB/s). Esse número **não** representa a placa: serve para provar,
com o 68000 real, que o protocolo somente-escrita funciona. Em todos os 6 tamanhos, o DMA terminou antes do fim da
espera fixa (marcador B8), e as 60.032 words do DMA conferem com o modelo de referência.

## Próximos passos (não implementados, não medidos)

O COPY está limitado pelo controlador SDRAM de página fechada (ACT + tRCD + READ + CL + captura + PRE por par de
words). Rajadas (BL 4/8) ou página aberta poderiam aproximar a leitura de 1 word/ciclo. Isso é uma **hipótese** para
a próxima fase, não um resultado.
