#!/usr/bin/env bash
# Run the generated core regression using Verilator's timing simulator.
# Generate inputs first with: make generate
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
tools_dir="$project_dir/../.tools"
VERILATOR=${VERILATOR:-verilator}
PYTHON=${PYTHON:-python3}
BUILD=${BUILD:-build}
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
verilator_prefix=$(CDPATH= cd -- "$(dirname -- "$VERILATOR")/.." 2>/dev/null && pwd || true)
if [[ -d "$verilator_prefix/share/verilator/include" ]]; then
    export VERILATOR_ROOT=${VERILATOR_ROOT:-"$verilator_prefix/share/verilator"}
fi
if [[ ! -f "$BUILD/cases/cases.txt" ]]; then
    echo "Generated cases missing; run make generate first" >&2
    exit 1
fi

mkdir -p "$BUILD"
"$VERILATOR" --version
# These warnings arise from simulation-only integer flags and the testbench
# timescale; core RTL has a separate strict lint target.
"$VERILATOR" --binary --timing -j "${JOBS:-2}" \
    -Wno-TIMESCALEMOD -Wno-WIDTH \
    --top-module tb_core --Mdir "$BUILD/verilator_core" -o sim_core \
    -f rtl/rtl.f tb/tb_latency_memory.sv tb/tb_core.sv \
    > "$BUILD/verilator_compile.log" 2>&1
"$VERILATOR" --binary --timing -j "${JOBS:-2}" \
    -Wno-TIMESCALEMOD -Wno-WIDTH \
    --top-module tb_core -GRESET_PC=2 \
    --Mdir "$BUILD/verilator_pc2" -o sim_core \
    -f rtl/rtl.f tb/tb_latency_memory.sv tb/tb_core.sv \
    > "$BUILD/verilator_pc2_compile.log" 2>&1

"$PYTHON" scripts/run_tests.py --engine verilator --build "$BUILD" \
    | tee "$BUILD/verilator_regression.log"
