#!/usr/bin/env python3
"""ECP5-P2: cenas de teste do DMA (executadas por sim/tb_main.cpp junto com as 17 da P1).

VRAM usada pelas cenas (words):
  0x0000-0x3FFF tiles (até 1024 tiles)    0x4000 nametable A (64x32)   0x5000 nametable B (64x32)
  0x6000 tabela de hscroll                0x7000-0x7FFF área de trabalho do DMA (fora da tela,
                                          exceto quando a cena aponta um plano para ela)
"""
import math
import os
import random
import sys

from vdpx import (Scene, rgb555, nt_entry, tile_words, sprite, MODE, BG, ABASE, BBASE, PSIZE, AX, AY,
                  BX, BY, TBASE, SMODE, HSBASE, TGT, ADDR, INC, AHI, DATA, T_VRAM, T_VSRAM, T_SAT,
                  T_APU, T_SMEM, DMA_FILL, DMA_COPY, DMA_PATTERN, DMA_CANCEL, APU_WAVE, APU_MASTER,
                  pcm_pitch, wav_freq, vol)

OUT = sys.argv[1] if len(sys.argv) > 1 else "../scenes"
A, B, HS, WORK = 0x4000, 0x5000, 0x6000, 0x7000


def palettes(s, rnd=None):
    pal = [0] * 256
    for p in range(16):
        for i in range(1, 16):
            h = (p * 37 + i * 11) % 360 / 360
            r = int(127 + 127 * math.cos(2 * math.pi * h))
            g = int(127 + 127 * math.cos(2 * math.pi * (h + 1 / 3)))
            b = int(127 + 127 * math.cos(2 * math.pi * (h + 2 / 3)))
            pal[p * 16 + i] = rgb555(r, g, b)
    pal[0] = rgb555(10, 10, 40)
    s.cram(0, pal)


def art_tiles(n, seed):
    """n tiles 8x8 'desenhados' (anéis e listras), lista de words."""
    rnd = random.Random(seed)
    out = []
    for t in range(n):
        cx, cy, k = rnd.uniform(0, 8), rnd.uniform(0, 8), rnd.randint(1, 3)
        px = [1 + int((math.hypot(x - cx, y - cy) * k + t) % 15) for y in range(8) for x in range(8)]
        out += tile_words(px)
    return out


def show_planes(s, a_base=A, b_base=B):
    s.reg(TBASE, 0); s.reg(ABASE, a_base); s.reg(BBASE, b_base)
    s.reg(PSIZE, 1 | (1 << 4)); s.reg(SMODE, 0); s.reg(BG, 0)
    for r in (AX, AY, BX, BY):
        s.reg(r, 0)
    s.reg(MODE, 1)


# ------------------------------------------------------------------------------- basic
def scene_basic():
    s = Scene()
    s.comment("dma_basic: FILL de tiles sólidos, COPY de tiles da memória de samples, PATTERN de nametable")
    palettes(s)
    # 15 tiles sólidos (tile n = cor n) por FILL; dmawait a cada 4 para não encher a fila
    for n in range(1, 16):
        s.dma(DMA_FILL, dst=n * 16, length=16, v0=0x1111 * n, tag=n)
        if n % 4 == 0:
            s.dmawait()
    # 64 tiles desenhados -> memória de samples -> COPY para os tiles 0x40..0x7F (fonte par)
    art = art_tiles(64, 1)
    s.smem(0x2000, art)
    s.dma(DMA_COPY, dst=0x40 * 16, length=len(art), src=0x2000, tag=0x20)
    # mais uma cópia com fonte ímpar e comprimento ímpar (palavra única + pares)
    s.smem(0x3001, art[:333])
    s.dma(DMA_COPY, dst=0x80 * 16, length=333, src=0x3001, tag=0x21)
    s.dmawait()
    # plano A: cada linha = PATTERN (word0 = tile, word1 = paleta) -> 64 entradas iguais
    for row in range(32):
        tile = 0x40 + (row * 7) % 64
        s.dma(DMA_PATTERN, dst=A + row * 128, length=128, v0=tile, v1=(row % 16) | (16 if row % 3 == 0 else 0), tag=row)
        if row % 4 == 3:
            s.dmawait()
    # plano B: nametable montada na memória de samples e copiada (entradas com flips)
    rnd = random.Random(7)
    nt = []
    for i in range(64 * 32):
        e0, e1 = nt_entry(1 + rnd.randrange(15) if rnd.random() < 0.7 else 0x80 + rnd.randrange(42),
                          pal=rnd.randrange(16), hflip=rnd.getrandbits(1), vflip=rnd.getrandbits(1))
        nt += [e0, e1]
    s.smem(0x10000, nt)
    s.dma(DMA_COPY, dst=B, length=len(nt), src=0x10000, tag=0x30)
    s.dmawait()
    show_planes(s)
    s.frame("dma_basic_0")
    s.reg(AX, 13); s.reg(BY, 5)
    s.frame("dma_basic_1")
    s.dmastat()
    return s


