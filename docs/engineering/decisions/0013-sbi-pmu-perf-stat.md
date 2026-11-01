# ADR 0013: Expose synthesizable Wally counters through SBI PMU

Status: **proposed**, implemented on `riscv-pmu-counters`, based on
`main:82d0b80f7d1471f224fc5a8fc307d75f5eb26f53`. Date: 2026-10-20.
The user selected counting with `perf stat`; overflow sampling is later work.

## Context and decision

Wally already implements synthesizable 64-bit machine counters, Zicntr/Zihpm
read-only aliases, RV32 high halves, counter-enable permissions and inhibition.
The additional counters have fixed event sources: mhpmevent=0 disables the
source and a nonzero value enables it. RISC-V leaves event encodings platform
specific, so a programmable crossbar is not required to expose these counters.
The missing integration is an accurate OpenSBI event-to-counter map and Linux
PMU/perf configuration, with hardware/software end-to-end verification.

Retain the fixed-function layout and existing events 3-24. Add counter 25 for
retired conditional branches, jumps and returns, and counter 26 for mispredicted
retired control transfers. OR the overlapping Jump/Return class bits so a return
counts once. These aggregates avoid reporting conditional-only branches as the
standard Linux branches event, or nonbranch class mispredictions as branch-misses.
Counters 27-31 remain without event sources. Existing coverage expectations are
updated for the two newly populated slots.

Generate `wally-pmu.dtsi` from `linux/pmu/events.py`. Standard cycles and
instructions use counters 0 and 2. Generic cache references/misses use all
L1D accesses/misses, and explicit L1I read events use counters 16/17. Do not
advertise load-only or store-only L1D events: the current signals do not
separate them. Raw event n is eligible only on fixed counter n, for 3-26.

## Interfaces, compatibility and validation

Include the map in the seven rv64gc-derived board DTBs, which implement 32
counters. For other configurations, regenerate with the matching `--counters`
and check the underlying cache/event support. Old firmware/bitstreams without
events 25/26 must not use the new branch-event bindings. No existing event ID
changes. The generator omits counters above the configured count.

Enable PERF_EVENTS/RISCV_PMU_SBI in the kernel and select Buildroot's current
LINUX_TOOLS_PERF package. Standard OpenSBI generic platform support consumes
the bindings; no private SBI extension or kernel driver fork is introduced.
The fixed mapping may constrain event groups; multiple aliases of one counter
cannot run simultaneously. Counts include all privilege modes. This first
version does not advertise Sscofpmf, overflow IRQs or privilege filtering, so
perf record and :u/:k filtering are outside scope.

Directed RV32/RV64 tests exercise permissions, enable/inhibit, fixed events and
64-bit rollover, including reduced counter counts. Native full-core coverage
and a fresh single-core Linux test exercise retirement and SBI PMU/perf. The
Linux init first checks perf_event_open start/stop/read, then runs the actual
statically linked perf stat executable. It never infers hardware correctness
from QEMU event semantics. See the [experiment](../experiments/2026-10-20-sbi-pmu.md)
for observed verdicts and missing evidence.

Counters are flip-flops/adders in `src/privileged/csrc.sv`, outside simulation
only code. They are available after synthesis when the selected configuration
implements them. FPGA access requires the matching bitstream, DTB, OpenSBI
and kernel; no synthesized area/timing, board boot or FPGA perf verdict has
been established by RTL simulation. Multicore remains a separate branch and
its private/coherence-cache events are not wired by this change.

## Primary references

- [RISC-V Zicntr/Zihpm](https://docs.riscv.org/reference/isa/unpriv/counters.html)
- [Machine counters and inhibition](https://docs.riscv.org/reference/isa/priv/machine.html)
- [OpenSBI 1.7 PMU device-tree bindings](https://github.com/riscv-software-src/opensbi/blob/v1.7/docs/pmu_support.md)
- [Linux SBI PMU driver](https://github.com/torvalds/linux/blob/v6.19/drivers/perf/riscv_pmu_sbi.c)
