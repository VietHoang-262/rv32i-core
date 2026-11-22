#!/usr/bin/env python3
"""Verify that the core testbench rejects six representative wiring regressions.

Mutations are made in copies under build/mutations, never in the source RTL.
A passing unmodified baseline is required. Compile errors, simulator timeouts,
and testbench setup failures are inconclusive; they never count as detections.
This is a bounded smoke test of the verification harness, not mutation coverage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


PROJECT = Path(__file__).resolve().parents[1]
MUTATIONS = (
    {
        "name": "rf_source_ports_swapped",
        "file": "rtl/rv32i_core.sv",
        "before": ".rs1_i(dec.rs1), .rs2_i(dec.rs2),",
        "after": ".rs1_i(dec.rs2), .rs2_i(dec.rs1),",
        "purpose": "RF source-address wiring must preserve rs1 and rs2 roles.",
    },
    {
        "name": "alu_immediate_mux_bypassed",
        "file": "rtl/rv32i_core.sv",
        "before": "assign alu_b = dec.alu_src_imm ? dec.imm : rs2_q;",
        "after": "assign alu_b = rs2_q;",
        "purpose": "Immediate ALU instructions must select the decoded immediate.",
    },
    {
        "name": "rf_writeback_bit_corrupted",
        "file": "rtl/rv32i_core.sv",
        "before": ".rd_data_i(result_q)",
        "after": ".rd_data_i(result_q ^ 32'd1)",
        "purpose": "The physical RF write port must receive the committed result.",
    },
    {
        "name": "store_lane_shift_bypassed",
        "file": "rtl/rv32i_lsu.sv",
        "before": "wdata_o = store_data_i << lane_shift;",
        "after": "wdata_o = store_data_i;",
        "purpose": "Subword stores must place the low rs2 bytes in addressed lanes.",
    },
    {
        "name": "pc_advanced_during_fetch_stall",
        "file": "rtl/rv32i_core.sv",
        "before": "end else state_q <= FETCH_WAIT;",
        "after": "end else begin pc_q <= pc_q + 32'd4; state_q <= FETCH_WAIT; end",
        "purpose": "PC and instruction request address must remain stable while stalled.",
    },
    {
        "name": "jalr_bit_zero_mask_removed",
        "file": "rtl/rv32i_core.sv",
        "before": "control_target = (rs1_q + dec.imm) & 32'hffff_fffe;",
        "after": "control_target = rs1_q + dec.imm;",
        "purpose": "JALR must clear target bit zero before checking IALIGN32.",
    },
)


def run_logged(command: list[str], destination: Path, timeout: float):
    try:
        result = subprocess.run(
            command, cwd=PROJECT, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        destination.write_text(output + "\nHarness subprocess timeout\n")
        return None, output
    destination.write_text(result.stdout)
    return result.returncode, result.stdout


def detected_failure(returncode, output: str):
    if returncode is None or returncode == 0:
        return False
    # An explicit testbench failure is required. Infrastructure failures are
    # deliberately distinguished from a test detecting wrong CPU behavior.
    if not re.search(r"\bFATAL:", output):
        return False
    excluded = (
        "timeout", "cannot open", "missing +case", "missing expected",
        "bad configuration", "bad retirement reference", "bad data reference",
        "wrong RESET_PC", "Unable to open", "$readmemh",
    )
    return not any(word.lower() in output.lower() for word in excluded)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--iverilog", default=os.environ.get("IVERILOG", "iverilog"))
    ap.add_argument("--iverilog-flags", default=os.environ.get("IVERILOG_FLAGS", ""))
    ap.add_argument("--vvp", default=os.environ.get("VVP", "vvp"))
    ap.add_argument("--build", type=Path, default=Path("build"))
    ap.add_argument("--case", default="isa_seed_1")
    ap.add_argument("--timeout", type=float, default=30)
    args = ap.parse_args()
    build = args.build if args.build.is_absolute() else PROJECT / args.build
    case = build / "cases" / args.case
    if not (case / "config.hex").is_file():
        ap.error("generated test case missing; run make generate first")
    rtl_paths = [Path(line) for line in (PROJECT / "rtl/rtl.f").read_text().splitlines() if line.strip()]
    original = {str(p): (PROJECT / p).read_text() for p in rtl_paths}
    fingerprints = {name: hashlib.sha256(text.encode()).hexdigest() for name, text in original.items()}
    out = build / "mutations"
    out.mkdir(parents=True, exist_ok=True)
    compiler = shlex.split(args.iverilog) + shlex.split(args.iverilog_flags)
    simulator = shlex.split(args.vvp)
    results = []

    # The same case and delay schedule must pass before any mutated run.
    for mutation in (None,) + MUTATIONS:
        name = mutation["name"] if mutation else "baseline"
        directory = out / name
        directory.mkdir(parents=True, exist_ok=True)
        source = dict(original)
        if mutation:
            text = source[mutation["file"]]
            if text.count(mutation["before"]) != 1:
                raise RuntimeError(f"{name}: mutation site must match exactly once")
            source[mutation["file"]] = text.replace(mutation["before"], mutation["after"], 1)
        paths = []
        for relative, text in source.items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            paths.append(str(path))
        image = directory / "tb_core.vvp"
        compile_command = compiler + ["-g2012", "-I", str(PROJECT), "-s", "tb_core", "-o", str(image)] + paths + ["tb/tb_latency_memory.sv", "tb/tb_core.sv"]
        code, _ = run_logged(compile_command, directory / "compile.log", args.timeout)
        record = {"name": name, "status": "inconclusive_compile_failure", "compile_returncode": code}
        if mutation:
            record.update({"source": mutation["file"], "purpose": mutation["purpose"]})
        if code == 0:
            command = simulator + [str(image), f"+case={case}", "+latency=2"]
            run_code, output = run_logged(command, directory / "simulation.log", args.timeout)
            record["simulation_returncode"] = run_code
            if mutation is None:
                record["status"] = "pass" if run_code == 0 and "PASS core " in output else "baseline_failed"
            elif detected_failure(run_code, output):
                record["status"] = "detected"
                record["evidence"] = next(line for line in output.splitlines() if "FATAL:" in line)
            elif run_code == 0:
                record["status"] = "survived"
            else:
                record["status"] = "inconclusive_simulator_failure"
        results.append(record)
        print(f"{record['status'].upper()} mutation {name}", flush=True)
        if mutation is None and record["status"] != "pass":
            break

    # Detect any accidental source-tree write by the harness as a hard failure.
    unchanged = all(hashlib.sha256((PROJECT / name).read_bytes()).hexdigest() == digest for name, digest in fingerprints.items())
    detected = sum(item["status"] == "detected" for item in results)
    report = {
        "case": args.case, "latency_mode": 2, "baseline_pass": results[0]["status"] == "pass",
        "detected": detected, "planned_mutations": len(MUTATIONS), "source_rtl_unchanged": unchanged,
        "scope": "Six selected wiring faults; not a general mutation-coverage score.", "results": results,
    }
    (out / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    if detected != len(MUTATIONS) or not unchanged or not report["baseline_pass"]:
        print(f"FAIL mutation smoke: {detected}/{len(MUTATIONS)} detected; see {out / 'summary.json'}", file=sys.stderr)
        return 1
    print(f"PASS mutation smoke: {detected}/{len(MUTATIONS)} selected wiring faults detected; original RTL unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