# ------------------------------------------------------------------------------- DMA x renderer
def heavy_display(s, rnd):
    """planos com scroll por linha e por coluna + 128 sprites grandes (limites por linha)."""
    palettes(s)
    s.vram(0, art_tiles(256, 3))
    s.vram(A, [w for _ in range(64 * 32) for w in nt_entry(rnd.randrange(256), pal=rnd.randrange(16),
                                                            pri=rnd.getrandbits(1), hflip=rnd.getrandbits(1))])
    s.vram(B, [w for _ in range(64 * 32) for w in nt_entry(rnd.randrange(256), pal=rnd.randrange(16),
                                                            vflip=rnd.getrandbits(1))])
    s.vram(HS, [rnd.getrandbits(9) for _ in range(2 * 224)])
    s.mem_write(T_VSRAM, 0, [rnd.getrandbits(8) for _ in range(64)])
    sat = []
    for i in range(128):
        w, h = rnd.randint(2, 8), rnd.randint(2, 8)
        sat += sprite(rnd.randrange(-40, 330), rnd.randrange(-40, 230), w, h, rnd.randrange(256 - 64),
                      pal=rnd.randrange(16), pri=rnd.getrandbits(1), hflip=rnd.getrandbits(1),
                      vflip=rnd.getrandbits(1))
    s.mem_write(T_SAT, 0, sat)
    s.reg(TBASE, 0); s.reg(ABASE, A); s.reg(BBASE, B); s.reg(PSIZE, 1 | (1 << 4))
    s.reg(HSBASE, HS); s.reg(SMODE, 15); s.reg(MODE, 1)


def scene_render():
    rnd = random.Random(11)
    s = Scene()
    s.comment("dma_render: renderização no pior caso (128 sprites, limites, scroll por linha/coluna) "
              "com o DMA escrevendo na área de trabalho durante os quadros capturados")
    heavy_display(s, rnd)
    src = [rnd.getrandbits(16) for _ in range(4096)]
    s.smem(0x20000, src)
    for k in range(4):
        # o quadro k começa a ser capturado; no meio da área ativa (~linha 100) entram 5 comandos
        # longos (1 em execução + 4 na fila) que rodam junto com a renderização das linhas seguintes
        s.lines.append("framebegin")
        s.wait(160000 + 30000 * k)
        s.dma(DMA_COPY, dst=WORK, length=4096, src=0x20000, tag=k)
        s.dma(DMA_FILL, dst=WORK, length=4096, v0=0x1234 + k, tag=k)
        s.dma(DMA_PATTERN, dst=WORK + 1, length=4095, v0=0xA5A5, v1=k, tag=k)
        s.dma(DMA_COPY, dst=WORK + 3, length=4093, src=0x20001, tag=k)
        s.dma(DMA_COPY, dst=WORK, length=4096, src=0x20000 + k, tag=k)
        s.lines.append(f"frameend dma_render_{k}")
    s.dmawait()
    # mostra o conteúdo escrito pelo DMA: plano B aponta para a área de trabalho
    s.reg(BBASE, WORK)
    s.frame("dma_render_work")
    s.dmastat()
    return s


