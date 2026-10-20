# ADR 0007: Parameterizable multiword private I/D lines

Status: **accepted for the optional multicore-support design; two-hart multiword Linux SMP validated at 287,836,760 cycles**, 2026-10-19, on
`multicore-support` after `b9dd6e458`. This extends
[ADR 0006](0006-local-modified-stores.md); existing one-word results do not
validate the new line machinery.

## Objective and configuration

Implement the requested I-cache and D-cache line enlargement together, with
one global coherence transaction in progress and the existing local hit paths.
`PRIVATE_DCACHE_LINE_WORDS` and `PRIVATE_ICACHE_LINE_WORDS` default to 1.
They independently specify power-of-two AHB words per line. Each cache must
contain at least two lines. Capacity parameters remain **total AHB words**;
256 words still occupy 2 KiB in RV64, whether there are 256 eight-byte lines
or 64 thirty-two-byte lines. Four words give 32-byte RV64 lines; RV32 needs
eight words for 32 bytes. Tags/MSI states/I valid bits are per line; data
storage retains one slot per word. NCORES=1 bypasses all added coherence and
private-bank machinery as before. Shared/uncached modes are unchanged.

## Transfer and coherence contract

The D controller serially transfers an entire dirty victim or modified snooper
before invalidating/downgrading it. A D miss fills a staging line; only after
all reads succeed does COMPLETE install tags, state and data and merge any
store bytes. A failed writeback preserves the complete dirty line and M
permission, even if earlier words reached RAM. A failed fill never installs a
partial line. A successful eviction need not be undone if the following fill
fails. Retrying a failed writeback retransmits the full dirty line.

An instruction miss holds the arbiter's global owner across the complete I
line fill, using individually snooped word reads through the D controller.
IFU reads do not allocate D lines. Dirty D lines are flushed before supplying
instruction data. I data can be written during filling, but the valid bit
remains clear until the last word succeeds; a failed refill leaves it clear.
The original requested word is retained for the final core response even
when it was not the last word transferred. Neither critical-word-first replies
nor early restart are implemented.

Each memory word uses an aligned AHB SINGLE transfer. No burst-capable
memory interface is required; the line reservation covers gaps between these
transfers. MMIO/ROM bypass remains one original-sized transaction without
prefetch. This step does not implement direct cache-to-cache forwarding.

Ownership and invalidation cover entire D lines, including stores to a word
other than the one another hart previously accessed. Every successful global
or local store invalidates matching I lines in all harts. An M-hit ordinary
store still changes only its selected word/bytes; local commit notifications
continue to reach the central reservation monitor. LR/SC reservations retain
the existing word granule; coherence ownership changes are not architectural
stores. Atomics retain the global path and AMO exclusion.

Global-write/local-read and global-access/local-M-write conflicts use a
conservative aligned region as large as the larger I/D line. This blocks a
store to another word of an in-flight refill/intervention, including between
I-fill word transactions. Local read/store conflicts use the same region;
coincident SC can therefore fail conservatively on a nearby local store.
Independent-line hits and distinct M owners can still complete concurrently.

## Tradeoffs and verification

Larger lines may reduce spatial misses and metadata, but increase refill
latency, dirty transfer cost and false sharing. Fixed-capacity comparisons
must measure cycles and memory transfers; no improvement is assumed. Arrays
still use asynchronous probes; this decision provides no BRAM, frequency,
area or board-validation claim.

Require RV32/RV64, two/three harts, latency 0/3, unequal I/D line sizes,
one-word compatibility, independent enables, every requested word offset,
partial stores, dirty intervention/replacement, errors at every transfer beat,
LR/SC, AMO, code modification, local hits/stores during independent misses,
reset, Linux-wrapper lint and single-core structural removal. Record measured
results in the [multiword experiment](../experiments/2026-10-19-multiword-lines.md).
Existing running Linux models have frozen older sources and cannot validate
this change. Full Linux SMP with multiword lines remains a separate check.
