#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check Wally's instruction trace against the E-Trace reference flow (docs/trace.md).

The reference flow lives in the specification's repository, which is not part of Wally:
    git clone https://github.com/riscv-non-isa/riscv-trace-spec.git
Point ETRACE_SPEC (or --spec) at the clone.  Its models are Python with the standard library
only, and its decoder reads the program with riscv64-unknown-elf-objdump from $RISCV.

Given the CSV of the instruction trace interface that testbench.sv writes with
+EtraceCsv=<file> (testbench/common/etracedump.sv), this script
  1. encodes it with the reference encoder (encoder_model.py), which validates the interface,
  2. decodes the packets with the reference decoder (decoder_model.py), and checks that the
     program counters it reconstructs are the ones that the hart retired, in order.
With --rtl-packets it also checks that the packets of Wally's encoder (src/debug/etraceencoder.sv),
as the program read them back from the RAM sink (src/debug/etracesink.sv; the testbench writes
them with +EtracePackets=: hex bytes, in order), are those of the reference, byte for byte.

    etracecheck.py --csv trace.csv --elf program.elf --xlen 64
"""

import argparse
import csv
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# The configuration of Wally's encoder (docs/trace.md)
STATIC_CONFIG = """[Required Attributes]
arch_p=0
bpred_size_p=0
cache_size_p=0
call_counter_size_p=0
context_width_p=0
time_width_p=0
ecause_width_p=5
f0s_width_p=0
iaddress_lsb_p=1
iaddress_width_p={xlen}
nocontext_p=1
notime_p=1
privilege_width_p=2
return_stack_size_p=0
sijump_p=0

[Other Recommended Attributes]
ctype_width_p=2
ilastsize_width_p=1
itype_width_p=3
iretire_width_p=1
retires_p=1
taken_branches_p=1
impdef_width_p=1
"""

USER_CONFIG = """[required]
file-stem = {stem}
debug-flags = 0
ip-version = 6
object-files = {elf}

[codec]
cycle-accurate = false
resync-max = {resync_max}
full-address = false
implicit-except = false
si-jump = false
implicit-return = false
branch-prediction = false
jump-target-cache = false

[flags]
print-set-pc = false
use-rv32-isa = {rv32}
"""


def run(cmd, cwd, env, what):
    """Run a reference model; on failure print its output and stop."""
    result = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.stdout.write(result.stdout[-4000:] + result.stderr[-4000:])
        sys.exit(f"FAIL: {what} (exit code {result.returncode})")
    return result.stdout


def split_packets(raw):
    """Split a te_inst byte stream into packets: a header byte, whose low 5 bits are the payload length.
    Bytes 0 between packets are idle bytes (the RAM sink fills its last word with them)."""
    packets, i = [], 0
    while i < len(raw):
        if raw[i] == 0:
            i += 1
            continue
        end = i + 1 + (raw[i] & 0x1F)
        packets.append(raw[i:end])
        i = end
    return packets


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", required=True, help="instruction trace interface CSV (+EtraceCsv=)")
    parser.add_argument("--elf", required=True, help="the program that ran")
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--resync-max", type=int, default=0, help="resync every 2^(n+4) packets")
    parser.add_argument("--rtl-packets", help="the trace read back from the RAM sink (+EtracePackets=), to compare")
    parser.add_argument("--spec", default=os.environ.get("ETRACE_SPEC"), help="riscv-trace-spec clone")
    parser.add_argument("--keep", help="keep the work files in this directory")
    args = parser.parse_args()

    if not args.spec:
        sys.exit("SKIP: set ETRACE_SPEC (or --spec) to a clone of riscv-trace-spec")
    scripts = Path(args.spec) / "referenceFlow" / "scripts"
    if not (scripts / "encoder_model.py").exists():
        sys.exit(f"FAIL: no referenceFlow/scripts/encoder_model.py under {args.spec}")
    # The objdump of $RISCV, else the one on the PATH
    objdump = str(Path(os.environ["RISCV"]) / "bin" / "riscv64-unknown-elf-objdump") if os.environ.get("RISCV") \
        else shutil.which("riscv64-unknown-elf-objdump")
    if not objdump or not Path(objdump).exists():
        sys.exit("FAIL: no riscv64-unknown-elf-objdump: set RISCV")

    work = Path(args.keep) if args.keep else Path(tempfile.mkdtemp(prefix="etrace-"))
    work.mkdir(parents=True, exist_ok=True)

    # The reference decoder runs $RISCV_TOOLCHAIN/bin/riscv64-unknown-elf-objdump.  It cannot parse
    # data in a code section (".word" lines), so the program must have none (docs/trace.md).
    env = dict(os.environ, RISCV_TOOLCHAIN=str(Path(objdump).resolve().parent.parent))
    stem = "wally"
    (work / "wally.scf").write_text(STATIC_CONFIG.format(xlen=args.xlen))
    (work / "wally.ucf").write_text(USER_CONFIG.format(
        stem=stem, elf=Path(args.elf).resolve(), resync_max=args.resync_max,
        rv32="true" if args.xlen == 32 else "false"))
    shutil.copyfile(args.csv, work / f"{stem}_input")

    # The program counters the hart retired, in order: the expected decoder output
    with open(args.csv, newline="") as fd:
        retired = [row["iaddr_0"] for row in csv.DictReader(fd) if row["iretire_0"] != "0"]
    (work / "expected").write_text("".join(f"{int(a, 16):x}\n" for a in retired))

    # 1. The reference encoder
    run([sys.executable, scripts / "encoder_model.py", "-c", "wally.scf", "-u", "wally.ucf"],
        work, env, "the reference encoder rejected the trace")
    # The reference names its outputs after its input, <file-stem>_input
    out = f"{stem}_input"
    packets = sum(1 for _ in open(work / f"{out}.te_inst")) - 1
    print(f"reference encoder: {len(retired)} instructions, {packets} packets")

    # 2. The reference decoder, on the reference packets
    run([sys.executable, scripts / "decoder_model.py", "-c", "wally.scf", "-u", "wally.ucf",
         "-i", f"{out}.te_inst_raw", "--expected", "expected"],
        work, env, "the reference decoder did not reconstruct the retired program counters")
    decoded = sum(1 for _ in open(work / f"{out}.decoder.trace"))
    if decoded != len(retired):
        sys.exit(f"FAIL: the decoder reconstructed {decoded} instructions, the hart retired {len(retired)}")
    print(f"reference decoder: the {decoded} program counters match")

    # 3. Wally's encoder, packet by packet
    if args.rtl_packets:
        ours = split_packets(bytes.fromhex("".join(Path(args.rtl_packets).read_text().split())))
        reference = split_packets((work / f"{out}.te_inst_raw").read_bytes())
        for n, (a, b) in enumerate(zip(ours, reference)):
            if a != b:
                sys.exit(f"FAIL: Wally's packet {n} is {a.hex()}, the reference's is {b.hex()} "
                         f"(line {n + 2} of {out}.te_inst with --keep)")
        if len(ours) != len(reference):
            sys.exit(f"FAIL: Wally's encoder sent {len(ours)} packets, the reference {len(reference)}")
        print(f"Wally's encoder: {len(ours)} packets, {sum(map(len, ours))} bytes, equal to the reference")

    if not args.keep:
        shutil.rmtree(work)
    print("PASS")


if __name__ == "__main__":
    main()
