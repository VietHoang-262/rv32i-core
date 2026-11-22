#!/usr/bin/env python3
"""Run generated programs against the RTL under completion latencies 0, 1, 0..6."""
import argparse
from pathlib import Path
import shlex
import subprocess

ap=argparse.ArgumentParser()
ap.add_argument('--vvp', default='vvp')
ap.add_argument('--build', type=Path, default=Path('build'))
a=ap.parse_args()
base=shlex.split(a.vvp)
count=0
for name in (a.build/'cases/cases.txt').read_text().splitlines():
    image=a.build/('tb_core_pc2.vvp' if name=='reset_pc_align' else 'tb_core.vvp')
    for latency in (0,1,2):
        command=base+[str(image),f'+case={a.build}/cases/{name}',f'+latency={latency}']
        subprocess.run(command, check=True)
        count+=1
for name,mode in (('reset_fetch',1),('reset_data',2),('reset_store',2)):
    subprocess.run(base+[str(a.build/'tb_core.vvp'),f'+case={a.build}/cases/{name}','+latency=2',f'+reset_mode={mode}'], check=True)
    count+=1
subprocess.run(base+[str(a.build/'tb_core.vvp'),f'+case={a.build}/cases/ecall','+latency=2','+restart_halted=1'],check=True)
count+=1
print(f'PASS regression: {count} core runs')
