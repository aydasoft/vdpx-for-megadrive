#!/usr/bin/env python3
"""Runs a negative test: succeeds only if the command FAILS (exit != 0) and printed FALHA/FAIL."""
import subprocess, sys
name, cmd = sys.argv[1], sys.argv[2:]
r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
n = sum(1 for l in r.stdout.splitlines() if "FALHA" in l)
if r.returncode != 0 and ("FAIL" in r.stdout or n):
    print(f"PASS negativo: {name} -> falhou como esperado (exit {r.returncode}, {n} falhas listadas)")
    sys.exit(0)
print(f"FAIL negativo: {name} -> passou, o teste nao detecta o defeito")
print(r.stdout[-2000:])
sys.exit(1)
