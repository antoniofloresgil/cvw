# ADR 0005: Read hits during independent writes

Status: **accepted for the working-tree implementation on multicore-support**,
2026-10-19, following the user's request to implement item 2 of the proposed
next steps. Base Git revision remains `8ac2d4d6b`; the uncommitted stage-5
implementation is the behavioral baseline. This refines the write/read
ordering subsection of [ADR 0004](0004-private-instruction-caches.md), keeping
its private banks, global write/atomic ordering and single-core bypass.

## Decision and rationale

Replace the blanket in-flight-write prohibition with a comparison of full
physical AHB-word addresses in `ahbmulticore.readhazards`. Instruction and
ordinary D-cache read hits may complete while another hart writes a different
word. A local read remains blocked if its hart owns the outstanding transfer
or its word matches the in-flight architectural write. Compare above
`GRANULE_BITS = log2(XLEN/8)`, covering every byte of the word. Effective MSI
already requires AHBW=XLEN. Comparing byte addresses would miss partial-write
hazards; comparing only bank indices would block unrelated tags needlessly.

The guard remains active throughout the write's data phase, including the
interval after the MSI bank merge and before the arbiter receives its reply.
Matching pending reads recheck validity/data after commit. No other writer or
coherence transaction can begin concurrently. Reads of other words can be
ordered before the pending write, preserving each hart's one-request ordering.

A write may evict its owner's dirty victim, but that hart cannot complete a
second local request while it owns the transaction. Peer invalidations and
modified intervention concern the target physical word, which is blocked.
An unrelated hart's bank is not evicted just because its index matches.
Internal writebacks preserve previously ordered values; they are not new
architectural writes to independent data.

All LR/SC/AMO accesses still traverse the global arbiter. Local D reads remain
blocked for the **entire AMO lock**, including unrelated words; this step does
not weaken atomic exclusion or allow local stores. Instruction hits retain
the physical-word write guard, including during an AMO write. Global writes
still invalidate reservations and matching I copies at successful completion.
No new enable parameter is needed: the refinement applies only when the
existing private-I/local-D-read paths are enabled. NCORES=1 still removes them.

## Verification and boundaries

Require I-only, D-only and combined checks; RV32/RV64; 2/3 harts; waits 0/3;
small unequal capacities; independent accesses with colliding indices;
matching full-word and byte writes; LR/SC conflicts, AMO exclusion, errors
and reset. An independent hit must actually complete during the write data
phase, not merely before or after it. Compare full-core cycles/traffic with
the captured stage-5 baseline. Results are recorded in the
[overlap experiment](../experiments/2026-10-19-independent-read-write.md).

The pre-existing Linux run uses its previously compiled binary and frozen
source snapshot. Its verdict cannot validate this refinement. No DMA
coherence, local writes, additional outstanding misses or FPGA timing/area
result is implied.

The subsequent optional [local-M extension](0006-local-modified-stores.md)
adds per-hart commit notifications and reservation/I-cache coordination.
The no-local-store restriction above remains the baseline with that option off.
