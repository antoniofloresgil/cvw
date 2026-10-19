# ADR 0004: Private instruction banks and concurrent read hits

Status: **accepted for the optional stage-5 implementation on
`multicore-support`**, 2026-10-19. The user requested private instruction
caches and concurrency/performance improvements. Base: `8ac2d4d6b` plus the
working-tree changes. This extends [ADR 0003](0003-private-msi-data-caches.md);
its default blocking mode remains available. No adoption on main is implied.

## Context and alternatives

Serializing every instruction and data hit wastes the replicated banks'
read bandwidth. Allowing local stores would hide writes from reservations
and snooping, requiring a different distributed protocol. Instead, permit
independent read hits while keeping all writes, atomic accesses, misses and
coherence transitions at the existing central ordering point. Nonblocking
miss machinery, local M stores, larger lines and multiple coherence requests
remain outside this step.

## Selected design and interface

Three optional SoC parameters extend the existing MSI mode:

- `PRIVATE_ICACHE=0`: per-hart physically tagged, direct-mapped instruction
  banks in `ahbmulticore`; `PRIVATE_ICACHE_WORDS=256` words per bank.
- `LOCAL_DCACHE_READS=0`: enable read-only probes into `ahbmsicache`, using
  buffered physical `CacheReadAddr` and returning `CacheReadHit/CacheReadData`.

Both options require effective MSI with multiple harts. With NCORES=1 all
private/coherence additions disappear and the original core path remains.
Capacity must be a power of two >= 2. Lines remain one AHB word, 8 bytes
on RV64 and 4 on RV32. Legacy IFU/LSU caches remain disabled. RAM/EXT_MEM
are cacheable; ROM/MMIO bypass both local paths.

A pending instruction hit can complete independently for every hart in the
same cycle, including while another hart waits for a global read/miss.
Ordinary non-atomic data read hits can do the same. The hart holding an
outstanding global transfer cannot also complete it locally. A reply still
uses the original per-hart AHB buffer and preserves back-to-back acceptance.
Local replies do not consume or rotate the global round-robin grant.

Data misses and instruction misses traverse the existing arbiter/MSI path;
an instruction miss snoops dirty data, including its own hart, before filling
its I bank. Only a successful full-word response allocates an instruction
line. Instructions never allocate in a D bank. Errors do not allocate.
Reset invalidates every I/D bank and aborts buffered requests.

## Invalidation and ordering

The initial blanket write/read restriction below is **superseded by
[ADR 0005](0005-independent-read-write-overlap.md)** for the later working-tree
refinement. Other stage-5 contracts remain in effect.

Every successfully completed global write invalidates matching instruction
words in **all** harts, including the writer. This includes partial writes,
M hits, successful SC and AMO writes. Failed SC never emits a write; failed
writes do not invalidate. I-cache fill and invalidation cannot race because
the global path admits one transfer. Data writebacks are internal transfers
of previously ordered stores, not additional architectural writes.

Local reads are held while any global write is in flight. This covers the
interval where the MSI controller has merged a write but the arbiter has
not yet received its reply/invalidation edge. A read accepted before that
write can finish before it; a pending read behind it rechecks current tags
and validity after commit. No local path bypasses a pending invalidation.

All LR/SC/AMO operations use the global path even on a hit. Ordinary local
data reads are also held for the complete AMO lock interval. Instruction
hits can continue, including from other harts; they cannot expose a partial
data AMO. Instruction misses retain the existing AMO-owner restriction.
Every store still invalidates LR reservations centrally, including M hits.
No store buffer or per-hart reordering is introduced.

Eager instruction invalidation supplies stronger visibility than software
needs: local `fence.i` and remote synchronization do not need an additional
cache flush port for writes made through this fabric. The pipeline's existing
instruction synchronization remains in use. This does not make external DMA,
unsnooped devices or writes bypassing the fabric coherent.

## Consequences and verification

Read bandwidth scales across the bank read ports; writes/misses remain
serialized. The centralized arrays implement private contents and independent
reads, not physically distributed controllers. Asynchronous read probes may
cost FPGA LUTs or affect timing; no BRAM inference or clock improvement is
claimed without implementation results.

Required checks: simultaneous I/D hits, hits during a different hart's miss,
write-versus-hit races, own/remote code patching and fence.i, I conflicts,
MMIO bypass, failed fills, reset, LR/SC conflicts, AMO lock exclusion,
RV32/RV64 and single-core structural removal. Compare cycles using identical
programs and RAM latency, with I-only, D-read-only and combined settings.
Results and scope are in the [stage-5 experiment](../experiments/2026-10-19-private-l1.md).

The subsequent optional [local-M extension](0006-local-modified-stores.md)
adds per-hart commit notifications and reservation/I-cache coordination.
The no-local-store restriction above remains the baseline with that option off.
