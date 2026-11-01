# ADR 0006: Local M-hit commits with central coherence notifications

Status: **accepted for the optional multicore-support working-tree design**,
2026-10-19, implementing the user's item 3: local stores with reservation and
snoop coordination. Base Git revision `8ac2d4d6b`, plus the source-captured
stage-5 and [independent-word overlap](0005-independent-read-write-overlap.md)
changes. Earlier experiment verdicts do not validate this implementation.

## Interface and selected design

`LOCAL_DCACHE_WRITES=0` is an independent SoC option requiring effective MSI
when NCORES>1. NCORES=1 removes it with the other private-cache paths. It does
not require local reads or private I caches. S hits, misses, LR/SC, AMO,
ROM/MMIO and permission acquisition retain the global path.

The shared buffered address port CacheReadAddr also probes write permission.
`ahbmsicache` returns CacheWriteHit only for a physically matching M line.
`ahbmulticore` broadcasts CacheWriteCommit, CacheWriteData and CacheWriteStrb
per hart; the bank merges those bytes at the commit edge and the hart gets
its normal registered reply. Distinct M words can commit in parallel and
alongside an unrelated global transaction without consuming a global grant.
These remain centrally instantiated private banks, not distributed controllers.

Every commit is visible centrally. It invalidates all matching LR reservations
and instruction words in every hart, including the writer. No store is hidden
from those mechanisms. An ordinary same-value or partial store still consumes
a reservation on its word. SC validation rejects a reservation invalidated
by a coincident local commit; failed SC never writes. All atomics remain on
the existing global path, and the entire AMO lock blocks local M commits.

## Hazards and commit ordering

Local stores are blocked for their own outstanding global transfer and for
**any global access to their physical word**, including read intervention.
A writeback may already have captured old M data; permitting a local update
behind it would lose the update when the bank downgrades to S. A queued store
must recheck M permission after the global reply and use a global upgrade if
it has become S. Different-word local writes cannot touch the active owner's
bank and do not interfere with the target word's peer snoops. Same-index,
different-tag words are not treated as the same address.

Local read hits matching a local commit wait through that edge. A simultaneous
new global request observes local commits before its subsequent lookup.
Multiple local commits are to distinct words (asserted), so they commute.
Single-outstanding coherence/miss machinery and per-hart request order remain.

Two edge cases require explicit priority:

- A newly completed LR replaces the old reservation address. Local invalidation
  compares its new word, not a stale old address, so an unrelated M store
  cannot accidentally destroy the new reservation.
- Instruction invalidations precede a simultaneous unrelated I fill. The new
  fill keeps its valid bit even if its victim tag matches a committing store.

The cache asserts M permission at commit and absence of a conflicting global
owner/snoop. Partial writes preserve unselected bytes; local M updates need no
RAM transfer. Existing writeback/fill error handling and dirty-data loss on
reset are unchanged. Precise CPU bus exceptions and external DMA coherence
remain outside the implemented contract.

## Verification and Linux boundary

Require parallel M stores, stores during unrelated misses, global read/write
conflicts, permission downgrade/retry, byte stores, own-reservation consumption,
coincident LR replacement/I fill, AMO exclusion, code patching/fence.i, errors,
reset, RV32/RV64, unequal capacities and independent enable combinations.
Measure full-core cycles against a freshly rebuilt item-2 baseline.

The [local-M experiment](../experiments/2026-10-19-local-modified-stores.md)
records actual results. After directed/full-core checks, start a fresh Linux
simulation containing both items 2 and 3. Its model, images, checkpoints and
frozen inputs must be separate from the earlier stage-5 run. No prior Linux
PASS is inherited. No FPGA timing, area or general scalability result is implied.
