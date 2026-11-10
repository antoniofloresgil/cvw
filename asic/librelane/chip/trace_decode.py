#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Decodes the instruction trace that zephyr/trace prints when built with FPGA_DUMP=1 (the chip on the FPGA has no JTAG).

    uart_load.py /dev/ttyUSB1 zephyr/build-fpga-trace/zephyr/zephyr.bin | tee trace.log
    trace_decode.py trace.log zephyr/build-fpga-trace/zephyr/zephyr.elf

The log has "trace bytes N" and N/4 lines "T 0123abcd" (one little-endian word of the sink's buffer each).  The packets are decoded
against the ELF with testbench/debug/etrace/etracedecode.py and the path is checked as chipsim's zephyr_trace test does: it goes
through the workload, the semaphore calls, at least six context switches and the timer's interrupt handler.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(os.environ.get("WALLY", Path(__file__).resolve().parents[3])) / "testbench/debug/etrace"))
from etracedecode import decode, read_program


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    log, elf = sys.argv[1:]
    text = Path(log).read_text(errors="replace")
    words = re.findall(r"^T ([0-9a-f]{8})\s*$", text, re.M)
    m = re.search(r"^trace bytes (\d+)", text, re.M)
    if not m or "trace dumped" not in text:
        sys.exit("the log has no complete dump (trace bytes, T lines, trace dumped): was the image built with FPGA_DUMP=1?")
    printed = int(m.group(1))
    trace = b"".join(int(w, 16).to_bytes(4, "little") for w in words)
    if len(trace) != printed // 4 * 4 or not trace:
        sys.exit(f"{len(words)} words in the log, the program printed {printed} bytes")
    if trace[:2] != b"\x41\x1f":
        sys.exit(f"the trace starts with {trace[:2].hex()}, not a support packet")
    pcs = decode(trace, read_program(elf, 32), 32)
    print(f"trace: {len(trace)} bytes, {len(pcs)} instructions")

    symbols = {}
    for line in subprocess.run(["riscv64-unknown-elf-nm", "-S", elf], check=True, capture_output=True, text=True).stdout.splitlines():
        f = line.split()
        if len(f) == 4:
            symbols[f[3]] = (int(f[0], 16), int(f[1], 16))
        elif len(f) == 3:
            symbols[f[2]] = (int(f[0], 16), 0)

    def entered(name):
        start, size = symbols[name]
        return [i for i, pc in enumerate(pcs) if start <= pc < start + max(size, 1)]

    switches = [i for i, pc in enumerate(pcs) if pc == symbols["z_riscv_switch"][0]]
    isr = entered("timer_isr")
    checks = [("the workload", bool(entered("traced_work"))), ("the worker thread", bool(entered("worker"))),
              ("the semaphore calls", bool(entered("z_impl_k_sem_give") and entered("z_impl_k_sem_take"))),
              (f"{len(switches)} context switches (at least 6)", len(switches) >= 6),
              ("the timer's interrupt handler", bool(isr)),
              ("the timer interrupt after the three round trips", bool(isr and len(switches) > 5 and isr[0] > switches[5]))]
    for what, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {what}")
    sys.exit(0 if all(ok for _, ok in checks) else 1)


if __name__ == "__main__":
    main()
