#!/usr/bin/env python3
"""Independent byte-for-byte expected output from the upstream Zmod script."""
from pathlib import Path
import subprocess
import sys
import json

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
header = b'; HEADER_BLOCK_START\n; filament_colour = #FF0000;#00FF00;#FFFFFF\n; filament_type = PLA;PETG;ABS\n; HEADER_BLOCK_END\n'
outline = b'EXCLUDE_OBJECT_DEFINE NAME=part CENTER=5,5 POLYGON= [[0,0],[5,0],[10,0],[10,5],[10,10],[5,10],[0,10],[0,5],[0,0]] EXTRA=1\n'
cases = [b'', b'G28', b'G28\n', header+b'T2\nT0\nT2\n'+outline,
         header+b'T-1\nT+2 ; comment\nT1_0\nT1\n',
         b'; MD5:old\r\n; zmod_color_data = stale\r\n'+header+b'; zmod_color_data = duplicate\nG28\n',
         b'; author \xff\xfe\rG28\r\nG1 X3\n', outline,
         b'EXCLUDE_OBJECT_DEFINE POLYGON=bad\n',
         b'EXCLUDE_OBJECT_DEFINE POLYGON=[[0,0],[true,0],[1,1],[0,1],[0,0]]\n',
         b'EXCLUDE_OBJECT_DEFINE POLYGON=[[0,0],[0.00001,0],[0.00002,0],[0.00002,0.00002],[0,0.00002],[0,0]]\n',
         b'G1 X5\n' * 20000]
records=[]
for index, payload in enumerate(cases):
    for mode, flags in [('default', []), ('none', ['--no-simplify-objects']), ('box', ['--simplify-objects','0'])]:
        name=f'{index}-{mode}'
        original=out/(name+'.input')
        expected=out/(name+'.expected')
        original.write_bytes(payload)
        expected.write_bytes(payload)
        subprocess.run([sys.executable, str(root/'ios/tests/fixtures/zmod-preprocess-reference.py'), *flags, str(expected)],check=True)
        records.append({'name':name,'command':'zmod-preprocess.py' + ((' '+' '.join(flags)) if flags else '')})
(out/'cases.json').write_text(json.dumps(records))
