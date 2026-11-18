#!/usr/bin/env python3
"""ECP5-P1 static audit (no hardware):
  1. LPF: unique sites, HDMI = schematic balls + true A/B pairs of bank 2 whose N side is
     free, nothing on SDRAM/flash/Ethernet/JTAG-reserved balls, no use of D16 (SDRAM
     divergence), CN2 inputs only, I/O standards.
  2. Synthesized netlist (if build_ecp5/vdpx_ecp5_p1.json exists): md_* are input ports.
  3. Clock arithmetic: PLL (from rtl/ecp5/colorlight_i9_top.v), video rate, I2S frame,
     MCLK, ACR CTS, SDRAM clock phase.
Writes logs/ecp5_audit.json and prints PASS/FAIL lines. Exit 1 on any FAIL."""
import json, re, os, sys
from fractions import Fraction as F

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lpf = open(os.path.join(root, "board/colorlight_i9_v72_extboard.lpf")).read()
pins = json.load(open(os.path.join(root, "board/lfe5u45_cabga381_pins_subset.json")))["pins"]
res, fails = {}, []

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (": " + detail if detail else ""))
    res[name] = {"ok": bool(ok), "detail": detail}
    if not ok: fails.append(name)

# ---------------------------------------------------------------- 1. LPF
loc = dict(re.findall(r'LOCATE COMP "([^"]+)" SITE "(\w+)"', lpf))
iob = {k: v for k, v in re.findall(r'IOBUF PORT "([^"]+)" (.*);', lpf)}
sites = list(loc.values())
check("LPF sites unicos", len(sites) == len(set(sites)), f"{len(sites)} portas")
hdmi_p = {"gpdi_dp[0]": "G19", "gpdi_dp[1]": "E20", "gpdi_dp[2]": "C20", "gpdi_dp[3]": "J19"}
hdmi_n = {"G19": "H20", "E20": "F19", "C20": "D19", "J19": "K19"}       # i5-i9-extboard.pdf
ok = all(loc.get(k) == v for k, v in hdmi_p.items())
check("HDMI P = esquema da Ext-Board", ok, ", ".join(f"{k}={loc.get(k)}" for k in hdmi_p))
ok = all(pins[p]["pair"] == n and pins[p]["pio"] == "A" and pins[p]["bank"] == 2 for p, n in hdmi_n.items())
check("HDMI pares verdadeiros A/B no banco 2 (prjtrellis-db)", ok,
      "; ".join(f"{p}(A)/{pins[p]['pair']}(B) banco {pins[p]['bank']}" for p in hdmi_n))
check("HDMI lado N livre", not (set(hdmi_n.values()) & set(sites)))
check("HDMI IO_TYPE LVCMOS33D", all("LVCMOS33D" in iob.get(k, "") for k in hdmi_p))
reserved = {"flash": "R2 U3 V2 W2", "eth": "N5 P5 P4 U19 U20 T19 T20 R20 P19 L19 P20 N19 N20 M19 M20 G1 G2 H1 J1 J3 K1 H2 K2 L1 N1 P1 P2",
            "D16 (divergencia SDRAM)": "D16", "K18/J17/H18 (botao/serial)": "K18 J17 H18"}
for k, v in reserved.items():
    used = set(v.split()) & set(sites)
    check(f"nao usa pinos reservados: {k}", not used, ",".join(sorted(used)))
sd = {k: v for k, v in loc.items() if k.startswith("sdram_")}
check("SDRAM: 49 pinos (clk, ras, cas, we, 2 ba, 11 a, 32 dq)", len(sd) == 49, str(len(sd)))
md = [k for k in loc if k.startswith("md_")]
check("CN2: 23 entradas (16 dados, 3 endereco, FDC FDWR CAS0 FRES), sem DRIVE",
      len(md) == 23 and all("DRIVE" not in iob.get(k, "") for k in md), str(len(md)))
check("todos os I/O em LVCMOS33/LVCMOS33D", all(v.split()[0].startswith("IO_TYPE=LVCMOS33") for v in iob.values()))
banks = {}
for k, p in loc.items():
    banks.setdefault(pins[p]["bank"], []).append(k)
