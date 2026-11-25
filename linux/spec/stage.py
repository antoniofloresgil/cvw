#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Stage SPEC CPU 2026 benchmarks for the board: for each benchmark a directory with the (stripped) static rv64gc executable, its inputs of one size
(data/all plus data/<size>) and a `cmds` file with one command line per run, ready to be copied to the SD card of the Linux image.

The SPEC installation is only read, never changed.  SPEC CPU 2026 belongs to its licensees: the staged directory holds the benchmarks and their inputs,
so keep it outside git (stage.py refuses an output directory inside a git work tree) and do not publish it.

The command lines come from each benchmark's Spec/object.pm.  Five kinds of `invoke` are understood: arguments in the lines of a `control` file,
arguments in the file <name>.in, no arguments, gem5's `control.cmd` (the statistics are not post-processed) and femflow's <size>.prm.  Others are reported as unsupported (they need a port of their invoke by hand).  `control_fixup` corrects omnetpp (-f/-c), abc (-F <name>.in), gcc and llvm (-o <file>; llvm's --sha512 hashes its output instead of writing it) and cppcheck (--platform=unix64; its test-size `testrunner_r` run is not staged); fotonik3d, vpr and gem5 get their .xz inputs decompressed.
Standard library only:   stage.py --spec <cpu2026_install> --size test --out /datos/tmp/spec-stage [--bench 782.lbm_r ...]
"""

import argparse
import lzma
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from events import GROUPS


def read_lines(path):
    return [ln.rstrip("\n") for ln in path.read_text().splitlines() if ln.strip() and not ln.lstrip().startswith("#")]


def commands(bench_dir, size, exename, benchname):
    """The argument lists of the benchmark's runs, or None if its invoke is of a kind not understood."""
    pm = (bench_dir / "Spec" / "object.pm").read_text()
    inputs = [bench_dir / "data" / "all" / "input", bench_dir / "data" / size / "input"]

    def find(name):
        for d in reversed(inputs):
            if (d / name).is_file():
                return d / name
        return None

    if re.search(r"read_file\(\s*'control'\s*\)", pm):
        ctl = find("control")
        return [shlex.split(ln) for ln in read_lines(ctl)] if ctl else None
    if re.search(r'read_file\(\s*"\$\{name\}\.in"\s*\)', pm):
        f = find(f"{benchname}.in")
        return [shlex.split(f.read_text().strip())] if f else None
    if re.search(r"read_file\(\s*'control\.cmd'\s*\)", pm):  # gem5: --stats-file=<name>.stats.txt, then the line of control.cmd
        ctl = find("control.cmd")
        return [[f"--stats-file={re.sub(r'[^A-Za-z0-9._-]', '_', '_'.join(shlex.split(ln)))}.stats.txt", *shlex.split(ln)] for ln in read_lines(ctl)] if ctl else None
    if re.search(r"\$me->size\(\)\s*\.\s*\"\.prm\"", pm):  # femflow: one argument, <size>.prm
        return [[f"{size}.prm"]] if find(f"{size}.prm") else None
    if re.search(r"'args'\s*=>\s*\[\s*\]", pm):
        return [[]]
    return None


# Benchmarks whose invoke builds the command line from the `control` lines in a way that the plain "the line is the argument list" rule gets wrong.
def control_fixup(benchname, args):
    if benchname == "omnetpp":  # object.pm: -f <ini> -c <configuration>; the third field of the line is not an argument
        return ["-f", args[0], "-c", args[1]]
    if benchname == "cppcheck":  # object.pm: the line, then --platform=unix64
        return [*args, "--platform=unix64"]
    if benchname in ("gcc", "llvm"):  # object.pm: the line, then [--sha512] -o <safe name>.s / .ll
        out = re.sub(r"[^a-zA-Z0-9_.-]", "_", f"{args[0]}.opts" + "_".join(args[1:]))[:200]
        return [*args, "-o", f"{out}.s"] if benchname == "gcc" else [*args, "--sha512", "-o", f"{out}.ll"]
    if benchname == "abc":  # object.pm: -F <line>.in; without -F abc reads commands from the console and never ends
        return ["-F", f"{args[0]}.in"]
    return args


# Benchmarks whose generate_inputs runs `specxz -d` on their inputs: the board has no xz, so they are decompressed here (the .xz files stay).
XZ_INPUTS = ("fotonik3d", "vpr", "gem5")


def stage(spec, size, out, bench):
    bench_dir = spec / "benchspec" / "CPU" / bench
    pm = (bench_dir / "Spec" / "object.pm").read_text()
    exename = re.search(r"\$exename\s*=\s*'([^']+)'", pm).group(1)
    benchname = bench.split(".", 1)[1].rsplit("_", 1)[0]
    exes = re.search(r"@base_exe\s*=\s*\(([^)]*)\)", pm)
    if exes and "," in exes.group(1) and "control.cmd" not in pm:  # gem5's second executable (gem5stats) only reads the statistics afterwards
        return f"{bench}: more than one executable, not supported"
    exe = bench_dir / "exe" / f"{exename}_base.trixie.stripped"
    if not exe.is_file():
        return f"{bench}: {exe.name} not found"
    cmds = commands(bench_dir, size, exename, benchname)
    if cmds is not None:
        cmds = [control_fixup(benchname, a) for a in cmds]
    if cmds is None:
        return f"{bench}: invoke or input of size {size} not understood, port it by hand"
    dest = out / bench
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    for d in (bench_dir / "data" / "all" / "input", bench_dir / "data" / size / "input"):
        if d.is_dir():
            shutil.copytree(d, dest, dirs_exist_ok=True)
    shutil.copy2(exe, dest / exename)
    if benchname in XZ_INPUTS:
        for f in sorted(dest.rglob("*.xz")):
            f.with_suffix("").write_bytes(lzma.open(f).read())
    (dest / "cmds").write_text("".join(shlex.join(["./" + exename, *args]) + "\n" for args in cmds))
    return f"{bench}: {len(cmds)} run(s), {sum(p.stat().st_size for p in dest.rglob('*') if p.is_file()) / 1e6:.1f} MB"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spec", type=Path, required=True, help="the cpu2026_install directory (read only)")
    ap.add_argument("--size", default="test", choices=("test", "train"))
    ap.add_argument("--out", type=Path, required=True, help="staging directory, outside any git work tree")
    ap.add_argument("--bench", nargs="*", help="benchmarks to stage, e.g. 782.lbm_r (default: all of them that are understood)")
    args = ap.parse_args()
    out = args.out.resolve()
    probe = subprocess.run(["git", "-C", str(out.parent if not out.exists() else out), "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True, check=False)
    if probe.stdout.strip() == "true":
        sys.exit(f"{out} is inside a git work tree: SPEC files must not go to git")
    benches = args.bench or sorted(p.name for p in (args.spec / "benchspec" / "CPU").iterdir() if re.match(r"\d+\.\w+_r$", p.name))
    out.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    shutil.copy2(here / "perf-run.sh", out / "perf-run.sh")
    (out / "events").write_text("".join(",".join(g) + "\n" for g in GROUPS))
    for b in benches:
        print(stage(args.spec, args.size, out, b))


if __name__ == "__main__":
    main()
