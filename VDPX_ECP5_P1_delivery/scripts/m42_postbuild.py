#!/usr/bin/env python3
"""Structural CN2 safety check on actual synthesized/routed netlists."""
import json,sys
from pathlib import Path
out=Path(sys.argv[1] if len(sys.argv)>1 else 'build_m42');out.mkdir(exist_ok=True,parents=True)
syn=json.loads(Path('build_tang/tang.json').read_text())['modules']['tang_top']
ports={n:p for n,p in syn['ports'].items() if n.startswith('md_')}
assert len(ports)==6 and all(p['direction']=='input' for p in ports.values())
pnr=json.loads(Path('build_tang/pnr.json').read_text())['modules']
top=pnr.get('top',pnr.get('tang_top'))
rows=[{'name':n,'type':c['type'],'attributes':c.get('attributes',{})} for n,c in top['cells'].items() if c['type'] in ('IBUF','OBUF','IOBUF','TLVDS_OBUF')]
md=[r for r in rows if '.md_' in r['name']]
assert len(md)>=23 and all(r['type']=='IBUF' for r in md)
(out/'synth_pin_directions.json').write_text(json.dumps(ports,indent=2)+'\n')
(out/'pnr_io_report.json').write_text(json.dumps(rows,indent=2)+'\n')
print(f'PASS: all six md_* ports input; {len(md)} retained CN2 IBUF cells; no physical qualification implied')
