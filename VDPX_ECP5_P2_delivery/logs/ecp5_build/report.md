# Relatório do build ECP5-P2 (gerado por scripts/ecp5_report.py)

Dispositivo: LFE5U-45F-6BG381C. Sementes: 1, 2, 3. Bitstream da semente 1.

| Semente | exit | clk_sys (50) | clk_pix (25) | clk_x5 (125) | avisos P&R | timing |
|---|---|---|---|---|---|---|
| 1 | 0 | 68.18 MHz (+36.4%, slack 5.334 ns) | 73.14 MHz (+192.6%, slack 26.328 ns) | 257.2 MHz (+105.8%, slack 4.112 ns) | 0 | PASS |
| 2 | 0 | 65.47 MHz (+30.9%, slack 4.726 ns) | 71.63 MHz (+186.5%, slack 26.039 ns) | 284.98 MHz (+128.0%, slack 4.491 ns) | 0 | PASS |
| 3 | 0 | 65.33 MHz (+30.7%, slack 4.693 ns) | 73.83 MHz (+195.3%, slack 26.456 ns) | 282.49 MHz (+126.0%, slack 4.46 ns) | 0 | PASS |

Células (síntese): LUT4 4619, CCU2C 1129, TRELLIS_FF 3715, TRELLIS_DPR16X4 183, DP16KD 48, MULT18X18D 4, EHXPLLL 1, ODDRX1F 5

Bitstream: `artifacts/vdpx_ecp5_p2.bit` sha256 `7eda4c78c020d2e0e899b6754d0fc38a6890ef75b28358f144e5764f6f81f986` (1143589 bytes)
Config (semente 1): sha256 `c7403e4b2aa039834879d7b705bff2c363d6d14ecc8ab60ddc45c6e240901479`; netlist JSON sha256 `b35f4772cb3e58023308839316bcd8ddd72f369ec3718c1eb6e79173ca70734f`

RESULTADO: PASS
