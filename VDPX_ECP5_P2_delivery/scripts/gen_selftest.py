#!/usr/bin/env python3
"""Gera rtl/board/selftest.hex: o roteiro do padrão de teste da placa (M4).

Formato (24 bits por word): [23:22] op, [18:16] porta, [15:0] dado
  0 WRITE   1 WAITVB n   2 JUMP addr   3 FILL2 n, seguido de v0 e v1
"""
import colorsys
import math
import sys

from vdpx import (Scene, rgb555, nt_entry, tile_words, sprite, MODE, BG, ABASE, BBASE, PSIZE,
                  AX, AY, BX, BY, TBASE, SMODE, HSBASE, TGT, ADDR, INC, AHI, DATA, REG_SEL,
                  REG_DATA, T_VRAM, T_CRAM, T_SAT, T_APU, T_SMEM, APU_WAVE, APU_MASTER,
                  wav_freq, pcm_pitch, vol, DMA_FILL, DMA_COPY, DMA_PATTERN)
from gen_scenes import ball, sprite_tiles

OUT = sys.argv[1] if len(sys.argv) > 1 else "../rtl/board/selftest.hex"
# P2: "--dma" adds the DMA demonstration (ECP5 build, ROM of 8192 words: selftest_dma.hex);
# without it the script is the P1 self-test (Tang build, 4096 words), unchanged.
DMA_DEMO = "--dma" in sys.argv
ROM_WORDS = 8192 if DMA_DEMO else 4096


class Script(Scene):
    def __init__(self):
        super().__init__()
        self.ops = []

    def w(self, a, d):
        self.ops.append((0 << 22) | ((a & 7) << 16) | (d & 0xFFFF))

    def waitvb(self, n=1):
        self.ops.append((1 << 22) | n)

    def jump(self, addr):
        self.ops.append((2 << 22) | addr)

    def fill2(self, n, v0, v1):
        self.ops += [(3 << 22) | n, v0 & 0xFFFF, v1 & 0xFFFF]

    def here(self):
        return len(self.ops)