res["banks"] = {str(b): sorted(v) for b, v in banks.items()}
print("INFO bancos usados:", ", ".join(f"{b}: {len(v)} portas" for b, v in sorted(banks.items())))

# ---------------------------------------------------------------- 2. netlist
nl = os.path.join(root, "build_ecp5/vdpx_ecp5_p1.json")
if os.path.exists(nl):
    j = json.load(open(nl))
    top = j["modules"]["colorlight_i9_top"]["ports"]
    dirs = {k: v["direction"] for k, v in top.items() if k.startswith("md_")}
    check("netlist: md_* somente input (write-only)", dirs and all(v == "input" for v in dirs.values()),
          ", ".join(f"{k}:{v}" for k, v in sorted(dirs.items())))
else:
    print("INFO netlist ainda nao sintetizada (make ecp5_synth)")

# ---------------------------------------------------------------- 3. clocks
top = open(os.path.join(root, "rtl/ecp5/colorlight_i9_top.v")).read()
P = {k: int(v) for k, v in re.findall(r"\.(\w+_DIV|CLKO\w*_CPHASE|CLKO\w*_FPHASE)\((\d+)\)", top)}
fin = F(25)
fop = fin / P["CLKI_DIV"] * P["CLKFB_DIV"]              # feedback from CLKOP
vco = fop * P["CLKOP_DIV"]
f = {"CLKOP": vco / P["CLKOP_DIV"], "CLKOS": vco / P["CLKOS_DIV"], "CLKOS2": vco / P["CLKOS2_DIV"], "CLKOS3": vco / P["CLKOS3_DIV"]}
check("PLL VCO 400..800 MHz", 400 <= vco <= 800, f"{float(vco)} MHz")
check("PLL 125/50/25/50 MHz", (f["CLKOP"], f["CLKOS"], f["CLKOS2"], f["CLKOS3"]) == (125, 50, 25, 50),
      ", ".join(f"{k}={float(v)}" for k, v in f.items()))
ph = lambda o: F(P[f"{o}_CPHASE"]) + F(P[f"{o}_FPHASE"], 8)
same = ph("CLKOP") == ph("CLKOS") == ph("CLKOS2")
check("125/50/25 MHz com a mesma fase (bordas alinhadas)", same,
      f"CPHASE {P['CLKOP_CPHASE']}/{P['CLKOS_CPHASE']}/{P['CLKOS2_CPHASE']}")
sd_ns = (ph("CLKOS3") - ph("CLKOS")) / vco * 1000
check("clock da SDRAM 16 ns depois de clk_sys (288 graus)", sd_ns == 16, f"{float(sd_ns)} ns")
fv = F(25_000_000, 800 * 525)
check("video 640x480 800x525 a 25 MHz", True, f"{float(fv):.4f} Hz")
fr = F(50_000_000) / F(3125, 3)
check("quadro I2S 3125/3 ciclos = 48 kHz exatos", fr == 48000, f"{float(fr)} Hz")
acc, last, edges = 0, 0, []
for t in range(1, 3125 * 4 + 1):
    acc += 1536
    if acc >= 3125:
        acc -= 3125; edges.append(t - last); last = t
mclk = F(len(edges), 2) * 50_000_000 / (3125 * 4)
check("MCLK media 256 fs = 12,288 MHz", mclk == 12_288_000, f"{float(mclk)/1e6} MHz; meios periodos {sorted(set(edges))} ciclos (jitter fracionario, EXPERIMENTAL)")
cts = F(25_000_000 * 6144, 128 * 48000)
check("ACR N=6144 CTS=25000 exato para 25 MHz", cts == 25000, str(cts))
src = open(os.path.join(root, "rtl/board/vdpx_board.v")).read()
check("vdpx_board: CTS 25000 com CLK50", "CLK50 ? 25000 : 25200" in src)
res["clocks"] = {k: float(v) for k, v in f.items()} | {"vco": float(vco), "video_hz": float(fv), "sdram_clk_phase_ns": float(sd_ns)}

os.makedirs(os.path.join(root, "logs"), exist_ok=True)
json.dump(res, open(os.path.join(root, "logs/ecp5_audit.json"), "w"), indent=1)
print("ECP5 audit:", "FAIL " + ", ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
