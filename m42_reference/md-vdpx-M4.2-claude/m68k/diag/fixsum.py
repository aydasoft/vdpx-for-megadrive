#!/usr/bin/env python3
"""Completa a ROM para múltiplo de 2 e grava o checksum do header ($18E)."""
import sys
d = bytearray(open(sys.argv[1], "rb").read())
if len(d) % 2:
    d += b"\0"
s = 0
for i in range(0x200, len(d), 2):
    s = (s + (d[i] << 8 | d[i + 1])) & 0xFFFF
d[0x18E] = s >> 8
d[0x18F] = s & 0xFF
open(sys.argv[1], "wb").write(d)
print(f"{sys.argv[1]}: {len(d)} bytes, checksum {s:04X}")
