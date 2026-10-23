# ADR 0014: isolate multi-hart peripherals and scope single-hart corrections

Status: **proposed**; implemented and tested in the working tree based on
`multicore-support:67ec3d991`. Acceptance is pending review; passing tests do
not change this status.

## Context

Recommendation 2 of the [maintenance review](../experiments/2026-10-21-multicore-maintainability-review.md)
identified that bypassing the multicore memory fabric did not preserve the
single-hart peripheral implementation or no-bus clock/reset behavior.
Peripheral changes and LSU atomic metadata corrections need explicit scope.

## Proposed boundary

Keep the upstream-shaped `clint_apb` and `plic_apb` modules for NCORES=1.
Move the existing multi-hart implementations into `clint_multicore_apb` and
`plic_multicore_apb`; select them in `uncore` only for NCORES>1. Preserve the
`uncore.clint.clint` and `uncore.plic.plic` instance paths and existing SoC ports.
Retain the same core for all hart counts.

Apply these generic corrections explicitly to the single-hart modules:

- CLINT MSIP writes honor byte-zero PSTRB.
- PLIC decodes the full 28-bit relative address, preventing upper-address
  aliases. Unimplemented priorities/source banks read zero; source zero is
  never written. Reset defines Dout, and completion IDs are range checked.
- SoC HCLK/HRESETn are zero when BUS_SUPPORTED=0, matching upstream behavior.
- The cached LSU uncacheable path uses LSUAtomicM, which belongs to the
  selected request, instead of the CPU's AtomicM during a page-table walk.
  The cacheless path already uses LSUAtomicM in the parent revision.

Peripheral MMIO maps, timer clock, APB phases, interrupt arbitration and
memory-fabric selection are unchanged. Generic fixes are visible with one
hart; this proposal does not claim bit-for-bit upstream equivalence.

## Alternatives and costs

Keeping one parameterized peripheral implementation avoids duplicated logic
but retains a broad single-hart delta against upstream. Restoring upstream
byte-for-byte would preserve the known alias/strobe behavior and leave generic
fixes unaddressed. The proposed split makes upstream comparison and future
maintenance easier, at the cost of maintaining common fixes in two modules.
Differential tests compare corrected single-hart peripherals to the multicore
engines configured with one hart to catch drift.

## Verification and limits

The [compatibility record](../experiments/2026-10-21-singlecore-compatibility.md)
records upstream differential checks, intentional differences, no-bus outputs,
translated AMO/PTE updates, a negative mutation, and 1/2/3-hart regressions.
This is simulation evidence for the named profiles, not formal equivalence,
new Linux validation, FPGA timing or board verification.
