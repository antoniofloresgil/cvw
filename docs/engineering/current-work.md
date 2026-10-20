# Current work

Checkpoint: 2026-10-20, `multicore-support`, published base `f71666f07` plus
optional independent coherence homes validated with their own Linux PASS.
Use Git for current publication state.

## Objective and implementation

The user requested more than one outstanding coherence transaction. Optional
`COHERENCE_BANKS` (default one) now selects independent address-home MSI
controllers sharing one external AHB port. Total private capacity stays fixed;
NCORES=1 eliminates coherence. One transaction per hart and per active home,
with up to min(harts, homes) engines making progress. Cross-home LR/SC clearing
and global AMO admission/owner IFU progress preserve ordering.
See [ADR 0009](decisions/0009-banked-coherence-transactions.md) and
[the experiment](experiments/2026-10-20-banked-coherence.md).

Focused checks PASS in `/tmp/wally-banked-20261020/`: ten banked and two
one-home controller cases (24,000 random operations), 18 full-core runs,
18 lint/structural checks, four legacy checks, two negative controls and
DTS/manifest/CLI checks. Four-hart RV32/RV64 tests reach four active homes. The short two-hart atomic test is slower with two homes:
19,583 versus 14,147 cycles with one; the new router/port bridge adds latency.
Defaults remain unchanged. QEMU and byte-exact 100k versus 50k+restore
checkpoint checks pass for the new two-home model. Full Linux is
**PASS at 457,165,361 cycles**, exit 0 in `/tmp/wally-linux-banked-20261020/`, model SHA-256
`d2d7f71051e31af1b8ed7060853bfd815ba6834c34bd9a899b14c9156e5166e3`.
Its `supervisor-status.json` and `production-process.json` record the completed
run, with a 1.5-billion-cycle limit and 5M checkpoints. The final result verifies two online CPUs and both shared counters equal
to 128. The user authorized commit and push after this verified result.
The publication finisher records its actual commit/push outcome in
`publication-status.json`; Linux PASS alone does not establish publication.

## Completed baseline and boundaries

One-home cache-to-cache Linux passed at 288,425,528 cycles with two CPUs and
both shared counters 128, documented and pushed as `f71666f07`. The prior
multiword-line baseline passed at 287,836,760 cycles, commit `f9bd2003f`.
Neither verdict validates the new home fabric. Earlier records retain their
configuration/revision scope.

Same-home misses, physical AHB beats and AMOs remain serialized. There are no
per-hart multiple miss slots, bursts, Owned state, external DMA coherence,
precise writeback exceptions or FPGA/DDR3 results. Multicore stays separate
from main; open FPGA DDR3 initialization still needs board verification.
