#!/usr/bin/env python3
from pathlib import Path
import re,json
s=Path('rtl/board/tang_top.v').read_text()
assert re.search(r'input\s+\[15:0\]\s+md_d',s)
assert not re.search(r'assign\s+md_d\s*=',s)
pins=re.findall(r'IO_LOC\s+"([^"]+)"\s+(\d+)',Path('board/tang_nano_20k.cst').read_text())
assert len({p for n,p in pins})==len(pins)
assert all(p not in {'25','26','52','53'} for n,p in pins if n.startswith('md_'))
acc=0;last=0;edges=[]
for t in range(1,10501):
 acc+=512
 if acc>=1050:
  acc-=1050;edges.append(t-last);last=t
assert len(edges)==5120 and set(edges)=={2,3}
report={'cst_unique_pins':len(pins),'md_data_direction':'input only','pins':dict(pins),
'mclk_average_hz':50400000*256/1050,'mclk_half_period_ns':sorted({x*1e9/50400000 for x in edges}),
'mclk_physical_status':'BLOCKED: no PCM1808 captures','scope':'static pin audit and divider arithmetic; not P&R or analog validation'}
Path('build_m42/pin_clock_report.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS static pins/input-only; MCLK 5120 transitions/10500 cycles, half-periods 2/3 clocks; ADC physical BLOCKED')
