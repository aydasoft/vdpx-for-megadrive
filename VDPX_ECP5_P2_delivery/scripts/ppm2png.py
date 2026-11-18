#!/usr/bin/env python3
"""Converte out/*.ppm em PNG (requer Pillow)."""
import glob
import sys
from PIL import Image

d = sys.argv[1] if len(sys.argv) > 1 else "out"
for p in sorted(glob.glob(f"{d}/*.ppm")):
    Image.open(p).save(p[:-4] + ".png")
    print(p[:-4] + ".png")
