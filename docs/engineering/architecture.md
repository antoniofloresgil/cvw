# Architecture pointers and checked constraints

Initially checked against `main` at `3585ff04e` on 2026-10-18; the subsequent
[upstream integration](experiments/2026-10-18-upstream-integration.md) retains
the ownership mechanisms below. The overview already lives
in [CLAUDE.md](../../CLAUDE.md) and [README.md](../../README.md); this document
records source boundaries and interactions that should guide future changes.

## Source boundaries

| Concern | Implementation / existing explanation |
| --- | --- |
| SoC wiring | [wallypipelinedsoc.sv](../../src/wally/wallypipelinedsoc.sv): this revision instantiates one `core` and optional uncore |
| Pipeline interfaces | [wallypipelinedcore.sv](../../src/wally/wallypipelinedcore.sv), [hazard.sv](../../src/hazard/hazard.sv): stage-aligned stall/flush coordination |
| Configuration | [cvw_t](../../src/cvw.sv), [shared derivations](../../config/shared/config-shared.vh), [struct initialization](../../config/shared/parameter-defs.vh), [derivative recipes](../../config/derivlist.txt) |
| Fetch, translation and memory arbitration | [ifu.sv](../../src/ifu/ifu.sv), [lsu.sv](../../src/lsu/lsu.sv), [hptw.sv](../../src/mmu/hptw.sv) |
| Instruction/data cache implementation | [src/cache](../../src/cache), instantiated through IFU/LSU; shared implementation code does not imply a coherent inter-hart cache |
| External bus and peripherals | [ebu.sv](../../src/ebu/ebu.sv), [uncore.sv](../../src/uncore/uncore.sv) |

## Walker / memory-access ownership

The existing [HPTW sequencing design](../hptw_sequencing_design.md) explains
the motivation and invariants for issues #1538/#1766. Its original branch
header and verification plan are historical, not proof of a new test run.
The current RTL contains the corresponding mechanisms:

- LSU distinguishes `MemAccessInFlightM` from `MemAccessDoneM` and holds a
  performed access's result across stalls. `HoldAccessM` prevents reissuing it.
- HPTW defers instruction-side requests during an in-flight LSU access,
  records DTLB/ITLB pending requests and serves the DTLB first. It asserts
  `HPTWStall` through FAULT and restores the LSU address selection before
  resumption; trap/flush overrides remain coordinated by the hazard unit.
- IFU holds walker fault indications until the fetch advances, avoiding a
  lost pulse when downstream stages stall.

Changes here must preserve ownership of the LSU datapath, completed accesses
and fault delivery together. Consult the original design's directed overlap
matrix; changing only a stall expression can affect all three interfaces.
No HPTW regression was run as part of establishing these notes.

The subsequent integration adds walker ownership of `LSUFpLoadStoreM` in
`hptw.sv`, passed through `lsu.sv`: the walker clears the FP-data selection
while accessing PTEs. The LSU uses this selection for memory size, store data
and endian handling. This keeps an overlapping FP store from substituting
its data for a PTE update. The integration's `fpADUpdate` test passed on
`rv64gc`; that is not complete verification of every FLEN/XLEN combination.

## Branch-specific architecture

`NCORES`, central inter-hart atomics and the optional unified physical cache
exist at `multicore-support:f655debae`, **not in this main revision**. See
[ADR 0002](decisions/0002-shared-multicore-cache.md) and its pinned sources;
do not apply its cache or software A/D assumptions to every base configuration.

The open LiteDRAM integration is separately scoped to
`opensource-fpga-bitstream:23ba9c2a7`; its reset/clock/service-CPU contract is
linked in the [DDR3 record](experiments/open-ddr3-bringup.md).
