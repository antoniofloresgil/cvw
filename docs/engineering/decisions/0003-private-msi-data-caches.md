# ADR 0003: Blocking private data caches with MSI bus snooping

Status: **accepted for the first MSI implementation on `multicore-support`**,
2026-10-19, following the user's explicit choice of private data caches,
MSI, snooping and one coherence transaction in flight. This is an optional
mode alongside [ADR 0002](0002-shared-multicore-cache.md), not its removal.
Base revision: `35cb2093b`; validation of this working tree is recorded
separately. No adoption on main or hardware result is implied.

## Context and alternatives

The shared physical cache avoids replicated copies. Adding private caches
requires ownership, invalidation and modified-data intervention. The first
step must support two harts, retain NCORES parameterization and eliminate
coherence logic when multicore is disabled. More concurrent private L1
controllers, MESI and a directory were deferred in favor of a blocking MSI
baseline that retains the verified central reservation/AMO ordering point.

## Selected design

`ahbmulticore` continues to serialize **every** core transaction, including
private hits, and exports its address/data owner as HOWNER. Downstream,
`ahbmsicache` maintains separate tags, data and I/S/M state for each hart's
private data-cache bank. These are not the pre-existing unsnooped LSU caches:
P.DCACHE_SUPPORTED and P.ICACHE_SUPPORTED remain off in this mode. HPROT[0]
distinguishes data access from instruction fetch. Each direct-mapped line
holds one full XLEN-wide AHB word; WORDS configures each bank's capacity.

The controller broadcasts its physical-address lookup to all banks. A read
miss (BusRd) flushes any M owner to RAM and downgrades it to S, then fills
the requester's data cache in S. A write miss (BusRdX) first writes back its
own dirty victim if needed, flushes any remote M copy, obtains the full word,
invalidates matching peer copies and installs M. A write to S (BusUpgr)
invalidates peers; a write to M merges byte strobes locally. S replacements
are silent; M replacements require a successful full-word writeback.

Snoop acknowledgments are implicit in the single synchronous controller:
all matching bank states change at the commit edge. There are no independent
snoop queues, distributed transient-state machines or outstanding cache
requests. The shared physical interconnect remains the ordering point;
hit concurrency and scalable bandwidth are explicitly not provided yet.

Instruction fetches do not allocate. They snoop all D-cache banks, including
the requesting hart's, and write back modified code before reading memory.
ROM and MMIO bypass cache allocation and preserve address/size/strobes.
All cores and banks use the same clock/reset. External DMA bypassing this
fabric is outside the coherence contract.

## Atomics, errors and configuration

LR/SC reservations and AMO read/write exclusion remain in ahbmulticore.
Because even M-hit writes pass that arbiter, no store is hidden from its
reservation invalidation. Failed SC never reaches the cache. An AMO owner
may still fetch instructions while holding the exclusion lock. Cache
writebacks/fills preserve the downstream HMASTLOCK indication.

Writeback errors retain M and its data; failed fills never install a line
or grant ownership. The cache returns AHB's two-cycle ERROR response. This
is cache/bus recovery, not precise CPU exception delivery: the existing EBU
still treats HRESP as ignored, and delayed writeback exceptions are not
implemented. Reset invalidates banks and aborts transactions; dirty data
is not guaranteed to survive a system reset.

SoC parameters: PRIVATE_DCACHE (default 0), PRIVATE_DCACHE_WORDS (default
256), and existing NCORES (default 1). The effective enable is
`NCORES > 1 && PRIVATE_DCACHE`; NCORES=1 removes MSI through generate and
retains the original direct core path even if PRIVATE_DCACHE was requested.
Shared-cache and effective MSI modes are mutually exclusive. Guards require
XLEN-wide AHB, no legacy private caches/memories or bursts, Svade software
PTE A/D updates, no Svpbmt, and no cache-maintenance extensions. The
multicore_msi derivative supplies these restrictions; parameters enable
and size the actual private banks. WORDS is a power of two >= 2.

## Verification requirements and limits

Required checks include M exclusivity, S sharing, read/write hits and misses,
BusRd/BusRdX/BusUpgr, modified intervention, dirty eviction, partial writes,
instruction/data aliasing, MMIO bypass, concurrent requests, LR/SC and AMO,
wait states, error retention/retry, reset and single-core generate bypass.
Exercise RV32/RV64, two/three harts and several capacities. Full-core programs
must check shared counters, code patching plus fence.i, IPIs/timers and UART.

See the [MSI experiment](../experiments/2026-10-19-private-msi.md) for observed
results; requirements are not results. No FPGA implementation, resource or
clock-closure claim is made. No new Linux SMP boot is inferred from the
older shared-cache Linux result.
