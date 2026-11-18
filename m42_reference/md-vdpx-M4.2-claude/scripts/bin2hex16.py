#!/usr/bin/env python3
"""ROM binária (big-endian) -> hex de words para $readmemh."""
import sys
data = open(sys.argv[1], "rb").read()
if len(data) % 2:
    data += b"\0"
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 2):
        f.write(f"{data[i] << 8 | data[i + 1]:04x}\n")
