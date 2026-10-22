#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Bounded per-change single-core/multicore matrix; no Linux or commercial tools."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'config/multicore'))
import profiles

UPSTREAM_REF = "4ce065926c8096f34c77867c358f044ec1ea777e"
# Stress capacities are named in schema.json, separate from deployment defaults.
CASES = {
    'single-default': ('rv64gc', 'default', [1]),
    'bus': ('deriv/multicore_atomic', 'stress', [1, 2, 3]),
    'msi': ('deriv/multicore_msi', 'ci-msi', [2, 3]),
    'mesi-banked': ('deriv/multicore_msi', 'ci-mesi-banked', [2, 3]),
}


def execute(command, log, cwd=None):
    """Keep the exact command and diagnostics, and fail on nonzero status."""
    log.with_suffix(".command.json").write_text(json.dumps(list(map(str, command)), indent=2) + "\n")
    with log.open("w") as stream:
        subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True, cwd=cwd)


def lint(root, work, config, params, cores):
    """Use lint-wally's warning policy with explicit topology parameters."""
    command = ["verilator", "--lint-only", "--top-module", "wallywrapper", f"-GNCORES={cores}", *params,
               f"-I{root}/config/shared", f"-I{root}/config/{config}", str(root / "src/cvw.sv"),
               str(root / "testbench/wallywrapper.sv"),
               *map(str, sorted(p for p in (root / "src").rglob("*.sv") if p.name != "cvw.sv")),
               "-Wall", "-Wno-UNUSEDSIGNAL", "-Wno-VARHIDDEN", "-Wno-GENUNNAMED", "-Wno-PINCONNECTEMPTY"]
    execute(command, work / f"lint-{cores}.log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["all", *CASES, "feature-interactions"], default="all")
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--skip-deriv", action="store_true", help="Enclosing regression has already generated configs")
    args = parser.parse_args()
    if "WALLY" not in os.environ:
        parser.error("Source ./setup.sh first")
    root = Path(os.environ["WALLY"]).resolve()
    work = args.work_dir.resolve() if args.work_dir else root / "sim/verilator/wkdir/multicore-ci"
    work.mkdir(parents=True, exist_ok=True)
    selected = list(CASES) if args.case == "all" else ([] if args.case == "feature-interactions" else [args.case])
    summary = work / f"results-{args.case}.json"
    # Invalidate all selected case summaries before any build, including deriv generation.
    summary.unlink(missing_ok=True)
    for name in selected:
        (work / name / "results.json").unlink(missing_ok=True)
    sources = [p for directory in ("src", "config", "testbench", "tests/multicore", "tests/coverage", "linux/smp")
               for p in (root / directory).rglob("*") if p.is_file() and p.suffix in (".sv", ".svh", ".vh", ".py", ".S", ".h", ".cpp", ".ld") and "deriv" not in p.parts]
    sources.extend(root / name for name in ("bin/regression-wally", "bin/lint-wally", "bin/derivgen.pl", "config/derivlist.txt",
                                           ".github/workflows/multicore.yml", "config/multicore/schema.json", "setup.sh", "sim/verilator/wrapper.c", "examples/link/link.ld"))
    manifest = {"results": []}
    try:
        profiles.check_generated()
        manifest.update({"source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
                         "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip(),
                         "compiler": subprocess.check_output(["riscv64-unknown-elf-gcc", "--version"], text=True).splitlines()[0],
                         "sources": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}})
        if not args.skip_deriv:
            execute(["perl", str(root / "bin/derivgen.pl")], work / f"deriv-{args.case}.log")
        for name in selected:
            started = time.monotonic()
            casework = work / name
            casework.mkdir(exist_ok=True)
            config, profile, core_counts = CASES[name]
            options = ['--profile', profile, '--cores', *map(str, core_counts)]
            values = profiles.resolve(profile)
            params = [arg for arg in profiles.verilator_args(values) if not arg.startswith('-GNCORES=')]
            print(f"Starting multicore CI case {name}", flush=True)
            if name == 'single-default':
                execute([sys.executable, str(root / 'tests/multicore/check_capabilities.py'),
                         '--work-dir', str(casework / 'capabilities')], casework / 'capabilities.log')
                execute([sys.executable, str(root / 'tests/multicore/check_profiles.py'),
                         '--work-dir', str(casework / 'policy')], casework / 'policy.log')
            for cores in ([1] if name == "single-default" else [2, 3]):
                lint(root, casework, config, params, cores)
            if name == "single-default":
                execute([sys.executable, str(root / "tests/multicore/check_singlecore.py"), "--upstream-ref", UPSTREAM_REF,
                         "--work-dir", str(casework / "compatibility"), "--atomic-walker"], casework / "run.log")
                # Reuse the same model/ELF with ordinary cacheability as well.
                atomic = casework / "compatibility/atomic-walker"
                execute([str(atomic / "cached/model/Vtestbench"), f"+ElfFile={atomic}/amoADUpdate.elf",
                         "+TEST=atomic-walker", "+CACHEABLE_DATA", f"+sim_log_prefix={atomic}/native"],
                        casework / "native-run.log", cwd=root / "sim/verilator")
                if "SUCCESS! All tests ran without failures." not in (casework / "native-run.log").read_text():
                    raise SystemExit("Native single-core test did not report success")
            else:
                if name == 'bus':
                    execute([sys.executable, str(root / 'tests/multicore/check_observation.py'),
                             '--work-dir', str(casework / 'observation')], casework / 'observation.log')
                    execute([sys.executable, str(root / 'tests/multicore/check_engines.py'),
                             '--work-dir', str(casework / 'engines')], casework / 'engines.log')
                if name in ("bus", "mesi-banked"):
                    execute([sys.executable, str(root / "tests/multicore/check_boundary.py"),
                             "--banks", "1" if name == "bus" else "2", *(["--negative"] if name == "bus" else []),
                             "--work-dir", str(casework / "adapter")], casework / "adapter.log")
                execute([sys.executable, str(root / "tests/multicore/run.py"), "--skip-deriv", "--suite", "atomic",
                         "--latency", "0", "3", *options, "--work-dir", str(casework)], casework / "run.log")
            effective = [profiles.probe(config, {**values, 'NCORES': n}, casework / f'config-{n}') for n in core_counts]
            scope = {'environment': 'verilator', 'full_core_harts': core_counts,
                     'full_core_widths': sorted({c['core']['XLEN'] for c in effective}),
                     'full_core_latencies': [] if name == 'single-default' else [0, 3],
                     'full_core_bus_error_policy': 'fault_free_required_by_guard' if name != 'single-default' else 'native_compatibility_fixture',
                     'injected_error_verdicts': 'transport_only', 'linux_boot': 'not_run', 'fpga_multicore': 'not_run',
                     'hart_count_qualification': 'executed_counts_only'}
            result = {"validation_scope": scope, "effective_configurations": effective, "case": name, "config": config, "options": options, "lint_parameters": params,
                      "config_sha256": hashlib.sha256((root / "config" / config / "config.vh").read_bytes()).hexdigest(),
                      "suite": "translated AMO, cached and uncacheable" if name == "single-default" else "atomic and smoke",
                      "latencies": [] if name == "single-default" else [0, 3],
                      "verdict": "PASS", "elapsed_seconds": round(time.monotonic() - started, 2)}
            (casework / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            manifest["results"].append(result)
            print(f"PASS: multicore CI case {name} ({result['elapsed_seconds']} s)", flush=True)
        if args.case in ("all", "feature-interactions"):
            feature_work = work / "feature-interactions"
            feature_work.mkdir(parents=True, exist_ok=True)
            execute([sys.executable, str(root / "tests/multicore/check_feature_interactions.py"),
                     "--work-dir", str(feature_work)], feature_work / "run.log")
            feature_report = json.loads((feature_work / "feature-coverage.json").read_text())
            manifest["feature_interactions"] = {"verdict": feature_report["verdict"],
                                                "report": str(feature_work / "feature-coverage.json"),
                                                "coverage": feature_report["coverage"],
                                                "limits": feature_report["limits"]}
    except (subprocess.CalledProcessError, OSError, SystemExit, ValueError) as error:
        manifest["verdict"] = "FAIL"
        manifest["error"] = str(error)
        summary.write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"FAIL: multicore CI matrix; see {work}: {error}", file=sys.stderr)
        return 1
    manifest["verdict"] = "PASS"
    summary.write_text(json.dumps(manifest, indent=2) + "\n")
    print("SUCCESS! Multicore CI matrix passed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
