#!/usr/bin/env python3
"""Gera as cenas de teste da M1 em scenes/*.scn."""
import colorsys
import os
import random
import sys

import math
from vdpx import (Scene, rgb555, nt_entry, tile_words, sprite, MODE, BG, ABASE, BBASE,
                  PSIZE, AX, AY, BX, BY, TBASE, SMODE, HSBASE, TGT, ADDR, INC, DATA,
                  REG_SEL, REG_DATA, ID, T_VRAM, T_CRAM, T_VSRAM, T_SAT,
                  SM_A_HLINE, SM_B_HLINE, SM_A_VCOL, SM_B_VCOL)


def sprite_tiles(pix, w, h):
    """pix[y][x] (h*8 x w*8 nibbles) -> lista de tiles em ordem de coluna."""
    out = []
    for c in range(w):
        for r in range(h):
            out.append([pix[r * 8 + y][c * 8 + x] for y in range(8) for x in range(8)])
    return out


def ball(w, h, shade_base=1):
    """Esfera sombreada com nibbles 1..15 (0 = transparente)."""
    W, H = w * 8, h * 8
    cx, cy = (W - 1) / 2, (H - 1) / 2
    rx, ry = W / 2 - 0.5, H / 2 - 0.5
    pix = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            dx, dy = (x - cx) / rx, (y - cy) / ry
            d = dx * dx + dy * dy
            if d <= 1.0:
                l = 1 - math.hypot(dx + 0.35, dy + 0.35) / 1.6
                pix[y][x] = max(1, min(15, int(2 + 13 * l)))
    return pix


def arrow_sprite(w, h):
    W, H = w * 8, h * 8
    pix = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if abs(y - H / 2 + 0.5) < H / 6 and x < W * 0.6:
                pix[y][x] = 9
            if x >= W * 0.5 and abs(y - H / 2 + 0.5) <= (W - 1 - x) * (H / W):
                pix[y][x] = 12
            if y < 2:
                pix[y][x] = 4          # faixa no topo para mostrar vflip
    return pix



