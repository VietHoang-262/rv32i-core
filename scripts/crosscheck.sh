#!/usr/bin/env bash
# Run the generated core regression using Verilator's timing simulator.
# Generate inputs first with: make generate
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
tools_dir="$project_dir/../.tools"
VERILATOR=${VERILATOR:-verilator}
PYTHON=${PYTHON:-python3}
if ! command -v "$VERILATOR" >/dev/null 2>&1; then
    if [[ -x "$tools_dir/verilator/usr/bin/verilator_bin" ]]; then
        VERILATOR="$tools_dir/verilator/usr/bin/verilator_bin"
        export VERILATOR_ROOT=${VERILATOR_ROOT:-"$tools_dir/verilator/usr/share/verilator"}
    else
        echo "Verilator not found; install it or set VERILATOR=/path/to/verilator" >&2
        exit 1
    fi
fi
if [[ "$VERILATOR" == "$tools_dir/verilator/usr/bin/verilator_bin" ]]; then
    export VERILATOR_ROOT=${VERILATOR_ROOT:-"$tools_dir/verilator/usr/share/verilator"}
fi
if [[ ! -f build/cases/cases.txt ]]; then
    echo "Generated cases missing; run make generate first" >&2
    exit 1
fi

mkdir -p build
"$VERILATOR" --version
# These warnings arise from simulation-only integer flags and the testbench
# timescale; core RTL has a separate strict lint target.
"$VERILATOR" --binary --timing -j "${JOBS:-2}" \
    -Wno-TIMESCALEMOD -Wno-WIDTH \
    --top-module tb_core --Mdir build/verilator_core -o sim_core \
    -f rtl/rtl.f tb/tb_latency_memory.sv tb/tb_core.sv \
    > build/verilator_compile.log 2>&1
"$VERILATOR" --binary --timing -j "${JOBS:-2}" \
    -Wno-TIMESCALEMOD -Wno-WIDTH \
    --top-module tb_core -GRESET_PC=2 \
    --Mdir build/verilator_pc2 -o sim_core \
    -f rtl/rtl.f tb/tb_latency_memory.sv tb/tb_core.sv \
    > build/verilator_pc2_compile.log 2>&1

"$PYTHON" - <<'PY' | tee build/verilator_regression.log
from pathlib import Path
import subprocess

count = 0
for name in Path('build/cases/cases.txt').read_text().splitlines():
    image = 'build/verilator_pc2/sim_core' if name == 'reset_pc_align' else 'build/verilator_core/sim_core'
    for latency in (0, 1, 2):
        subprocess.run([image, f'+case=build/cases/{name}', f'+latency={latency}'], check=True)
        count += 1
for name, mode in (('reset_fetch', 1), ('reset_data', 2), ('reset_store', 2)):
    subprocess.run(['build/verilator_core/sim_core', f'+case=build/cases/{name}', '+latency=2', f'+reset_mode={mode}'], check=True)
    count += 1
subprocess.run(['build/verilator_core/sim_core', '+case=build/cases/ecall', '+latency=2', '+restart_halted=1'], check=True)
count += 1
print(f'PASS Verilator crosscheck: {count} core runs')
PY
