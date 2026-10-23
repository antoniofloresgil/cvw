# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run the generated SMP boot test on the Wally RTL or QEMU reference machine."""

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "linux/smp"


sys.path.insert(0, str(ROOT / 'config/multicore'))
import profiles  # noqa: E402 -- repository-local scripts share the policy module
from devicetree import verify_images  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path.home() / "wally-smp-work")
    parser.add_argument("--sim", choices=["verilator", "qemu"], default="verilator")
    parser.add_argument("--cycles", type=int, default=1000000000)
    parser.add_argument("--timeout", type=int, default=300, help="QEMU wall time in seconds")
    parser.add_argument("--jobs", type=int, default=2)
    profiles.add_arguments(parser, default=None, linux=True)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--checkpoint", type=Path, help="Snapshot path; defaults to a mode-specific file in --work")
    parser.add_argument("--checkpoint-interval", type=int, default=5000000)
    parser.add_argument("--resume", action="store_true", help="Restore a compatible checkpoint; combine with --reuse")
    parser.add_argument("--reuse", action="store_true", help="Reuse an already compiled RTL model")
    args = parser.parse_args()
    work = args.work.resolve()
    manifest = json.loads((work / "manifest.json").read_text())
    if 'effective_configuration' not in manifest:
        parser.error('Image manifest lacks an elaborated configuration; regenerate images with build.py')
    try:
        topology = profiles.from_args(args, linux=True, base=manifest['effective_configuration']['multicore'])
        if args.profile and profiles.from_args(args, linux=True) != topology:
            raise ValueError('Selected profile differs from image topology')
        if topology != manifest['effective_configuration']['multicore']:
            raise ValueError('Parameters differ from image manifest; regenerate DTB/images')
        options = profiles.legacy_options(topology)
        if any(manifest.get(k) != v for k, v in options.items()):
            raise ValueError('Legacy image metadata differs from effective topology')
    except ValueError as error:
        parser.error(str(error))
    cores, mode, words = options['cores'], options['cache_mode'], options['cache_words']
    icache, iwords = options['private_icache'], options['icache_words']
    local_reads, local_writes = options['local_dcache_reads'], options['local_dcache_writes']
    banks, mesi, bursts = options['coherence_banks'], options['mesi'], options['cache_bursts']
    forwarding = options['cache_to_cache']
    dline, iline = options['cache_line_words'], options['icache_line_words']
    if args.cycles < 1 or args.checkpoint_interval < 1:
        parser.error("Cycle limit and checkpoint interval must be positive")
    if args.resume and (args.build_only or not args.reuse):
        parser.error("--resume requires --reuse and cannot be combined with --build-only")
    if 'WALLY' not in os.environ:
        parser.error('Source ./setup.sh first')
    import fcntl

    lock_file = (work / 'rtl.lock').open('a')
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('Another RTL build/run is using this work directory')
    if not args.reuse:
        subprocess.run(['perl', str(ROOT / 'bin/derivgen.pl')], check=True)
    effective = profiles.probe('deriv/multicore_linux', topology, work / 'configuration')
    try:
        verify_images(work, effective, manifest)
    except ValueError as error:
        parser.error(str(error))
    if args.sim == "qemu":
        command = [
            "qemu-system-riscv64",
            "-M",
            "virt",
            "-m",
            f"{profiles.LINUX['ram_mb']}M",
            "-smp",
            str(cores),
            "-bios",
            str(work / "opensbi/platform/generic/firmware/fw_jump.bin"),
            "-kernel",
            str(work / "kernel/arch/riscv/boot/Image"),
            "-dtb",
            str(work / "wally-smp.dtb"),
            "-nographic",
            "-no-reboot",
        ]
        print(" ".join(command), flush=True)
        log = work / "qemu.log"
        with log.open("w") as stream:
            proc = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
            import time

            try:
                start = time.monotonic()
                while proc.poll() is None and time.monotonic() - start < args.timeout:
                    output = log.read_text(errors="replace")
                    if "WALLY_SMP_PASS" in output or "WALLY_SMP_FAIL" in output:
                        break
                    time.sleep(0.2)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        output = log.read_text(errors="replace")
        print(output)
        return 0 if "WALLY_SMP_PASS" in output and "WALLY_SMP_FAIL" not in output else 1
    build = work / f"rtl-{cores}-{mode}-{words}"
    if icache or local_reads:
        build = Path(str(build) + f"-i{int(icache)}-{iwords}-r{int(local_reads)}")
    if local_writes:
        build = Path(str(build) + "-w1")
    if dline != 1 or iline != 1:
        build = Path(str(build) + f"-dl{dline}-il{iline}")
    if forwarding:
        build = Path(str(build) + "-c2c1")
    if banks > 1:
        build = Path(str(build) + f"-b{banks}")
    if bursts:
        build = Path(str(build) + "-burst1")
    if mesi:
        build = Path(str(build) + "-mesi1")
    exe = build / "Vlinux_tb"
    metadata_path = build / "model.json"
    sources = sorted(p for p in (ROOT / "src").rglob("*.sv") if p.name != "cvw.sv")
    inputs = [ROOT / "src/cvw.sv", *sources, HERE / "linux_tb.sv", HERE / "sim_main.cpp",
              ROOT / "tests/multicore/dpi.cpp", ROOT / "testbench/common/bus_fault_guard.sv", ROOT / "config/deriv/multicore_linux/config.vh",
              ROOT / "config/multicore/schema.json", ROOT / "config/multicore/profiles.py",
              *sorted((ROOT / "config/shared").glob("*.vh"))]
    fingerprint = {
        "cores": cores, "cache_mode": mode, "cache_words": words, "savable": True, "effective_configuration": effective,
        "cache_line_words": dline, "icache_line_words": iline, "cache_to_cache": forwarding, "coherence_banks": banks, "cache_bursts": bursts, "mesi": mesi,
        "private_icache": icache, "icache_words": iwords, "local_dcache_reads": local_reads, "local_dcache_writes": local_writes,
        "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip(),
        "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
    }
    if args.reuse:
        if not exe.is_file() or not metadata_path.is_file():
            parser.error("No matching model metadata; build without --reuse first")
        model = json.loads(metadata_path.read_text())
        if model["inputs"] != fingerprint or model["binary_sha256"] != hashlib.sha256(exe.read_bytes()).hexdigest():
            parser.error("Compiled model differs from current sources/parameters; rebuild")
    else:
        command = [
            "verilator", "--cc", "--exe", "--build", "--assert", "--savable",
            "-CFLAGS", "-O3", "-MAKEFLAGS", "OPT_FAST=-O3", "-j", str(args.jobs),
            "--top-module", "linux_tb", *profiles.verilator_args(topology),
            "--Mdir", str(build), f"-I{ROOT / 'config/shared'}",
            f"-I{ROOT / 'config/deriv/multicore_linux'}", str(ROOT / "src/cvw.sv"),
            str(HERE / "linux_tb.sv"), *map(str, sources), str(HERE / "sim_main.cpp"),
            str(ROOT / "tests/multicore/dpi.cpp"), str(ROOT / "testbench/common/bus_fault_guard.sv"),
        ]
        with (work / "rtl-build.log").open("w") as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        model = {"inputs": fingerprint, "binary_sha256": hashlib.sha256(exe.read_bytes()).hexdigest()}
        metadata_path.write_text(json.dumps(model, indent=2) + "\n")
    if args.build_only:
        print(f"RTL model ready: {exe}", flush=True)
        return 0
    checkpoint = args.checkpoint.resolve() if args.checkpoint else work / f"{build.name}.checkpoint"
    checkpoint_meta = Path(str(checkpoint) + ".json")
    identity = {"model_sha256": model["binary_sha256"], "images": manifest["sha256"],
                "cores": cores, "cache_mode": mode, "cache_words": words,
                "cache_line_words": dline, "icache_line_words": iline, "cache_to_cache": forwarding, "coherence_banks": banks, "cache_bursts": bursts, "mesi": mesi,
                "private_icache": icache, "icache_words": iwords, "local_dcache_reads": local_reads, "local_dcache_writes": local_writes}
    if args.resume:
        if not checkpoint.is_file() or not checkpoint_meta.is_file() or json.loads(checkpoint_meta.read_text()) != identity:
            parser.error("Checkpoint missing or incompatible with this model/images")
    elif checkpoint.exists():
        parser.error("Checkpoint already exists: use --resume or a different --checkpoint path")
    else:
        checkpoint.parent.mkdir(parents=True, exist_ok=True)
        checkpoint_meta.write_text(json.dumps(identity, indent=2) + "\n")
    command = [str(exe), f"+ram={work / 'ram.memfile'}", f"+rom={work / 'boot.memfile'}",
               f"+cycles={args.cycles}", f"+checkpoint={checkpoint}", f"+interval={args.checkpoint_interval}"]
    if args.resume:
        command.append(f"+restore={checkpoint}")
    print(f"Running {mode}: {cores} harts, {words} words/cache. Log: {work / 'rtl.log'}", flush=True)
    with (work / "rtl.log").open("a" if args.resume else "w") as log:
        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        def stop(signum, _frame):
            if proc.poll() is None:
                proc.send_signal(signum)
        handlers = {sig: signal.signal(sig, stop) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            code = proc.wait()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    output = (work / "rtl.log").read_text(errors="replace")
    verdict = "PASS" if code == 0 and "WALLY_SMP_PASS" in output and "WALLY_SMP_FAIL" not in output else "INCOMPLETE" if code == 75 else "FAIL"
    result = {"verdict": verdict, "exit_code": code, **identity,
              "log_sha256": hashlib.sha256((work / "rtl.log").read_bytes()).hexdigest()}
    (work / "rtl-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{verdict}: RTL run exited {code}", flush=True)
    return code



if __name__ == "__main__":
    sys.exit(main())
