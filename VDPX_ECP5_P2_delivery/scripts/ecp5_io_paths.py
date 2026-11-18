#!/usr/bin/env python3
"""ECP5-P1: on-chip routing delay of every net that reaches or leaves an SDRAM pad, from the
nextpnr --report JSON (detailed_net_timings). nextpnr does not analyse external I/O timing;
this only gives the fabric part (routing FF/LUT -> pad, pad -> FF). Usage: ecp5_io_paths.py report.json"""
import json, sys, re
d = json.load(open(sys.argv[1]))
cls = {"cmd_out": {}, "dq_out": {}, "dq_oe": {}, "dq_in": {}, "clk_out": {}}
for n in d["detailed_net_timings"]:
    for e in n["endpoints"]:
        m = re.match(r"(sdram_\w+(\[\d+\])?)\$tr_io", e["cell"])
        if not m: continue
        pin, port, dl = m.group(1), e["port"], e["delay"][1]
        k = ("clk_out" if pin == "sdram_clk" else "dq_oe" if port == "T" else
             "dq_out" if pin.startswith("sdram_dq") else "cmd_out")
        cls[k][pin] = max(cls[k].get(pin, 0), dl)
    m = re.match(r"(sdram_dq\[\d+\])\$tr_io", n["driver"])
    if m:
        cls["dq_in"][m.group(1)] = max([e["delay"][1] for e in n["endpoints"]] + [0])
res = {k: {"n": len(v), "max_ns": round(max(v.values()), 3) if v else None,
           "worst": max(v, key=v.get) if v else None} for k, v in cls.items()}
print(json.dumps(res))
