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
