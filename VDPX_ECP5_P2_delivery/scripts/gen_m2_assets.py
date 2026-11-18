#!/usr/bin/env python3
"""Gera m68k/assets.h para o programa 68000 da M2 (paletas, tiles, seno)."""
import colorsys
import math
import sys

from vdpx import rgb555, tile_words
from gen_scenes import ball, sprite_tiles

out = sys.argv[1] if len(sys.argv) > 1 else "../m68k/assets.h"

# paletas: 0 = listras arco-íris, 1 = chão verde, 2..15 = bolas
pal = [0] * 256
for i in range(1, 16):
    r, g, b = colorsys.hsv_to_rgb(i / 15, 0.7, 1.0)
    pal[i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
    r, g, b = colorsys.hsv_to_rgb(0.3, 0.6, 0.3 + 0.7 * i / 15)
    pal[16 + i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
for p in range(2, 16):
    h = (p - 2) / 14
    for i in range(1, 16):
        v = 0.25 + 0.75 * (i / 15)
        r, g, b = colorsys.hsv_to_rgb(h, 0.85, v)
        pal[p * 16 + i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
pal[0] = rgb555(10, 10, 30)

tiles = [[0] * 64]
for n in range(1, 16):                       # 1..15 listras
    tiles.append([n if (x // 2) % 2 == 0 else (n % 15) + 1 for y in range(8) for x in range(8)])
T_PILLAR = len(tiles)
tiles.append([8 + (x * 7) // 8 if x < 7 else 2 for y in range(8) for x in range(8)])
T_CAP = len(tiles)
tiles.append([15 if y < 2 else 0 for y in range(8) for x in range(8)])
T_BALL2 = len(tiles); tiles += sprite_tiles(ball(2, 2), 2, 2)
T_BALL4 = len(tiles); tiles += sprite_tiles(ball(4, 4), 4, 4)
T_BALL8 = len(tiles); tiles += sprite_tiles(ball(8, 8), 8, 8)
words = [w for t in tiles for w in tile_words(t)]

sine = [int(round(24 * math.sin(2 * math.pi * i / 256))) for i in range(256)]

# áudio: bumbo (PCM 8 bits), ondas, tabela de notas (FREQ da wavetable)
kick = []
ph = 0.0
for n in range(6000):
    t = n / 48000
    ph += 2 * math.pi * (45 + 140 * math.exp(-t * 25)) / 48000
    kick.append(max(-128, min(127, int(round(127 * math.sin(ph) * math.exp(-t * 9))))) & 0xFF)
kick_words = [(kick[i] << 8) | kick[i + 1] for i in range(0, len(kick), 2)]


def wave_nib(fn):
    nib = [max(0, min(15, int(round(8 + 7.5 * fn(i / 32))))) for i in range(32)]
    return [(nib[4 * i] << 12) | (nib[4 * i + 1] << 8) | (nib[4 * i + 2] << 4) | nib[4 * i + 3] for i in range(8)]


waves = (wave_nib(lambda x: math.sin(2 * math.pi * x)) + wave_nib(lambda x: 1 if x < 0.5 else -1))
melody_hz = [523.25, 659.25, 783.99, 1046.5, 783.99, 659.25, 587.33, 493.88, 523.25, 392.0]
bass_hz = [130.81, 130.81, 98.0, 110.0, 87.31, 98.0, 130.81, 98.0, 130.81, 65.41]
melody = [int(round(f * (1 << 20) / 48000)) for f in melody_hz]
bassf = [int(round(f * (1 << 20) / 48000)) for f in bass_hz]


def arr(name, vals, typ="u16"):
    lines = []
    for i in range(0, len(vals), 12):
        if typ == "u16":
            lines.append("    " + ", ".join(f"0x{v:04X}" for v in vals[i:i + 12]) + ",")
        else:
            lines.append("    " + ", ".join(str(v) for v in vals[i:i + 12]) + ",")
    return f"static const {typ} {name}[{len(vals)}] = {{\n" + "\n".join(lines) + "\n};\n"


with open(out, "w") as f:
    f.write("/* gerado por scripts/gen_m2_assets.py -- não editar */\n")
    f.write("#ifndef ASSETS_H\n#define ASSETS_H\n#include \"vdpx.h\"\n\n")
    f.write(f"#define T_PILLAR {T_PILLAR}\n#define T_CAP {T_CAP}\n")
    f.write(f"#define T_BALL2 {T_BALL2}\n#define T_BALL4 {T_BALL4}\n#define T_BALL8 {T_BALL8}\n")
    f.write(f"#define TILE_WORDS {len(words)}\n\n")
    f.write(arr("palette", pal))
    f.write(arr("tile_data", words))
    f.write(arr("sine", sine, "s16"))
    f.write(f"#define KICK_WORDS {len(kick_words)}\n#define KICK_LEN {len(kick)}\n#define NOTES {len(melody)}\n")
    f.write(arr("kick_data", kick_words))
    f.write(arr("wave_data", waves))
    f.write(arr("melody_freq", melody))
    f.write(arr("bass_freq", bassf))
    f.write("\n#endif\n")
print(out, len(words), "words de tiles")