# ------------------------------------------------------------------------------- DMA x APU
def scene_pcm():
    rnd = random.Random(21)
    s = Scene()
    s.comment("dma_pcm: 8 canais PCM em loop + 8 wavetable, escritas da CPU na memória de samples "
              "e cópias DMA da memória de samples em paralelo; áudio conferido bit a bit")
    palettes(s)
    s.vram(0, art_tiles(64, 5))
    # 8 samples de 4096 bytes (2048 words) em 0x00000.. e fonte do DMA em 0x40000
    for c in range(8):
        f = 200 + 90 * c
        smp = [int(110 * math.sin(2 * math.pi * f * n / 48000) + 15 * math.sin(n * 0.37 * (c + 1))) & 0xFF
               for n in range(4096)]
        s.smem(c * 2048, [(smp[i] << 8) | smp[i + 1] for i in range(0, 4096, 2)])
    s.smem(0x40000, [rnd.getrandbits(16) for _ in range(4096)])
    wave = [(8 + int(7 * math.sin(2 * math.pi * i / 32))) for i in range(32)]
    for k in range(8):
        s.apu(APU_WAVE + k * 8, [(wave[4 * i] << 12) | (wave[4 * i + 1] << 8) | (wave[4 * i + 2] << 4) | wave[4 * i + 3]
                                for i in range(8)])
    for c in range(8):
        start = c * 4096                                                  # byte address
        s.apu(c * 8 + 1, [start & 0xFFFF, start >> 16, 4096, 128, pcm_pitch(0.5 + 0.21 * c), vol(40, 30)])
    for k in range(8):
        s.apu((8 + k) * 8 + 1, [wav_freq(110 * (k + 1)), vol(12, 16)])
    s.apu(APU_MASTER, vol(255))
    for c in range(8):
        s.apu(c * 8, 3)                                                   # KEY + LOOP
    for k in range(8):
        s.apu((8 + k) * 8, 1)
    s.rec("dma_pcm")
    s.samples(300)
    for b in range(10):
        for k in range(4):
            s.dma(DMA_COPY, dst=WORK + 256 * k, length=1024 + 512 * k, src=0x40000 + 3 * k, tag=b)
        # a CPU escreve na memória de samples enquanto o DMA e a APU a usam (outra região)
        s.smem(0x50000 + 64 * b, [rnd.getrandbits(16) for _ in range(64)])
        s.samples(1500)
    s.dmawait()
    s.samples(500)
    s.stoprec()
    show_planes(s)
    s.frame("dma_pcm")
    s.dmastat()
    return s


# ------------------------------------------------------------------------------- errors, queue, cancel
def scene_errors():
    s = Scene()
    s.comment("dma_errors: comandos incompletos, op inválida, comprimento zero, destino/fonte fora da faixa, "
              "último endereço, fila cheia, cancelamento durante leitura e escrita, mudança de parâmetro após o commit")
    palettes(s)
    # logo após o reset nenhum parâmetro foi escrito: INCOMPLETE
    s.dma_cmd(DMA_COPY)
    s.dma(DMA_FILL, dst=WORK, length=8, regs=[2, 3])          # sem VALUE0
    s.dma(DMA_PATTERN, dst=WORK, length=8, v0=1, regs=[2, 3, 4])  # sem VALUE1
    s.dma(DMA_COPY, dst=WORK, length=8, regs=[2, 3])          # sem SRC
    for bad in (0, 5, 6, 7, 0x00F5):
        s.dma_cmd(bad)                                         # BAD_OP
    s.dma(DMA_FILL, dst=WORK, length=0, v0=1)                  # ZERO_LEN
    s.dma(DMA_FILL, dst=0x7FFF, length=2, v0=1)                # DST_RANGE (passa do fim)
    s.dma(DMA_FILL, dst=0x8000, length=1, v0=1)                # DST_RANGE (DST[15])
    s.dma(DMA_FILL, dst=0, length=0x8001, v0=1)                # DST_RANGE (maior que a VRAM)
    s.dma(DMA_COPY, dst=WORK, length=32, src=(1 << 20) - 16)   # SRC_RANGE (memória de 2^20 words na simulação)
    s.dma(DMA_COPY, dst=WORK, length=1, src=1 << 20)           # SRC_RANGE
    s.dma(DMA_FILL, dst=0x7FFF, length=1, v0=0xBEEF)           # último endereço: aceito
    s.dma(DMA_COPY, dst=0x7FF0, length=16, src=(1 << 20) - 16) # últimas 16 words da memória: aceito
    s.dmawait()
    # fila cheia: 1 em execução + 4 na fila; o 6º e o 7º são rejeitados
    for k in range(7):
        s.dma(DMA_FILL, dst=WORK, length=4096, v0=0x1000 + k, tag=k)
    s.dmawait()
    # cancelamento durante uma cópia (leituras da memória de samples) com comandos na fila
    s.smem(0x30000, list(range(4096)))
    s.dma(DMA_COPY, dst=WORK, length=4096, src=0x30000, tag=0x40)
    s.dma(DMA_FILL, dst=WORK, length=4096, v0=0x7777, tag=0x41)
    s.dma(DMA_PATTERN, dst=WORK, length=4096, v0=1, v1=2, tag=0x42)
    s.wait(1500)
    s.dma_cmd(DMA_CANCEL)
    s.dmawait()
    # cancelamento durante um FILL (escritas na VRAM)
    s.dma(DMA_FILL, dst=WORK, length=4096, v0=0x5555, tag=0x50)
    s.wait(700)
    s.dma_cmd(DMA_CANCEL)
    s.dmawait()
    s.dma_cmd(DMA_CANCEL)                                      # cancel ocioso: sem efeito
    # parâmetro alterado depois do commit não afeta o comando na fila
    s.dma(DMA_FILL, dst=WORK, length=4096, v0=0x1111, tag=0x60)
    s.dma(DMA_FILL, dst=WORK + 0x800, length=16, v0=0x2222, tag=0x61)
    s.reg(TGT, 6); s.reg(ADDR, 4); s.w(DATA, 0x3333)         # VALUE0 muda com o 0x61 ainda na fila
    s.dmawait()
    # resultado visível: plano B aponta para a área de trabalho
    s.vram(0, art_tiles(64, 9))
    show_planes(s, b_base=WORK)
    s.frame("dma_errors")
    s.dmastat()
    return s


