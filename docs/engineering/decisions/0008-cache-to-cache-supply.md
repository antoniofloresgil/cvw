# ADR 0008: Optional cache-to-cache supply within MSI

Status: **accepted** for the optional serialized simulation implementation.
Date: 2026-10-20. Branch: `multicore-support`, parent `f9bd2003f53197268e306f997026956fcf7111a3`.

## Context and decision

Multiword MSI previously wrote a dirty supplier to memory, then reread the
line for its requester. Add `CACHE_TO_CACHE`, default off, independently of
local-hit enables. It requires effective private MSI; NCORES=1 bypass removes
coherence. Existing one-word defaults remain unchanged.

For a data write seeking ownership, copy every word from the M owner into
the fill buffer; COMPLETE installs the requester's M line, merges the byte
store and invalidates peer copies atomically. Dirty responsibility transfers
M to M without target-line RAM transactions. A dirty requester victim still
requires its ordinary writeback.

For a read intervention, MSI requires S copies to be clean. Retain all
acknowledged RAM writeback beats, but capture those same words for the new
reader, avoiding the subsequent RAM reread. Only after the final successful
beat may the old owner become S and the requester install its line. Errors
retain M ownership and prevent destination installation. IFU uses the
requested forwarded word without D allocation; subsequent clean suppliers
can provide other words. No dirty shared state is introduced.

## Alternatives and consequences

Always writing and rereading is the disabled baseline. MOESI would allow
read sharing without making RAM current, but needs an Owned state and new
invariants; it is deferred. A single global miss/permission transaction,
AHB SINGLE transfers, local-hit guards, store notifications, word reservations,
LR/SC and AMO ordering remain. No bursts, external DMA coherence, precise
writeback exceptions, FPGA timing or DDR3 result is claimed.

Affected interfaces: SoC, MSI cache, wrappers, focused test CLI and Linux
manifest/model/checkpoint identity. Private instruction/data capacities and
line geometry are independent. Linux images/DTB retain their geometry;
forwarding is an RTL property recorded in the manifest.

## Verification

See [the reproducible experiment](../experiments/2026-10-20-cache-to-cache.md)
for directed/random tests, negative controls and the separately built Linux
model. Short tests establish benefit for those workloads only. The exact new model completed Linux SMP PASS at 288,425,528 cycles, exit 0,
with two online CPUs and both counters equal to 128.
