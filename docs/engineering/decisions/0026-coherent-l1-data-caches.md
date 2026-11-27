# 0026. Coherent L1 data caches

Status: **accepted** (2026-11-25). Applies to the core's data cache (`src/cache`), the LSU (`src/lsu/lsu.sv`,
`lrsc.sv`) and a new coherence controller in the SoC's multicore memory system (`src/ebu`). Supersedes, for cached
SMP, the private caches in the fabric ([ADR 0025](0025-multicore-caches-in-block-ram.md)), which stay as an option.

## Context

The multicore SoC keeps each hart's caches in the fabric, on the far side of the core's AHB port, and turns the core's
own caches off. On the Nexys Video (2026-11-25, two harts, 8 KiB private caches, 20 MHz) a load that hits the private
cache costs about 70 cycles in a five-instruction loop, against about 75-87 when it misses to DDR3; an empty loop with
a counter on the stack costs 99 cycles an iteration. Every instruction fetch and every load and store is a separate
AHB transaction of about 11 cycles, hit or miss, and Linux SMP needs 95 s to reach `/init`. No fabric optimization
removes a bus crossing per access: the caches must be the core's L1.

Wally's D-cache (`cache.sv`, `cachefsm.sv`, `cacheway.sv`) is a write-back cache with valid and dirty bits in flip-flops,
tags and data in single-port RAMs read one cycle after the address, and a finite-state machine that already writes back
a single line and clears its dirty or valid bit (the CMO paths `cbo.clean` and `cbo.flush`). The LSU and the IFU share
one AHB master (`ebu.sv`, `HPROT[0]` tells a data access from a fetch).

## Decision

### 1. Only the D-cache is coherent

The I-cache is unchanged. RISC-V does not require instruction fetches to see other harts' stores before a `fence.i`,
and Wally's `fence.i` already writes the hart's own D-cache back (`FlushDCacheM`). An I-cache refill (an AHB read with
`HPROT[0] = 0` to cacheable memory) is nevertheless made coherent by the controller, which snoops the *other* harts'
D-caches before the read reaches memory, so a remote `fence.i` sees data that is still dirty in the writer's cache.

### 2. Line states: MSI with E, in the existing bits plus one

| State | Valid | Writable (new) | Dirty |
|---|---|---|---|
| I | 0 | - | - |
| S | 1 | 0 | 0 |
| E | 1 | 1 | 0 |
| M | 1 | 1 | 1 |

A store, an AMO or an LR needs a writable line (LR acquires write permission so that the SC that follows does not
need an upgrade the other hart can race). A refill for a load is E when no other cache held the line, S otherwise.

### 3. One coherent transaction at a time

The controller serializes coherent transactions: a D-cache acquire, a D-cache flush (`fence.i`), or an I-cache refill.
A transaction holds the controller's single slot from grant to release. Within it:

- the controller snoops every *other* hart's D-cache, in parallel: invalidate for a write acquire, downgrade to S
  otherwise;
- dirty data returned by a snoop is written to memory by the controller before the grant;
- the requester then performs its own AHB transfers (victim write-back, line fetch) as today, holding the slot, and
  releases it when its operation completes.

A hart that holds the slot is never snooped (no other transaction runs). This removes the classical races of
snoop-based protocols: a snoop cannot meet a victim being written back, a line being filled, or a flush in progress.
An I-cache refill of hart `c` is admitted when the slot is free *or held by hart `c`'s D-cache*, since the two share
one AHB master and the D-cache's transfers may wait behind the refill; the refill snoops only other harts, none of
which holds the slot. Uncacheable accesses and bursts not part of a coherent transaction are routed as today.

### 4. The cache answers snoops without its AHB port

A snoop's dirty line returns on a sideband (the whole line, `LINELEN` bits, in the cycle of the acknowledge), not on
the hart's AHB master: that master may be occupied by an I-cache refill waiting for the very transaction that sent the
snoop. Snoops are therefore always answered in bounded time.

### 5. Interface (per hart)

| Signal | Direction | Meaning |
|---|---|---|
| `CohAcqReq`, `CohAcqWrite`, `CohAcqAdr` | core → controller | acquire the line (write permission if `CohAcqWrite`); held until granted or withdrawn |
| `CohAcqFlush` | core → controller | acquire the slot for a whole-cache flush |
| `CohGnt`, `CohGntExcl` | controller → core | one-cycle grant, only while `CohAcqReq`; `CohGntExcl`: no other cache holds the line |
| `CohRel` | core → controller | one-cycle release of the slot |
| `CohSnpReq`, `CohSnpInv`, `CohSnpAdr` | controller → core | snoop the line: invalidate, or downgrade to S; held until acknowledged |
| `CohSnpAck`, `CohSnpHit`, `CohSnpDirty`, `CohSnpData` | core → controller | one-cycle answer: the line was valid, was dirty, its data |

The AHB master is unchanged. The controller recognizes the granted hart's transfers by hart index and `HPROT[0]`.

### 6. Cache finite-state machine

Three states are added to `cachefsm.sv`, used only with coherence:

