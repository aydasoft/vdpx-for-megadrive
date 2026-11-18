#!/usr/bin/env python3
"""Gera font_tiles.h: a fonte 5x7 do overlay como tiles 8x8 de 4 bpp do VDP do Mega Drive (cor 1)."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
from font5x7 import CHARS, glyph_rows
words = []
for ch in CHARS:
    rows = list(glyph_rows(ch))[:8]              # 8 linhas, 7 bits (glifo nos bits 6..2)
    for r in rows:
        v = 0
        for x in range(8):
            on = x < 7 and (r >> (6 - x)) & 1
            v = (v << 4) | (1 if on else 0)
        words += [v >> 16, v & 0xFFFF]
out = open(sys.argv[1], "w")
out.write("/* gerado por gen_font_tiles.py */\n")
esc = "".join(CHARS).replace("\\", "\\\\").replace('"', '\\"')
out.write(f'static const char FONT_CHARS[] = "{esc}";\n#define FONT_WORDS {len(words)}\n')
out.write("static const u16 font_tiles[FONT_WORDS] = {\n")
for i in range(0, len(words), 8):
    out.write("    " + ", ".join(f"0x{w:04X}" for w in words[i:i+8]) + ",\n")
out.write("};\n")
