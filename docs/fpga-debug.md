# JTAG debug and E-Trace on the Nexys Video (Vivado)

`fpganexysvideodbg` (`config/derivlist.txt`) adds the JTAG debug port (`DEBUG_SUPPORTED`, `docs/debug.md`) and the
E-Trace instruction trace with its RAM sink (`TRACE_SUPPORTED`, `docs/trace.md`) to `fpganexysvideopmu`. The debug
port needs no extra pins or cables: the DTM's `dtmcs` and `dmi` registers are the FPGA's own TAP's USER3 and USER4
registers (BSCANE2 in `fpga/src/fpgaTopNexysA7.sv`, the BSCAN mode of `src/debug/dtm.sv`), reached through the board's
USB programming port, the same one openFPGALoader uses. `fpga/constraints/bscan.xdc` constrains the BSCANE2 TCK.

```bash
cd fpga/generator && make nexysvideo VIVADOCONFIG=fpganexysvideodbg
openFPGALoader -b nexysVideo <bitstream>
```

The default implementation strategy misses 20 MHz by 3.6 ns on the HPTW, TLB, D-cache and AMO path with this
configuration; `wally.tcl` uses `Performance_ExplorePostRoutePhysOpt` for any configuration with `DEBUG_SUPPORTED`,
which closes it (WNS +0.11 ns, 2026-11-23).

## Tools (`fpga/debug/`)

- `openocd-nexysvideo.cfg`: OpenOCD 0.12 through the FT2232's channel B and the XC7A200T's TAP. Let openFPGALoader
  finish before starting OpenOCD: both hold the same port.
- `debug-check.tcl`: `openocd -f openocd-nexysvideo.cfg -f debug-check.tcl` while Linux runs. Halts the hart, single-steps
  it, reads memory through the program buffer and through System Bus Access and compares them, and resumes;
  `SUCCESS` and Linux still alive afterwards (2026-11-23).
- `etrace-capture.tcl` and `etrace-board.sh <vmlinux> [out dir] [user program ...]`: trace hart 0 for 0.2 s into the
  RAM sink through System Bus Access, then decode the packets with `testbench/debug/etrace/etracedecode.py` and print
  the functions the program counters fall in. Linux patches its own code at boot (alternatives, static keys), so the
  script reads the running kernel's `.text` back through System Bus Access (about 40 s) and decodes against that copy;
  give the ELFs of user programs the trace runs through. On 2026-11-23 a trace of a user workload decoded 90,529 program
  counters (1024 words, no overflow).

OpenOCD's Tcl computes with signed 64-bit integers: write address arithmetic as `[expr {$a + 4}]` and mask shifted
values of registers whose top bit may be set (`misa`).
