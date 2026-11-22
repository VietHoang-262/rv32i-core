#!/usr/bin/env python3
"""Run grouped differential RTL tests and enforce architectural coverage gates.
Coverage counts describe model paths checked by successful RTL simulations, not
simulator code coverage. The independent unit checker and fixed goldens provide
additional checks against an error in the local reference model.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--vvp', default='vvp')
    ap.add_argument('--engine', choices=('icarus','verilator'), default='icarus')
    ap.add_argument('--build', type=Path, default=Path('build'))
    ap.add_argument('--group', help='Run one named ISA group (for example r_type or loads)')
    ap.add_argument('--summary', type=Path)
    ap.add_argument('--timeout',type=float,default=60,help='Wall-clock seconds per simulation, including delta-cycle hangs')
    a=ap.parse_args()
    cases=a.build/'cases'
    names=(cases/'cases.txt').read_text().splitlines()
    metadata={name:json.loads((cases/name/'metadata.json').read_text()) for name in names}
    if a.group:
        names=[name for name in names if metadata[name]['group']==a.group]
        if not names: ap.error(f'no cases for group {a.group}')
    coverage_spec=json.loads((cases/'coverage.json').read_text())
    summary_path=a.summary or a.build/f'{a.engine}_{a.group+"_" if a.group else ""}regression_summary.json'
    schedules=(
        ('zero', ['+latency=0']),
        ('one', ['+latency=1']),
        ('variable_noise', ['+latency=2','+idle_noise=1']),
        ('fast_i_slow_d', ['+imem_latency=0','+dmem_latency=3','+idle_noise=1']),
        ('slow_i_fast_d', ['+imem_latency=3','+dmem_latency=0','+idle_noise=1']),
        ('long_variable', ['+imem_latency=4','+dmem_latency=4','+idle_noise=1']),
    )
    results=[]; groups=defaultdict(lambda:dict(cases=[],runs=0,golden_checks=0))
    unique_passed=set()

    def run(name,schedule,args):
        pc2=name=='reset_pc_align'
        if a.engine=='icarus':
            image=a.build/('tb_core_pc2.vvp' if pc2 else 'tb_core.vvp')
            command=shlex.split(a.vvp)+[str(image)]
        else:
            command=[str(a.build/('verilator_pc2' if pc2 else 'verilator_core')/'sim_core')]
        command += [f'+case={cases}/{name}']+args
        try:
            completed=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=a.timeout)
        except subprocess.TimeoutExpired as exc:
            output=exc.stdout or ''
            if isinstance(output,bytes): output=output.decode(errors='replace')
            print(output,end='',flush=True)
            summary_path.write_text(json.dumps(dict(status='FAIL',engine=a.engine,failed_case=name,schedule=schedule,command=command,reason='wall_clock_timeout',timeout_seconds=a.timeout,passed_runs=len(results)),indent=2)+'\n')
            raise RuntimeError(f'{a.engine} timeout after {a.timeout}s: {name} schedule={schedule}') from exc
        print(completed.stdout,end='',flush=True)
        if completed.returncode or 'PASS core ' not in completed.stdout:
            summary_path.write_text(json.dumps(dict(status='FAIL',engine=a.engine,failed_case=name,schedule=schedule,command=command,returncode=completed.returncode,passed_runs=len(results)),indent=2)+'\n')
            raise RuntimeError(f'{a.engine} failed {name} schedule={schedule}')
        group=metadata[name]['group']
        groups[group]['runs']+=1
        if name not in unique_passed:
            unique_passed.add(name); groups[group]['cases'].append(name)
            groups[group]['golden_checks']+=metadata[name]['golden_checks']
        results.append(dict(case=name,group=group,schedule=schedule,status='PASS'))

    for name in names:
        for schedule,args in schedules: run(name,schedule,args)
    if not a.group:
        for name,mode in (('reset_fetch',1),('reset_data',2),('reset_store',2)):
            run(name,'reset_stall',['+latency=2',f'+reset_mode={mode}'])
            run(name,'reset_long_stall',['+latency=3','+idle_noise=1',f'+reset_mode={mode}','+reset_wait=5'])
            run(name,'reset_completion_cancel',['+latency=3','+idle_noise=1',f'+reset_mode={mode}','+reset_completion=1'])
        run('ecall','reset_halted',['+latency=2','+idle_noise=1','+restart_halted=1'])
    counts=Counter()
    for name in unique_passed: counts.update(metadata[name]['coverage'])
    minimums=coverage_spec['minimums']
    if a.group:
        selected_mnemonics={key.split(':')[1] for name in names for key in metadata[name]['coverage'] if key.startswith('mnemonic:')}
        minimums={key:value for key,value in minimums.items() if not key.startswith('fault:') and key.split(':')[1] in selected_mnemonics}
    missing={key:value for key,value in minimums.items() if counts[key]<value}
    report=dict(status='FAIL' if missing else 'PASS',engine=a.engine,case_count=len(unique_passed),run_count=len(results),golden_checks=sum(metadata[name]['golden_checks'] for name in unique_passed),coverage=dict(source='reference executed paths from unique cases whose RTL comparisons passed',counts=dict(sorted(counts.items())),minimums=minimums,missing=missing),groups=dict(sorted(groups.items())),runs=results)
    summary_path.write_text(json.dumps(report,indent=2)+'\n')
    if missing: raise RuntimeError(f'coverage gates failed: {missing}')
    for group,data in sorted(groups.items()):
        print(f'PASS group {group}: {len(data["cases"])} cases, {data["runs"]} runs, {data["golden_checks"]} fixed goldens')
    print(f'PASS {a.engine} regression: {len(results)} core runs, {len(minimums)} coverage gates, {report["golden_checks"]} fixed goldens; report={summary_path}')


if __name__=='__main__':
    try: main()
    except (RuntimeError,OSError,ValueError) as exc:
        print(f'FAIL: {exc}',file=sys.stderr); sys.exit(1)
