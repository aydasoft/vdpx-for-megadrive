#!/usr/bin/env python3
"""ECP5-P1 build report. Usage: ecp5_report.py <build_dir> "<seeds>" <bit_seed>
Reads synth_stat.txt, pnr_s<N>.log, report_s<N>.json, pnr_exit.txt and the bitstream from
<build_dir>; writes logs/ecp5_build/report.json and report.md. Exit 1 if any seed failed
timing, a domain is below its constraint, or the bitstream is missing."""
import json, os, re, sys, hashlib, subprocess

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bd = os.path.join(root, sys.argv[1])
seeds = sys.argv[2].split()
bit_seed = sys.argv[3]
out = os.path.join(root, "logs/ecp5_build")
os.makedirs(out, exist_ok=True)
R = {"device": "LFE5U-45F-6BG381C", "seeds": {}, "ok": True}

def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None

# ---- synthesis cells
st = open(os.path.join(bd, "synth_stat.txt")).read()
cells = {}
for m in re.finditer(r"^\s+(\d+)\s+(\S+)\s*$", st, re.M):
    cells[m.group(2)] = int(m.group(1))
R["synth_cells"] = {k: cells[k] for k in ("LUT4", "CCU2C", "TRELLIS_FF", "TRELLIS_DPR16X4", "DP16KD", "MULT18X18D", "EHXPLLL", "ODDRX1F") if k in cells}

exits = {}
if os.path.exists(os.path.join(bd, "pnr_exit.txt")):
    for l in open(os.path.join(bd, "pnr_exit.txt")):
        m = re.match(r"seed (\d+): exit (\d+)", l)
        if m: exits[m.group(1)] = int(m.group(2))

def crit(log, clk, n=40):
    """critical path of 'clk' (posedge->posedge) as compact lines"""
    lines, on = [], False
    for l in log.splitlines():
        if re.search(r"Critical path report for clock '\$glbnet\$%s'" % clk, l): on = True; continue
        if on:
            m = re.match(r"Info:\s+(clk-to-q|logic|routing|setup)\s+([\d.]+)\s+([\d.]+)\s+(Source|Net|Sink)?\s*(\S+)?", l)
            if m and m.group(1) != "routing":
                nm = re.sub(r"(_TRELLIS\w*|_LUT4\w*|_CCU2C\w*|_PFUMX\w*|_L6MUX\w*|\$\w+)", "", m.group(5) or "")
                lines.append(f"{m.group(1):8s} {m.group(2):>5s} {m.group(3):>6s} {nm[:80]}")
            if m and m.group(1) == "setup": break
            if len(lines) > n: break
    return lines

for s in seeds:
    log = open(os.path.join(bd, f"pnr_s{s}.log")).read()
    rep = json.load(open(os.path.join(bd, f"report_s{s}.json")))
    fmax = {k.replace("$glbnet$", ""): {"achieved_mhz": round(v["achieved"], 2), "constraint_mhz": v["constraint"],
            "slack_ns": round(1000 / v["constraint"] - 1000 / v["achieved"], 3),
            "margin_pct": round(100 * (v["achieved"] / v["constraint"] - 1), 1)} for k, v in rep["fmax"].items()}
    util = {k: {"used": v["used"], "available": v["available"]} for k, v in rep["utilization"].items() if v["used"]}
    xd = re.findall(r"Max delay (\S+ ?\S*)\s+-> (\S+ ?\S*)\s*: ([\d.]+) ns", log)
    io = json.loads(subprocess.run([sys.executable, os.path.join(root, "scripts/ecp5_io_paths.py"),
                                    os.path.join(bd, f"report_s{s}.json")], capture_output=True, text=True).stdout)
    warn = len(re.findall(r"^Warning:", log, re.M))
    errs = len(re.findall(r"^ERROR:", log, re.M))
    ok = exits.get(s, 1) == 0 and all(v["achieved_mhz"] >= v["constraint_mhz"] for v in fmax.values())
    R["seeds"][s] = {"exit": exits.get(s), "fmax": fmax, "utilization": util, "warnings": warn, "errors": errs,
                     "cross_domain_max_delay_ns": [{"from": a.strip(), "to": b.strip(), "ns": float(c)} for a, b, c in xd[-6:]],
                     "sdram_io_routing": io,
                     "critical_paths": {c: crit(log, c) for c in ("clk_sys", "clk_pix", "clk_x5")},
                     "timing_ok": ok}
    R["ok"] &= ok

bit = os.path.join(root, "artifacts/vdpx_ecp5_p1.bit")
R["bitstream"] = {"path": "artifacts/vdpx_ecp5_p1.bit", "seed": bit_seed, "sha256": sha(bit),
                  "config_sha256": sha(os.path.join(bd, f"vdpx_ecp5_p1_s{bit_seed}.config")),
                  "netlist_sha256": sha(os.path.join(bd, "vdpx_ecp5_p1.json")),
                  "size": os.path.getsize(bit) if os.path.exists(bit) else None}
R["ok"] &= R["bitstream"]["sha256"] is not None
json.dump(R, open(os.path.join(out, "report.json"), "w"), indent=1)

md = ["# Relatório do build ECP5-P1 (gerado por scripts/ecp5_report.py)", "",
      f"Dispositivo: {R['device']}. Sementes: {', '.join(seeds)}. Bitstream da semente {bit_seed}.", "",
      "| Semente | exit | clk_sys (50) | clk_pix (25) | clk_x5 (125) | avisos P&R | timing |", "|---|---|---|---|---|---|---|"]
for s, d in R["seeds"].items():
    f = d["fmax"]
    cell = lambda c: f"{f[c]['achieved_mhz']} MHz (+{f[c]['margin_pct']}%, slack {f[c]['slack_ns']} ns)"
    md.append(f"| {s} | {d['exit']} | {cell('clk_sys')} | {cell('clk_pix')} | {cell('clk_x5')} | {d['warnings']} | {'PASS' if d['timing_ok'] else 'FAIL'} |")
md += ["", "Células (síntese): " + ", ".join(f"{k} {v}" for k, v in R["synth_cells"].items()), "",
       f"Bitstream: `{R['bitstream']['path']}` sha256 `{R['bitstream']['sha256']}` ({R['bitstream']['size']} bytes)",
       f"Config (semente {bit_seed}): sha256 `{R['bitstream']['config_sha256']}`; netlist JSON sha256 `{R['bitstream']['netlist_sha256']}`", "",
       "RESULTADO: " + ("PASS" if R["ok"] else "FAIL")]
open(os.path.join(out, "report.md"), "w").write("\n".join(md) + "\n")
print("\n".join(md))
sys.exit(0 if R["ok"] else 1)
