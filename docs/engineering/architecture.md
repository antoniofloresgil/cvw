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
| Multicore memory topology | [multicore_memory_system.sv](../../src/ebu/multicore_memory_system.sv): bypass, arbitration, optional caches/coherence banks and capability checks; per-hart requests/responses to one uncore AHB port |
| Buffered hart/bus timing | [Interface contract](interfaces/core-bus.md), [corebus_contract.sv](../../src/ebu/corebus_contract.sv): accepted metadata, delayed write payload, AMO ownership, retained SC and ERROR/reset lifetime; assertions are excluded from synthesis |
| Pipeline interfaces | [wallypipelinedcore.sv](../../src/wally/wallypipelinedcore.sv), [hazard.sv](../../src/hazard/hazard.sv): stage-aligned stall/flush coordination |
| Configuration | [cvw_t](../../src/cvw.sv), [shared derivations](../../config/shared/config-shared.vh), [struct initialization](../../config/shared/parameter-defs.vh), [derivative recipes](../../config/derivlist.txt) |
| Fetch, translation and memory arbitration | [ifu.sv](../../src/ifu/ifu.sv), [lsu.sv](../../src/lsu/lsu.sv), [hptw.sv](../../src/mmu/hptw.sv) |
| Instruction/data cache implementation | [src/cache](../../src/cache), instantiated through IFU/LSU; shared implementation code does not imply a coherent inter-hart cache |
| External bus and peripherals | [ebu.sv](../../src/ebu/ebu.sv), [uncore.sv](../../src/uncore/uncore.sv) |

In the working tree on `multicore-support:67ec3d991`, uncore selects the
upstream-shaped `clint_apb`/`plic_apb` for one hart, and the separate
`clint_multicore_apb`/`plic_multicore_apb` for multiple harts, retaining existing
instance paths. Generic peripheral corrections and no-bus clock/reset behavior
are scoped in proposed [ADR 0014](decisions/0014-single-hart-peripheral-isolation.md).
The cached LSU bus atomic flag follows LSUAtomicM so CPU AMO decode cannot tag
a walker PTE request. See the [compatibility record](experiments/2026-10-21-singlecore-compatibility.md)
for the executed checks and intentional upstream differences.

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

This `opensource-fpga-bitstream` checkout integrates `main:1d5677648`,
including the optional multicore implementation and official upstream
`89479dd09`. The FPGA wrapper keeps the default NCORES=1 topology.
`NCORES`, central inter-hart atomics and the optional unified physical cache
remain implemented as described in [ADR 0002](decisions/0002-shared-multicore-cache.md).
The main-side changes retain `HART_ID` propagation and the shared atomic
sideband. Walker-owned `LSUFpLoadStoreM` selects access size/store data while
`LSUAtomicM` suppresses atomic tagging for PTE accesses. The new `WaitM`
interface connects privileged decode to each core's hazard unit; it does not
introduce a shared stall between harts. See the
[integration record](experiments/2026-10-19-multicore-main-integration.md) for
verification of the combination. Do not apply the shared-cache or software
A/D assumptions to every base configuration. Multicore is already integrated into the main input; its historical
verification records retain their original source scope.

The open LiteDRAM integration from `opensource-fpga-bitstream:23ba9c2a7`
remains present alongside the imported multicore code. The shared clock,
service-CPU ownership and reset gating in `fpgaOpenSource` are unchanged;
its reset/clock/service-CPU contract is linked in the
[DDR3 record](experiments/open-ddr3-bringup.md). The
[2026-10-23 integration record](experiments/2026-10-23-open-fpga-main-integration.md)
distinguishes combined-source checks from hardware qualification.

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

## Optional MSI supplier path

`CACHE_TO_CACHE=1` copies an M owner directly to a writing requester; read
sharing forwards acknowledged memory-writeback beats, keeping S clean.
Default off, with unchanged single-core bypass and one global transaction.
See [ADR 0008](decisions/0008-cache-to-cache-supply.md).

## Independent coherence homes

`COHERENCE_BANKS` defaults to one. With multiple harts and private MSI, powers
of two greater than one select `ahbmsifabric`: independent address-home
controllers, fixed total private capacity, one blocking request per hart and
a shared AHB memory port. Cross-home LR/SC clearing and global AMO admission
retain atomic ordering. See [ADR 0009](decisions/0009-banked-coherence-transactions.md)
for mapping, invariants, limitations and the independent verification scope.

## Optional pipelined line transfers

`CACHE_BURSTS` enables `ahblineburst` for complete D fills/writebacks and
coherently clean instruction-line prefetch, without changing core SINGLE
requests. `ahbburstmux` retains a bank's memory grant through the line and
separates address/data ownership. Disabled operation keeps the existing port
bridge; one-core generate removes both. See
[ADR 0010](decisions/0010-pipelined-cache-line-bursts.md) for error recovery,
mixed-geometry IFU snooping and the bounded-grant contract.

## Optional clean-exclusive private data permission

`MESI=1` extends the private MSI topology with E. A successful data fill with
no matching peer gets E; a peer read downgrades E to S only on success. Local
ordinary E stores become M through the existing commit/invalidation sideband
when `LOCAL_DCACHE_WRITES` is enabled. Instruction copies do not count as D
sharers; stores still invalidate them. One and multiple address homes use the
same rules. `MESI=0` retains MSI; NCORES=1 strips coherence. See
[ADR 0011](decisions/0011-optional-mesi-exclusive-state.md) and the
[separate verification record](experiments/2026-10-20-mesi.md).

## Extracted memory subsystem boundary

The extraction based on `multicore-support:ce02cf1ad` follows
[ADR 0013](decisions/0013-multicore-memory-subsystem-boundary.md). The SoC's
`memory_system` instance owns all topology generates and cache/arbiter-local
signals. Its ports are the existing per-hart AHB vectors plus HATOMIC/SCFail
and the uncore AHB master interface. Clocks, reset synchronization, core
instances and interrupt/uncore wiring stay in `wallypipelinedsoc`.

No state or pipeline stage is added at this boundary. Public SoC parameters
and their defaults remain unchanged. Single-hart private-cache requests still
bypass coherence; explicitly requested SHARED_CACHE still operates with one
hart. Core and uncore verification probe paths remain stable. Internal memory
probes acquire the `memory_system` prefix, including the multicore testbench's
architectural write-back observer and traffic counters. See the
[extraction record](experiments/2026-10-21-memory-subsystem-extraction.md) for
verification scope; this is not a resolution of the other maintenance findings.
