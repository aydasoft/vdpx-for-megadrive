#!/usr/bin/env python3
"""ECP5-P2: tabelas de benchmark a partir dos logs da simulação (nada é estimado aqui).
Uso: p2_bench_report.py <log do make m2bench> <log do make test50> <log do make ecp5_boardsim> > tabela.md
  - m2bench (fx68k + adaptador somente escrita, 50 MHz): tempo de CPU do 68000 por método, carga da
    memória de samples, envio do comando de DMA e tempo de execução do DMA com a memória de samples
    comportamental (6 ciclos de latência) da co-simulação;
  - test50 (cena dma_bench, controlador SDRAM RMW real, 50 MHz): ciclos de execução do DMA por operação,
    tamanho e condição (repouso, renderização pesada, PCM de 8 canais);
  - ecp5_boardsim: COPY do autoteste na placa ECP5 (clock da SDRAM a 288 graus, captura R3).
"""
import re
import sys

CLK = 50.0e6
sizes = [128, 512, 2048, 8192, 16384, 32768]

m2 = open(sys.argv[1]).read()
marks = {}
for k, i, c, w in re.findall(r"BENCH marca (\w) teste (\d+) ciclo (\d+) escritas (\d+)", m2):
    marks[(int(k, 16), int(i))] = (int(c), int(w))
dma_m2 = [(int(w), int(c)) for w, c in re.findall(r"BENCH dma_fim palavras=(\d+) ciclos_execucao=(\d+)", m2)]

t50 = open(sys.argv[2]).read()
cond = None
rows = {}
for line in t50.splitlines():
    m = re.match(r"bench (\w+) op=(\d) words=(\d+)", line)
    if m:
        cond = (m.group(1), int(m.group(2)), int(m.group(3)))
        continue
    m = re.match(r"DMA_LOG op=(\d) len=(\d+) words=(\d+) cycles=(\d+) stalls=(\d+)", line)
    if m and cond:
        rows[cond] = (int(m.group(3)), int(m.group(4)), int(m.group(5)))
        cond = None
board = open(sys.argv[3]).read() if len(sys.argv) > 3 else ""
mb = re.search(r"painel DMA: DONE COPY palavras (\d+) ciclos (\d+)", board)

def us(c): return c / CLK * 1e6
def mbps(words, cyc): return words * 2 / (cyc / CLK) / 1e6 if cyc else 0.0

print("### Método A (68000 copia pela CN2) e custo de CPU do método B — fx68k a 7,67 MHz, ciclos de 50 MHz\n")
print("| Tamanho | A1 desenrolado | A1 MB/s | ciclos/palavra | A2 laço DBRA | A2 MB/s | Carga da memória de samples (A1) | Envio do comando DMA (CPU) | Escritas CN2 do comando |")
print("|---|---|---|---|---|---|---|---|---|")
for i, n in enumerate(sizes):
    try:
        a1 = marks[(1, i)][0] - marks[(0, i)][0]
        a2 = marks[(3, i)][0] - marks[(2, i)][0]
        up = marks[(5, i)][0] - marks[(4, i)][0]
        cm = marks[(7, i)][0] - marks[(6, i)][0]
        wc = marks[(7, i)][1] - marks[(6, i)][1]
    except KeyError:
        continue
    print(f"| {n*2} B | {a1} ({us(a1):.0f} µs) | {mbps(n, a1):.2f} | {a1/n:.1f} | {a2} ({us(a2):.0f} µs) | {mbps(n, a2):.2f} | "
          f"{up} ({us(up):.0f} µs) | {cm} ({us(cm):.1f} µs) | {wc} |")

print("\n### Execução do DMA COPY na co-simulação fx68k (memória de samples comportamental, latência 6)\n")
print("| Palavras | Ciclos | ciclos/palavra | MB/s |")
print("|---|---|---|---|")
for w, c in dma_m2:
    print(f"| {w} | {c} | {c/w:.2f} | {mbps(w, c):.2f} |")

print("\n### Método B: execução do DMA com o controlador SDRAM RMW real (cena dma_bench, 50 MHz, captura R2)\n")
print("| Condição | Operação | Palavras | Ciclos | ciclos/palavra | MB/s | Ciclos de espera (stalls) |")
print("|---|---|---|---|---|---|---|")
opn = {1: "FILL", 2: "COPY", 3: "PATTERN"}
for c in ("repouso", "render", "pcm"):
    for op in (1, 3, 2):
        for n in sizes:
            if (c, op, n) in rows:
                w, cy, st = rows[(c, op, n)]
                print(f"| {c} | {opn[op]} | {w} | {cy} | {cy/w:.3f} | {mbps(w, cy):.2f} | {st} |")
if mb:
    w, c = int(mb.group(1)), int(mb.group(2))
    print(f"\nPlaca ECP5 (simulação da placa inteira, SDRAM com atraso de placa e captura R3): COPY de {w} palavras do "
          f"autoteste em {c} ciclos = {c/w:.2f} ciclos/palavra = {mbps(w, c):.2f} MB/s.")
