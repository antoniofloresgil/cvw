# Coupling with upstream

Where this fork changes files that openhwgroup/cvw owns, why, and what could be done about it.
It is the inventory for the clean-up that follows the microcontroller (ADR 0022), measured against
upstream `0daa3c38f` (the last upstream commit merged into `main`) on `open-asic-flow`.

Method: `git diff --numstat --diff-filter=M 0daa3c38f open-asic-flow -- <dir>` lists the upstream files we
edit; `--diff-filter=A` lists the files we only add. Added files do not conflict in a merge, so the
cost of staying close to upstream is the edited files, not the 29,000 added lines.

## Summary

| | files | lines |
|---|---|---|
| RTL in `src/` edited | 24 | +648 -271 |
| RTL in `src/` added (`debug/`, `ebu/`, `uncore/mcu/`, ...) | 32 | |
| Configuration (`config/`) edited | 10 | about 13 lines each, plus `derivlist.txt` +194 |
| Testbench, tools and scripts edited | 12 | |

Everything the fork adds to the core is behind a configuration parameter whose default is off
(`DEBUG_SUPPORTED`, `TRACE_SUPPORTED`, `MCU_SUPPORTED`, `SSCOFPMF_SUPPORTED`, `SMCNTRPMF_SUPPORTED`,
`SMCDELEG_SUPPORTED`, `EXT_IO_SUPPORTED`, `NCORES`, `SHARED_ATOMICS`), so the upstream configurations
behave as before.

## Edited upstream files, by feature

| Feature | Edited upstream files | Lines | Nature of the edit |
|---|---|---|---|
| Debug, triggers, trace | `wallypipelinedsoc.sv`, `privileged.sv`, `wallypipelinedcore.sv`, `lsu.sv`, `ifu.sv`, `mmu.sv`, `pmachecker.sv`, `testbench.sv` | about 330 | ports and instances that steer the trap and return paths; logic is in `src/debug/` |
| Counter extensions (Sscofpmf, Smcntrpmf, Smcdeleg) | `csrc.sv`, `csrm.sv`, `csrs.sv`, `csri.sv`, `csr.sv`, `trap.sv`, `privileged.sv` | about 300 | wider `MIP/MIE/MIDELEG` (12 to 14 bits), new CSRs, event and control logic already moved out to `pmuevents.sv` and `pmucountercontrol.sv` |
| Multicore, shared atomics | `wallypipelinedsoc.sv`, `wallypipelinedcore.sv`, `ebu.sv`, `lsu.sv`, `atomic.sv`, `plic_apb.sv`, `uncore.sv` | about 270 | `HART_ID`, `NCORES` ports, atomic sideband; engines in `src/ebu/` and `*_multicore_apb.sv` |
| MCU peripherals | `uncore.sv`, `plic_apb.sv`, `plic_multicore_apb.sv`, `gpio_apb.sv`, `adrdecs.sv`, `pmachecker.sv`, `cvw.sv`, `parameter-defs.vh`, six `config.vh` | about 120 | one APB region, four PLIC sources, `iof1oen` on the GPIO; peripherals in `src/uncore/mcu/` |
| I/O window in the PMA | `pmachecker.sv`, `cvw.sv`, `testbench.sv`, `config-shared.vh` | about 40 | `EXT_IO_*` parameters |
| Generic fixes | `lzc.sv`, `popcnt.sv`, `rom1p1r.sv`, `clint_apb.sv` | about 70 | not tied to a feature; see below |
| Tools and flow | `setup.sh`, `bin/regression-wally`, `bin/lint-wally`, `bin/wally-*-install.sh`, `.pre-commit-config.yaml`, `sim/verilator/Makefile`, `fpga/` | about 400 | fork tooling |

## What stays coupled

A feature that needs a new signal in the pipeline needs a port in each module on the way. Debug Mode
steers `privileged.sv`'s trap and return paths; the counter extensions widen the interrupt vectors;
the multicore work gives the core a `HART_ID` and an atomic sideband. This is the cost of adding the
feature to the core and no wrapper removes it. What can be done is to keep each edit small, inside a
`generate if` on the feature's parameter, with the logic in a file of our own.

## Candidates, in the order of the benefit

1. **Generic fixes as upstream pull requests.** `lzc.sv` and `popcnt.sv` (balanced trees; a priority loop
   and a linear chain are as deep as the width in Yosys), `rom1p1r.sv` and `clint_apb.sv` (`PSTRB` on
   `MSIP`) do not depend on any fork feature. Merged upstream they leave our diff and cannot conflict
   again. Each is a small branch from `upstream/main`.
2. **Refine the edits in `csrc.sv`, `csri.sv`, `csrm.sv`.** The counter logic already lives in
   `pmuevents.sv` and `pmucountercontrol.sv`; what remains in `csrc.sv` is the read mux and the write
   enables. Moving the read mux of the new CSRs into `pmucountercontrol.sv` would cut `csrc.sv` to a few
   lines. Widening `MIP/MIE/MIDELEG` cannot be avoided.
3. **`wallypipelinedsoc.sv` (+138 -22).** It carries the debug module, the trace, the watchdog reset and
   the multicore arbitration inline. A `wallypipelinedsoc` that only instantiates a fork-owned
   `soc_extras` (debug module, arbiter, reset logic) would leave upstream's file with the instance and
   the new ports. The cost is an interface of about 40 signals.
4. **Tooling in its own files.** `setup.sh` (OSS CAD Suite paths) and the install scripts could source a
   fork file (`setup-fork.sh`) so that upstream's scripts stay untouched.
5. **Testbench hooks.** `testbench.sv` (+26) holds the EXT_IO and trace hooks; they could move to
   `testbench/common/` modules instantiated from one line.

## Rules for new fork code

- New hardware goes in its own file under `src/<feature>/`; an edit to an upstream file is a port, an
  instance or a `generate if` on the feature's parameter, nothing more.
- A feature parameter defaults to 0 in every configuration, and the configuration comment contains no
  semicolon (`derivgen.pl` truncates at it).
- A new port of a module that upstream testbenches or `tests/multicore/` instantiate must be tied off
  there too, since Verilator lint makes a missing port fatal.
- New upstream configurations need the fork's parameters added (`rv32imcb` did).
- Merges follow `upstream -> main -> branches`; conflicts are resolved once, in `main`.