def main():
    s = Script()
    s.reg(MODE, 0)
    # ---- paletas: 0 céu, 1 texto/chão, 2..15 matizes
    pal = [0] * 256
    for i in range(1, 16):
        t = (i - 1) / 14
        pal[i] = rgb555(int(20 + 200 * t), int(40 + 120 * t * t), int(140 * (1 - t) + 60))
    pal[16 + 1] = rgb555(255, 255, 255)
    pal[16 + 2] = rgb555(10, 10, 30)
    pal[16 + 4] = rgb555(90, 60, 30)
    pal[16 + 5] = rgb555(150, 100, 50)
    pal[16 + 6] = rgb555(60, 170, 60)
    for p in range(2, 16):
        for i in range(1, 16):
            r, g, b = colorsys.hsv_to_rgb((p - 2) / 14, 0.85, 0.25 + 0.75 * i / 15)
            pal[p * 16 + i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
    s.cram(0, pal)

    # ---- tiles
    tiles = [[0] * 64] + [[n] * 64 for n in range(1, 16)]
    brick = [4 if (y in (0, 4) or (y < 4 and x == 0) or (y >= 4 and x == 4)) else 5
             for y in range(8) for x in range(8)]
    T_BRICK = len(tiles); tiles.append(brick)
    T_GRASS = len(tiles); tiles.append([6 if y < 3 else 5 for y in range(8) for x in range(8)])
    T_BALL = len(tiles); tiles += sprite_tiles(ball(2, 2), 2, 2)
    # texto "VDPX OK" (fonte 5x7 embutida, sem depender de fontes do sistema)
    font = {
        "V": ["10001", "10001", "10001", "10001", "01010", "01010", "00100"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "X": ["10001", "01010", "00100", "00100", "00100", "01010", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        " ": ["00000"] * 7,
    }
    text = "VDPX OK"
    t_text = []
    for ch in text:              # cada letra = 2x2 tiles (fonte ampliada 3x)
        g = [[0] * 16 for _ in range(16)]
        for y, row in enumerate(font[ch]):
            for x, bit in enumerate(row):
                if bit == "1":
                    for dy in range(2):
                        for dx in range(2):
                            g[1 + y * 2 + dy][3 + x * 2 + dx] = 1
        for y in range(16):      # contorno
            for x in range(16):
                if g[y][x] == 0 and any(0 <= y + dy < 16 and 0 <= x + dx < 16 and g[y + dy][x + dx] == 1
                                        for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                    g[y][x] = 2
        idx = []
        for ty in range(2):
            for tx in range(2):
                tl = [g[ty * 8 + y][tx * 8 + x] for y in range(8) for x in range(8)]
                if any(tl):
                    idx.append(len(tiles)); tiles.append(tl)
                else:
                    idx.append(0)
        t_text.append(idx)
    s.vram(0, [w for t in tiles for w in tile_words(t)])

    # ---- plano B 64x32 em 0x4000: degradê
    B, A = 0x4000, 0x6000
    s.reg(TGT, T_VRAM); s.reg(INC, 1); s.reg(ADDR, B)
    for row in range(32):
        e0, e1 = nt_entry(1 + min(14, row * 15 // 28), pal=0)
        s.fill2(64, e0, e1)
    # ---- plano A 64x32 em 0x6000
    amap = {}
    for i, idx in enumerate(t_text):
        for k, t in enumerate(idx):
            if t:
                amap[(3 + k // 2, 6 + i * 2 + k % 2)] = nt_entry(t, pal=1, pri=1)
    for j, p in enumerate(range(2, 16, 2)):                # amostra de cores (7 paletas)
        for n in range(1, 16):
            amap[(8 + j * 2, 3 + n)] = nt_entry(n, pal=p)
    for col in range(64):
        amap[(23, col)] = nt_entry(T_GRASS, pal=1)
    s.reg(ADDR, A)
    zero_run = 0
    for row in range(32):
        for col in range(64):
            if row >= 24:
                e = nt_entry(T_BRICK, pal=1)
            else:
                e = amap.get((row, col))
            if e is None:
                zero_run += 1
                continue
            if zero_run:
                s.fill2(zero_run, 0, 0); zero_run = 0
            s.w(DATA, e[0]); s.w(DATA, e[1])
    if zero_run:
        s.fill2(zero_run, 0, 0)

    # ---- áudio: sample na SDRAM (testa a SDRAM), onda senoidal
    blip = []
    for n in range(512):
        v = math.sin(2 * math.pi * 330 * n / 48000) * math.exp(-n / 180) + \
            0.5 * math.sin(2 * math.pi * 990 * n / 48000) * math.exp(-n / 90)
        blip.append(max(-128, min(127, int(127 * v))) & 0xFF)
    s.smem(0x1000, [(blip[i] << 8) | blip[i + 1] for i in range(0, 512, 2)])
    wave = [max(0, min(15, int(round(8 + 7.5 * math.sin(2 * math.pi * i / 32))))) for i in range(32)]
    s.apu(APU_WAVE, [(wave[4 * i] << 12) | (wave[4 * i + 1] << 8) | (wave[4 * i + 2] << 4) | wave[4 * i + 3]
                     for i in range(8)])
    s.apu(0 * 8 + 1, [0x2000, 0, 512, 0, pcm_pitch(1.0), vol(200)])   # START = byte 0x2000 = word 0x1000
    s.apu(8 * 8 + 2, vol(70, 50))
    s.apu(8 * 8, 1)
    s.apu(APU_MASTER, vol(255))

    # ---- P2: demonstração do DMA (linhas 5 e 6 do plano A: livres no autoteste da P1 e acima do
    #      painel de diagnóstico, que ocupa as linhas de texto 19..29 da tela)
    T_ANIM = 0x60                                          # tiles 0x60 e 0x61 (VRAM 0x600..0x61F)
    if DMA_DEMO:
        anim = []                                          # 4 quadros x 2 tiles na memória de samples
        for f in range(4):
            for t in range(2):
                anim += tile_words([1 + ((x + y + 2 * f + 4 * t) // 2) % 15 if (x + y + f) % 4 else 15
                                    for y in range(8) for x in range(8)])
        s.smem(0x2000, anim)
        s.dma(DMA_FILL, dst=T_ANIM * 16, length=32, v0=0)                       # FILL: limpa os 2 tiles
        e0, e1 = nt_entry(T_ANIM, pal=3, pri=1)
        s.dma(DMA_PATTERN, dst=A + 5 * 128, length=128, v0=e0, v1=e1, vsync=True)   # PATTERN no vblank
        e0, e1 = nt_entry(T_ANIM + 1, pal=5, pri=1)
        s.dma(DMA_PATTERN, dst=A + 6 * 128, length=128, v0=e0, v1=e1)

    # ---- registradores de vídeo
    s.reg(TBASE, 0); s.reg(ABASE, A); s.reg(BBASE, B)
    s.reg(PSIZE, 1 | (1 << 4)); s.reg(BG, 1); s.reg(MODE, 1)

    # ---- laço de animação: 32 quadros, 6 bolas, scroll do céu, arpejo
    notes = [523.25, 659.25, 783.99, 1046.5]
    loop = s.here()
    nballs = 6
    for f in range(32):
        s.waitvb(1)
        s.reg(TGT, T_SAT); s.reg(ADDR, 0)
        for i in range(nballs):
            ph = 2 * math.pi * (f / 32 + i / nballs)
            x = int(150 + 120 * math.cos(ph))
            y = int(100 + 60 * math.sin(2 * ph) + (i - 3) * 6)
            for wd in sprite(x, y, 2, 2, T_BALL, pal=2 + 2 * i, pri=1):
                s.w(DATA, wd)
        s.reg(BX, (f * 2) & 0xFFFF)
        if DMA_DEMO:   # COPY no vblank (logo após o WAITVB): próximo quadro da animação, SDRAM -> VRAM
            s.dma(DMA_COPY, dst=T_ANIM * 16, length=32, src=0x2000 + (f % 4) * 32, tag=f)
        if f % 8 == 0:
            s.apu(8 * 8 + 1, wav_freq(notes[f // 8]))
        if f % 16 == 0:
            s.apu(0, 1)                                         # dispara o sample (SDRAM)
    s.jump(loop)

    n = len(s.ops)
    assert n <= ROM_WORDS, f"roteiro grande demais: {n} words"
    with open(OUT, "w") as fh:
        for v in s.ops + [0] * (ROM_WORDS - n):
            fh.write(f"{v:06x}\n")
    print(f"{OUT}: {n} de {ROM_WORDS} words")


if __name__ == "__main__":
    main()