# ------------------------------------------------------------------------------- CPU x DMA on the same words
def scene_cpu():
    rnd = random.Random(31)
    s = Scene()
    s.comment("dma_cpu: escritas da CPU na porta DATA dentro da região que o DMA está preenchendo/copiando; "
              "o resultado segue a ordem da porta de escrita (CPU tem prioridade)")
    palettes(s)
    s.vram(0, art_tiles(128, 13))
    src = [w for _ in range(2048) for w in nt_entry(rnd.randrange(128), pal=rnd.randrange(16))]
    s.smem(0x8000, src)
    s.dma(DMA_FILL, dst=WORK, length=4096, v0=0x0005)
    s.vram(WORK + 100, [0x0010 + i for i in range(200)])      # CPU no meio do FILL
    s.dma(DMA_COPY, dst=WORK, length=4096, src=0x8000)
    s.mem_write(T_VRAM, WORK + 3000, [0x0020 + i for i in range(300)], inc=2)
    s.dmawait()
    show_planes(s, b_base=WORK)
    s.frame("dma_cpu")
    s.dmastat()
    return s


# ------------------------------------------------------------------------------- VSYNC animation
def scene_vsync():
    s = Scene()
    s.comment("dma_vsync: animação de tiles por COPY com VSYNC (troca no vblank, antes da linha 0)")
    palettes(s)
    frames = [art_tiles(32, 100 + f) for f in range(4)]
    for f, fr in enumerate(frames):
        s.smem(0x60000 + f * 512, fr)
    s.vram(0x40 * 16, frames[0])
    s.vram(A, [w for i in range(64 * 32) for w in nt_entry(0x40 + (i % 32), pal=i % 16)])
    s.vram(B, [0, 0] * (64 * 32))
    show_planes(s)
    for f in range(1, 4):
        s.dma(DMA_COPY, dst=0x40 * 16, length=512, src=0x60000 + f * 512, vsync=True, tag=f)
        s.frame(f"dma_vsync_{f}")
    s.dmastat()
    return s


# ------------------------------------------------------------------------------- benchmark
def scene_bench():
    rnd = random.Random(41)
    s = Scene()
    s.comment("dma_bench: FILL/PATTERN/COPY de 256 B a 64 KiB em repouso, com renderização pesada e com PCM ativo "
              "(dmalog imprime ciclos por comando)")
    s.smem(0x40000, [rnd.getrandbits(16) for _ in range(32768)])
    s.lines.append("dmalog")
    sizes = [128, 512, 2048, 8192, 16384, 32768]

    def run(cond):
        for n in sizes:
            for op in (DMA_FILL, DMA_PATTERN, DMA_COPY):
                s.lines.append(f"echo bench {cond} op={op} words={n}")
                s.dma(op, dst=0, length=n, src=0x40000, v0=0x1111, v1=0x2222, tag=n >> 7)
                s.dmawait()
    run("repouso")
    heavy_display(s, rnd)
    run("render")
    # PCM: 8 canais em loop lendo a memória de samples
    for c in range(8):
        s.apu(c * 8 + 1, [(c * 4096) & 0xFFFF, (c * 4096) >> 16, 4096, 0, pcm_pitch(1.9), vol(20)])
    s.apu(APU_MASTER, vol(255))
    for c in range(8):
        s.apu(c * 8, 3)
    s.samples(10)
    run("pcm")
    s.dmastat()
    return s


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [("dma_basic", scene_basic), ("dma_render", scene_render), ("dma_pcm", scene_pcm),
                     ("dma_errors", scene_errors), ("dma_cpu", scene_cpu), ("dma_vsync", scene_vsync),
                     ("dma_bench", scene_bench)]:
        fn().save(f"{OUT}/{name}.scn")
    print("cenas de DMA geradas em", OUT)