- `STATE_ACQUIRE`: a miss, a write to an S line, or a flush asks for the slot and stalls; snoops are answered from here.
  On the grant the cache re-reads the line (`STATE_ADDRESS_SETUP`) and decides again with the slot held: the snoops
  answered meanwhile may have invalidated the line or the victim. A pipeline flush withdraws the request (or releases
  the slot if it was granted in that cycle).
- `STATE_SNOOP`: the tag, valid, dirty, writable bits and data of the snooped set, addressed in the previous cycle, are
  compared; the answer is given and the hit way's bits updated. Not cancelled by a pipeline flush.
  The writable bits are flip-flops: the upgrade of an S line, granted while the access waits in `STATE_ACCESS`, writes
  the set of the M-stage address, which a load does not put on the arrays' address.
- `STATE_SNOOP_RESTORE`: the arrays re-read the M-stage address, which the snoop replaced, then `STATE_ACCESS` (or
  back to `STATE_ACQUIRE`).

A snoop is accepted in `STATE_ACCESS` (taking priority over the access of that cycle, whose write is suppressed and
which is replayed) and in `STATE_ACQUIRE`. All other states occur only while the slot is held.

### 7. LR/SC and AMOs

AMOs and LR/SC are done in the L1, as in a single-core Wally; the fabric's central reservations
(`multicore_reservations.sv`) and the cores' `SHARED_ATOMICS` path are not used. The reservation (`lrsc.sv`) is
cleared when the reserved line is invalidated by a snoop or replaced by a refill, even while the pipeline stalls.

An LR acquires write permission, so two harts running LR/SC on one line would take it from each other forever. As
in Rocket, once an LR has performed the cache defers snoops until the SC, a pipeline flush, or 32 cycles, whichever
comes first: the SC then finds its line writable and the reservation intact. The bound keeps a hart that stalls
between LR and SC (on an I-cache refill that needs the deferred snoop) from deadlocking.

A snoop may interrupt an access the pipeline holds in `STATE_ACCESS`; the access is replayed after the snoop. This is
safe because Wally writes nothing while the pipeline stalls (`CacheEn` is 0 then): a store or an AMO writes the
cycle the stall ends, so replaying it after a snoop writes once, on the current value of the line.

### 8. Built for merging with upstream

- **Off by default, invisible when off.** `COHERENT_DCACHE` is a module parameter (default 0) of
  `wallypipelinedcore`, `lsu` and `cache`, set by the multicore SoC from its topology parameter `COHERENT_L1`, as
  `SHARED_ATOMICS` already is; no configuration file and no field of `cvw_t` changes. Every change in an upstream file
  is guarded by it and reduces to the current logic when it is 0; `regression-wally` and `lint-wally` on the standard
  configurations must be unchanged.
- **New logic in new files.** The per-line writable bits, the snoop comparison, the acquire/release handshake and the
  reservation kill are in `src/cache/cachecoherence.sv`; the controller in `src/ebu/ahbcoherence.sv`.
- **Small, local edits in upstream files.** `cachefsm.sv` (the three states and their terms), `cache.sv` (the snoop
  address in the array address muxes, the instance of `cachecoherence`, and a pipeline flush that does not cancel a
  snoop's update of the valid and dirty bits; `cacheway.sv` is unchanged), `ifu.sv` (the I-cache's coherence ports
  tied off), `lsu.sv`, `atomic.sv` and `wallypipelinedcore.sv` (the parameter and the ports),
  `lrsc.sv` (the reservation kill). No existing state, signal or term is renamed or
  reordered.

## Consequences

- A hit costs what it costs in a single-core Wally, one cycle; a miss costs the snoops (two to three cycles in each
  other hart, in parallel), a write-back of snooped dirty data when there is one, and the DDR3 access. Each remote
  transaction steals two to three cycles from every other hart's D-cache.
- With the core's D-cache back, misaligned loads and stores are again split in hardware (Zicclsm), CMOs could be
  supported later, and bursts (`BURST_EN`) are used. The multicore policy allows the core's caches with
  `COHERENT_L1` and keeps forbidding them otherwise.
- Bursts (2026-11-27): until then the coherent path took only SINGLE transfers, so a line miss was eight DDR3
  accesses (on the Nexys Video 300 to 600 cycles against 33 to 45 in the single-core bitstream, which made each
  Linux wake-up cost 10 to 25 ms). `ahbmulticore` (`CORE_BURSTS`) now passes the caches' INCR bursts to memory as
  one burst through a line buffer (`docs/engineering/interfaces/core-bus.md`), and the controller writes a snooped
  dirty line as one burst.
- One slot limits throughput when many harts miss at once; a snoop filter or per-line serialization can come later.
- Second phase, an improvement that changes only the controller: cache-to-cache transfer. The controller already
  holds the line a snoop returned; it can answer the requester's refill from that buffer instead of writing the line
  to memory and reading it back from DDR3.
- Implementation in phases, each verified before the next:
  1. Cache side with a behavioral controller in a testbench (random acquires and snoops, a golden memory, the
     single-writer invariant checked every cycle).
  2. `ahbcoherence.sv` and the SoC topology `COHERENT_L1` (`multicore_memory_system.sv`, the policy in
     `config/multicore/schema.json`), a CI case in `tests/multicore`.
  3. Linux SMP on the RTL (`linux/smp/run.py`), then the Nexys Video.
