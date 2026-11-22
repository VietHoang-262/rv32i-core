#!/usr/bin/env bash
# Generic synthesis smoke check; no technology mapping, timing or PPA claim.
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
tools_dir="$project_dir/../.tools"

SV2V=${SV2V:-sv2v}
YOSYS=${YOSYS:-yosys}
if ! command -v "$SV2V" >/dev/null 2>&1; then
    if [[ -x "$tools_dir/sv2v/sv2v-Linux/sv2v" ]]; then
        SV2V="$tools_dir/sv2v/sv2v-Linux/sv2v"
    else
        echo "sv2v not found; install it or set SV2V=/path/to/sv2v" >&2
        exit 1
    fi
fi
if ! command -v "$YOSYS" >/dev/null 2>&1; then
    if [[ -x "$tools_dir/yosys/usr/bin/yosys" ]]; then
        YOSYS="$tools_dir/yosys/usr/bin/yosys"
    else
        echo "Yosys not found; install it or set YOSYS=/path/to/yosys" >&2
        exit 1
    fi
fi
if [[ "$YOSYS" == "$tools_dir/yosys/usr/bin/yosys" ]]; then
    export YOSYS_DATDIR=${YOSYS_DATDIR:-"$tools_dir/yosys/usr/share/yosys"}
fi

mkdir -p build
"$SV2V" --version
"$YOSYS" -V
"$SV2V" \
    rtl/rv32i_pkg.sv \
    rtl/rv32i_alu.sv \
    rtl/rv32i_decoder.sv \
    rtl/rv32i_regfile.sv \
    rtl/rv32i_lsu.sv \
    rtl/rv32i_core.sv > build/rv32i_core.v

"$YOSYS" -l build/synthesis.log -p '
    read_verilog build/rv32i_core.v;
    hierarchy -check -top rv32i_core;
    synth -top rv32i_core -noabc;
    check -assert;
    select -assert-none t:$dlatch t:$adlatch t:$_DLATCH_* t:$_DLATCHSR_*;
    stat;
    write_verilog -noattr build/rv32i_core_synth.v
' > build/synthesis.stdout.log

tail -55 build/synthesis.log
echo "PASS synthesis: hierarchy, generic synthesis, connectivity and no-latch checks"
