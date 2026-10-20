# Architecture pointers and checked constraints

Initially checked against `main` at `3585ff04e` on 2026-10-18; the subsequent
[upstream integration](experiments/2026-10-18-upstream-integration.md) retains
the ownership mechanisms below. The overview already lives
in [CLAUDE.md](../../CLAUDE.md) and [README.md](../../README.md); this document
records source boundaries and interactions that should guide future changes.

## Source boundaries

| Concern | Implementation / existing explanation |
| --- | --- |
| SoC wiring | [wallypipelinedsoc.sv](../../src/wally/wallypipelinedsoc.sv): hart zero is `core`, additional harts are `harts[h].core`; one optional uncore is shared |
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

This `multicore-support` checkout combines `f655debae` with `main:82d0b80f7`.
`NCORES`, central inter-hart atomics and the optional unified physical cache
remain implemented as described in [ADR 0002](decisions/0002-shared-multicore-cache.md).
The main-side changes retain `HART_ID` propagation and the shared atomic
sideband. Walker-owned `LSUFpLoadStoreM` selects access size/store data while
`LSUAtomicM` suppresses atomic tagging for PTE accesses. The new `WaitM`
interface connects privileged decode to each core's hazard unit; it does not
introduce a shared stall between harts. See the
[integration record](experiments/2026-10-19-multicore-main-integration.md) for
verification of the combination. Do not apply the shared-cache or software
A/D assumptions to every base configuration. Main itself still lacks the
multicore implementation until this feature branch is merged back.

The open LiteDRAM integration is separately scoped to
`opensource-fpga-bitstream:23ba9c2a7`; its reset/clock/service-CPU contract is
linked in the [DDR3 record](experiments/open-ddr3-bringup.md).

## Optional private MSI data-cache mode

The working tree based on `35cb2093b` adds PRIVATE_DCACHE and
PRIVATE_DCACHE_WORDS SoC parameters; NCORES still defaults to 1. Effective
MSI is `NCORES > 1 && PRIVATE_DCACHE`. With one hart, generate removes MSI
and retains the original core, bus latency and local atomic monitor.

`ahbmulticore` now exports HOWNER, using the granted address owner before
acceptance and the held owner during the data phase. `ahbmsicache` latches
that owner with the accepted address and samples write data/strobes in the
following data phase. In the default blocking mode every access passes this
ordering point. Optional concurrent read paths are described below; all stores
still remain visible to reservation invalidation and AMO exclusion.

Only data requests allocate; HPROT[0]=0 instruction reads snoop even the
requesting hart's modified D-cache bank before fetching from memory. Dirty
replacement/intervention writes back a full word and changes ownership only
after success. Cache fills and byte merges preserve the rest of the word.
MMIO/ROM bypass allocation. Existing legacy IFU/LSU caches remain disabled in
the multicore_msi derivative. Shared-cache and effective MSI modes cannot be
combined. See [ADR 0003](decisions/0003-private-msi-data-caches.md) for the
blocking MSI transitions, restrictions and error/reset contract, and the
[MSI result record](experiments/2026-10-19-private-msi.md) for executed checks.

## Optional private instruction banks and concurrent reads

The stage-5 changes based on `8ac2d4d6b` add PRIVATE_ICACHE,
PRIVATE_ICACHE_WORDS and LOCAL_DCACHE_READS, all disabled by default except
capacity (256). They require effective MSI; with NCORES=1 all are removed.
`ahbmulticore` holds one physically tagged I bank per hart, and probes private
D banks through CacheReadAddr/CacheReadHit/CacheReadData. Independent I hits
and ordinary D read hits can complete together or during a global read miss.
Stores, atomics and misses retain a single global ordering point. Local reads
wait for in-flight writes to the same physical word; D reads also wait for
AMO exclusion to end. The independent-word refinement is specified in
[ADR 0005](decisions/0005-independent-read-write-overlap.md).
Successful writes invalidate matching I words in all harts; failed fills do
not allocate. See [ADR 0004](decisions/0004-private-instruction-caches.md)
for the invalidation/fill ordering and external-DMA limits.

## Optional local modified stores

LOCAL_DCACHE_WRITES adds CacheWriteHit and per-hart CacheWriteCommit/Data/Strb
between arbiter and MSI banks. Only ordinary M hits use it; each commit still
invalidates reservations and I words centrally. Independent commits can
complete in parallel, but a global access to the same word, its global owner
or AMO exclusion blocks the local store. Coincident LR replacement and I fills
have explicit priority. See [ADR 0006](decisions/0006-local-modified-stores.md).

## Multiword private line extension

The optional private caches expose independent `PRIVATE_DCACHE_LINE_WORDS`
and `PRIVATE_ICACHE_LINE_WORDS` (default 1). Capacity parameters remain total
AHB words. D tags/MSI state and I tags/validity are per line; selected word
indices address flat data arrays. D fills stage all words before installation;
dirty eviction/intervention retains M until the entire writeback succeeds.
I fills retain global ownership across individually snooped word transactions
and expose a valid line only after the final successful response. All transfers
remain AHB SINGLE words; MMIO bypass retains its original size.

Local access guards cover the larger I/D line to protect ongoing interventions
and instruction refills, including transfer gaps. LR/SC retains its word
reservation granule and AMO retains global exclusion. Entire I lines are
invalidated on successful global/local stores. See
[ADR 0007](decisions/0007-multiword-private-cache-lines.md) for ordering, error
semantics and the verification record; older Linux models remain separate.
