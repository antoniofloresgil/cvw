# ADR 0009: Independent address-home coherence engines

Status: **proposed**; implemented as an optional simulation path on
`multicore-support`, based on `f71666f0776949f27c4ebdbaa627b5a46a8f5a54`.
Date: 2026-10-20. The user requested more than one outstanding transaction.
Functional evidence and the independent Linux verdict are recorded in
[the banked experiment](../experiments/2026-10-20-banked-coherence.md).

## Context, alternatives and selection

Private hits already overlap a global transaction, and the bridge already
buffers one request per hart. Adding another queue alone would not allow two
coherence misses to progress. The existing MSI engine has one fill buffer,
owner and transient state machine. A fully nonblocking per-hart cache with
MSHRs, tagged replies and distributed transient states would be a larger
change. Merely pipelining AHB does not remove coherence serialization.

The selected implementation adds `COHERENCE_BANKS`, default one. When
`NCORES > 1 && PRIVATE_DCACHE && COHERENCE_BANKS > 1`, `ahbmsifabric`
routes requests to independent address homes. Each home instantiates the
existing arbiter, private I banks and MSI D controller, including optional
cache-to-cache supply and local read/write paths. Every physical I/D alias
belongs to the same home. One transaction per home may progress, giving up
to `min(NCORES, COHERENCE_BANKS)` simultaneously active coherence engines.
Each hart remains blocking, with one outstanding CPU transfer. Requests
mapping to one home remain serialized; this is not multiple misses per hart.

A separate round-robin arbiter serializes only actual memory transfers on
the single external AHB port. Another home can perform snooping, local hits
or an M-to-M handoff while that port waits for RAM. External AHB remains
SINGLE, with no response IDs, bursts or multiple physical data phases.

## Address mapping and capacity

The bank count is a power of two. Divide total private I/D word capacities
by the bank count; every bank must retain at least two complete lines of
each configured geometry. Select the home from physical address bits just
above the larger per-home I/D word capacity. Thus no I or D line crosses a
home boundary, including unequal I/D capacities or line sizes. All ROM/MMIO
uses home zero. Tags retain full physical addresses. Total per-hart data
capacity stays fixed; transient buffers, metadata and routing grow.

## Atomic ordering and replies

The router accepts one core address before withholding HREADY, preserving
the core busfsm's ready-dependent address issue. It holds the home and
metadata through completion; core write data stays live until the data
reply. Per-home and final port arbiters retain their existing address/data
owner separation and two-cycle ERROR handling. Reset aborts all homes and
invalidates their banks; it does not preserve dirty data.

LR/SC reservations belong to harts, not homes. On every completed LR or SC
(including failed/error operations), the router clears that hart's reservations
in all other homes. The selected home retains its original reservation/SC
logic. Word-granule store invalidation stays local because a physical word
has exactly one home. `ahbmulticore.ReservationClear` is the new sideband;
legacy instantiations tie it to zero.

An AMO read waits for all already dispatched hart requests to drain. The
router then holds global exclusion for that hart until its AMO write or AMO
error reply. Other harts may queue addresses but cannot enter any home. The
owner can fetch instructions from another home, avoiding cross-home IFU/AMO
deadlock. Pending AMOs stop new ordinary dispatches, and AMO arbitration
rotates among harts. Existing per-home AMO locks remain in force.

## Compatibility, performance and limits

One bank selects the previous RTL path. Single-core generate bypass removes
all coherent banks even when additional banks are requested. Non-MSI
multicore use of multiple banks is rejected. CLI/model/image/checkpoint
identities carry the count; changing it requires a newly compiled model.
The DTB reports unchanged total private capacity and line geometry.

Routing and the additional port bridge add latency. The short two-hart,
32-byte-line atomic test is slower with two homes despite demonstrated
concurrency; no universal speedup is claimed. Contended words, same-home
misses and physical RAM beats remain serialized. No Owned state, DMA
coherence, FPGA/DDR3 result, arbitrary-N proof or precise writeback exceptions
are introduced. See the experiment for verification scope and limitations.

## Independent Linux evidence

The new two-hart/two-home model completed Linux SMP **PASS at 457,165,361 cycles**,
exit 0, with two online CPUs and both shared counters 128. Documented 2026-10-20;
see the experiment for exact source/model/log identities and directed
four-home evidence. This result does not change the proposal status or extend
the result to main, arbitrary home counts or FPGA hardware.