# ----------------------------------------------------------------- demo
def scene_demo():
    from PIL import Image, ImageDraw, ImageFont

    s = Scene()
    s.comment("demo: céu em degradê (plano B), texto + amostra de 210 cores + chão (plano A)")

    # ---- palettes
    pals = [[0] * 16 for _ in range(16)]
    for i in range(1, 16):                      # p0: pôr do sol
        t = (i - 1) / 14
        r = int(30 + 225 * t); g = int(20 + 120 * t * t); b = int(120 * (1 - t) + 40)
        pals[0][i] = rgb555(r, g, b)
    pals[1][1] = rgb555(255, 255, 255)           # p1: texto
    pals[1][2] = rgb555(20, 20, 40)
    pals[1][3] = rgb555(255, 210, 60)
    pals[1][4] = rgb555(90, 60, 30)              # chão
    pals[1][5] = rgb555(150, 100, 50)
    pals[1][6] = rgb555(60, 160, 60)
    for p in range(2, 16):                       # p2..p15: 14 matizes x 15 tons
        h = (p - 2) / 14
        for i in range(1, 16):
            v = 0.25 + 0.75 * (i / 15)
            r, g, b = colorsys.hsv_to_rgb(h, 0.85, v)
            pals[p][i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
    s.cram(0, [w for p in pals for w in p])

    # ---- tiles
    tiles = [[0] * 64]                           # 0 vazio
    solid = {}
    for n in range(1, 16):                       # 1..15 sólidos
        solid[n] = len(tiles); tiles.append([n] * 64)
    # chão: tijolo
    brick = []
    for y in range(8):
        for x in range(8):
            if y in (0, 4) or (y < 4 and x == 0) or (y >= 4 and x == 4):
                brick.append(4)
            else:
                brick.append(5)
    t_brick = len(tiles); tiles.append(brick)
    grass = [6 if y < 3 or (y == 3 and x % 2) else 5 for y in range(8) for x in range(8)]
    t_grass = len(tiles); tiles.append(grass)
    # seta (para mostrar hflip/vflip)
    arrow = [0] * 64
    for y in range(8):
        for x in range(8):
            if (y == 3 or y == 4) and x < 6: arrow[y * 8 + x] = 3
            if abs(y - 3.5) <= (7 - x) and x >= 4: arrow[y * 8 + x] = 3
    t_arrow = len(tiles); tiles.append(arrow)

    # texto via PIL -> tiles (com contorno)
    def text_tiles(txt, size, cols, rows):
        img = Image.new("L", (cols * 8, rows * 8), 0)
        d = ImageDraw.Draw(img)
        font = ImageFont.load_default(size=size)
        bbox = d.textbbox((0, 0), txt, font=font)
        ox = (cols * 8 - (bbox[2] - bbox[0])) // 2 - bbox[0]
        oy = (rows * 8 - (bbox[3] - bbox[1])) // 2 - bbox[1]
        d.text((ox, oy), txt, fill=255, font=font)
        px = img.load()
        grid = [[0] * (cols * 8) for _ in range(rows * 8)]
        for y in range(rows * 8):
            for x in range(cols * 8):
                if px[x, y] > 110:
                    grid[y][x] = 1
        for y in range(rows * 8):                # contorno
            for x in range(cols * 8):
                if grid[y][x] == 0:
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            yy, xx = y + dy, x + dx
                            if 0 <= yy < rows * 8 and 0 <= xx < cols * 8 and grid[yy][xx] == 1:
                                grid[y][x] = 2
        idx = []
        for ty in range(rows):
            line = []
            for tx in range(cols):
                t = [grid[ty * 8 + y][tx * 8 + x] for y in range(8) for x in range(8)]
                if any(t):
                    line.append(len(tiles)); tiles.append(t)
                else:
                    line.append(0)
            idx.append(line)
        return idx

    title = text_tiles("MD-VDPX", 30, 22, 5)
    sub = text_tiles("M1.5 - 256 cores, 128 sprites", 11, 24, 2)

    tile_base = 0x0000
    vram_tiles = [w for t in tiles for w in tile_words(t)]
    assert len(vram_tiles) < 0x4000
    s.vram(tile_base, vram_tiles)

    # ---- plane B (64x32) céu
    B_BASE, A_BASE = 0x4000, 0x6000
    nb = []
    for row in range(32):
        n = 1 + min(14, row * 15 // 28)
        for col in range(64):
            nb += nt_entry(solid[n], pal=0)
    s.vram(B_BASE, nb)

    # ---- plane A (64x32)
    amap = [[(0, 0, 0, 0, 0)] * 64 for _ in range(32)]   # (tile, pal, pri, hf, vf)
    for ty, line in enumerate(title):
        for tx, t in enumerate(line):
            amap[1 + ty][2 + tx] = (t, 1, 1, 0, 0)
    for ty, line in enumerate(sub):
        for tx, t in enumerate(line):
            amap[6 + ty][1 + tx] = (t, 1, 1, 0, 0)
    for p in range(2, 16):                       # amostra de cores
        for n in range(1, 16):
            amap[9 + (p - 2)][2 + n] = (solid[n], p, 0, 0, 0)
    for i, (hf, vf) in enumerate([(0, 0), (1, 0), (0, 1), (1, 1)]):
        amap[10 + i * 2][22] = (t_arrow, 1, 1, hf, vf)
    for col in range(64):
        amap[24][col] = (t_grass, 1, 0, 0, 0)
        for row in range(25, 32):
            amap[row][col] = (t_brick, 1, 0, 0, 0)
    na = []
    for row in range(32):
        for col in range(64):
            t, p, pr, hf, vf = amap[row][col]
            na += nt_entry(t, pal=p, pri=pr, hflip=hf, vflip=vf)
    s.vram(A_BASE, na)

    # ---- sprites (tiles depois dos tiles de fundo)
    spr_base = len(tiles)
    big = sprite_tiles(ball(8, 8), 8, 8)            # 64x64
    med = sprite_tiles(ball(4, 4), 4, 4)            # 32x32
    sml = sprite_tiles(ball(2, 2), 2, 2)            # 16x16
    arr = sprite_tiles(arrow_sprite(4, 2), 4, 2)    # 32x16
    t_big = spr_base; t_med = t_big + 64; t_sml = t_med + 16; t_arr = t_sml + 4
    spr_words = [w for t in big + med + sml + arr for w in tile_words(t)]
    s.vram(len(tiles) * 16, spr_words)
    sat = []
    sat += sprite(236, 92, 8, 8, t_big, pal=8, pri=1)        # bola grande na frente do texto? pri=1
    sat += sprite(220, 30, 4, 4, t_med, pal=2, pri=0)        # atrás do título (texto tem pri 1)
    for i in range(10):
        sat += sprite(190 + i * 11, 170 + int(8 * math.sin(i)), 2, 2, t_sml, pal=2 + i, pri=1)
    sat += sprite(240, 60, 4, 2, t_arr, pal=6, pri=1)
    sat += sprite(280, 60, 4, 2, t_arr, pal=6, pri=1, hflip=1)
    sat += sprite(240, 76, 4, 2, t_arr, pal=6, pri=1, vflip=1)
    sat += sprite(280, 76, 4, 2, t_arr, pal=6, pri=1, hflip=1, vflip=1)
    sat += sprite(-20, 150, 4, 4, t_med, pal=12, pri=1)      # cortado na borda esquerda
    s.mem_write(T_SAT, 0, sat)

    s.reg(TBASE, tile_base)
    s.reg(ABASE, A_BASE)
    s.reg(BBASE, B_BASE)
    s.reg(PSIZE, (1 << 0) | (0 << 2) | (1 << 4) | (0 << 6))  # A 64x32, B 64x32
    s.reg(AX, 0); s.reg(AY, 0); s.reg(BX, 0); s.reg(BY, 0)
    s.reg(BG, 0x01)
    s.reg(MODE, 1)
    s.frame("demo")

    s.reg(AX, 13); s.reg(BY, 0xFFF0 & 0xFFFF)     # scroll fino de A, B para cima
    s.frame("demo_scroll")
    return s


# ----------------------------------------------------------------- efeitos de scroll
def scene_fx():
    s = Scene()
    s.comment("fx: scroll por linha (ondas no plano B) e por coluna (plano A)")
    pal = [0] * 32
    for i in range(1, 16):
        r, g, b = colorsys.hsv_to_rgb(i / 15, 0.7, 1.0)
        pal[i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
        r, g, b = colorsys.hsv_to_rgb(0.3, 0.6, 0.3 + 0.7 * i / 15)
        pal[16 + i] = rgb555(int(r * 255), int(g * 255), int(b * 255))
    s.cram(0, pal)
    tiles = [[0] * 64]
    for n in range(1, 16):           # listras verticais
        tiles.append([n if (x // 2) % 2 == 0 else (n % 15) + 1 for y in range(8) for x in range(8)])
    pillar = [8 + (x * 7) // 8 if x < 7 else 2 for y in range(8) for x in range(8)]
    t_p = len(tiles); tiles.append(pillar)
    cap = [15 if y < 2 else 0 for y in range(8) for x in range(8)]
    t_cap = len(tiles); tiles.append(cap)
    s.vram(0, [w for t in tiles for w in tile_words(t)])
    B_BASE, A_BASE, HS = 0x4000, 0x6000, 0x7C00
    nb = []
    for row in range(32):
        for col in range(64):
            nb += nt_entry(1 + (col + row) % 15, pal=0)
    s.vram(B_BASE, nb)
    na = []
    for row in range(32):
        for col in range(64):
            if row >= 18:
                na += nt_entry(t_p, pal=1)
            elif row == 17:
                na += nt_entry(t_cap, pal=1, pri=1)
            else:
                na += nt_entry(0)
    s.vram(A_BASE, na)
    hs = []
    for y in range(224):
        hs += [0, int(24 * math.sin(y / 12.0)) & 0xFFFF]      # A: 0 ; B: onda
    s.vram(HS, hs)
    s.mem_write(T_VSRAM, 0, [w for c in range(32)
                             for w in (int(20 * math.sin(c / 2.5)) & 0xFFFF, 0)])
    s.reg(TBASE, 0); s.reg(ABASE, A_BASE); s.reg(BBASE, B_BASE)
    s.reg(PSIZE, 1 | (1 << 4)); s.reg(HSBASE, HS)
    s.reg(SMODE, SM_B_HLINE | SM_A_VCOL)
    s.reg(BG, 0); s.reg(MODE, 1)
    s.frame("fx")
    s.reg(AX, 5)                      # scroll fino + vscroll por coluna
    s.reg(SMODE, SM_B_HLINE | SM_A_VCOL | SM_A_HLINE)
    s.frame("fx_linha_A")
    return s


# ----------------------------------------------------------------- limites de sprites
def scene_sprite_limits():
    s = Scene()
    s.comment("limites: 32 sprites/linha e 64 colunas de tile/linha")
    s.cram(0, [rgb555(40, 40, 60)] + [rgb555(17 * i, 255 - 17 * i, 128) for i in range(1, 16)])
    pix = [[1 + (x + y) % 15 for x in range(8)] for y in range(8)]
    s.vram(0, [0] * 16 + tile_words([pix[y][x] for y in range(8) for x in range(8)]))
    s.reg(ABASE, 0x4000); s.reg(BBASE, 0x4000); s.reg(TBASE, 0); s.reg(MODE, 1)
    sat = []
    for i in range(40):               # 40 sprites 1x1 na mesma linha -> corta em 32
        sat += sprite(i * 8, 20, 1, 1, 1)
    for i in range(20):               # 20 sprites 4x1 -> 64 colunas = 16 sprites
        sat += sprite(i * 16, 60, 4, 1, 1)
    for i in range(68):               # resto: desligados
        sat += sprite(0, 0, 1, 1, 1, enable=0)
    s.mem_write(T_SAT, 0, sat)
    s.frame("limites")
    return s


# ----------------------------------------------------------------- random
def scene_random(seed):
    rnd = random.Random(seed)
    s = Scene()
    s.comment(f"aleatória seed={seed}: VRAM/CRAM/registradores aleatórios")
    s.cram(0, [rnd.getrandbits(15) for _ in range(256)])
    s.vram(0, [rnd.getrandbits(16) for _ in range(32768)])
    s.mem_write(T_VSRAM, 0, [rnd.getrandbits(16) for _ in range(64)])
    sat = []
    for i in range(128):
        sat += sprite(rnd.randrange(-80, 360), rnd.randrange(-80, 260), rnd.randint(1, 8),
                      rnd.randint(1, 8), rnd.getrandbits(14), pal=rnd.getrandbits(4),
                      pri=rnd.getrandbits(1), hflip=rnd.getrandbits(1), vflip=rnd.getrandbits(1),
                      enable=1 if rnd.random() < (0.15 + 0.3 * (seed % 3)) else 0)
    s.mem_write(T_SAT, 0, sat)
    for k in range(3):
        s.reg(SMODE, rnd.getrandbits(4))
        s.reg(HSBASE, rnd.getrandbits(16))
        s.reg(TBASE, rnd.getrandbits(16))
        s.reg(ABASE, rnd.getrandbits(16))
        s.reg(BBASE, rnd.getrandbits(16))
        s.reg(PSIZE, rnd.getrandbits(8))
        for r in (AX, AY, BX, BY):
            s.reg(r, rnd.getrandbits(16))
        s.reg(BG, rnd.getrandbits(8))
        s.reg(MODE, 1)
        s.frame(f"rand{seed}_{k}")
    s.reg(MODE, 0)
    s.frame(f"rand{seed}_off")
    return s


# ----------------------------------------------------------------- readback
def scene_readback():
    rnd = random.Random(99)
    s = Scene()
    s.comment("leitura: VRAM/CRAM com incrementos variados, registradores, ID")
    s.r(ID)
    data = [rnd.getrandbits(16) for _ in range(512)]
    s.mem_write(T_VRAM, 0x1234, data, inc=1)
    s.mem_write(T_VRAM, 0x7F00, data[:300], inc=3)      # passa do fim da VRAM
    s.mem_write(T_CRAM, 0xF0, [rnd.getrandbits(16) for _ in range(40)], inc=1)  # dá a volta
    s.mem_write(T_VSRAM, 60, [rnd.getrandbits(16) for _ in range(8)])   # dá a volta (64)
    s.mem_write(T_SAT, 500, [rnd.getrandbits(16) for _ in range(20)])   # dá a volta (512)
    s.wait(12000)   # leituras durante a renderização ativa (testa a arbitragem da VRAM)
    for tgt, addr, inc, n in [(T_VRAM, 0x1234, 1, 512), (T_VRAM, 0x7F00, 3, 300),
                              (T_CRAM, 0xF0, 1, 40), (T_VRAM, 0x1234, 0x101, 50),
                              (T_VSRAM, 60, 1, 8), (T_SAT, 500, 1, 20)]:
        s.reg(TGT, tgt); s.reg(INC, inc); s.reg(ADDR, addr)
        for _ in range(n):
            s.r(DATA)
    for i in range(16):
        s.reg(i, 0x1111 * (i + 1) if i not in (0, 10, 12, 13, 14) else 0)
        s.w(REG_SEL, i); s.r(REG_DATA); s.r(REG_SEL)
    return s


if __name__ == "__main__":
    OUT = sys.argv[1] if len(sys.argv) > 1 else "scenes"
    os.makedirs(OUT, exist_ok=True)
    scene_demo().save(f"{OUT}/demo.scn")
    scene_readback().save(f"{OUT}/readback.scn")
    scene_fx().save(f"{OUT}/fx.scn")
    scene_sprite_limits().save(f"{OUT}/limites.scn")
    for seed in range(6):
        scene_random(seed).save(f"{OUT}/rand{seed}.scn")
    print("cenas geradas em", OUT)
