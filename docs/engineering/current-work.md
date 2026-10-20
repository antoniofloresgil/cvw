# Current work

Checkpoint: 2026-10-20, branch `multicore-support`, parent `f9bd2003f53197268e306f997026956fcf7111a3`
plus optional cache-to-cache supply. Check Git for actual publication state.

## Objective and implementation

The multiword baseline passed its own Linux SMP and was pushed before this
change was applied. Optional CACHE_TO_CACHE (default off) forwards complete
M-owner lines on ownership acquisition and forwards acknowledged writeback
beats on read sharing. Standard MSI S copies remain clean. NCORES=1 removes
coherence. See [ADR 0008](decisions/0008-cache-to-cache-supply.md) and
[the experiment](experiments/2026-10-20-cache-to-cache.md).

16 controller configurations (32,000 random operations), 30 enabled full-core
runs, three disabled comparisons, 20 lint/structural checks, four legacy
checks, two negative controls and software identity checks pass. Linux with
this exact implementation has **PASS at 288,425,528 cycles**, exit 0, under the guarded supervisor
`/tmp/wally-c2c-preparation/chain.py`; `chain-status.json` records its stage.
Its new frozen model passed QEMU, bit-exact checkpoint restoration and full
Linux with two online CPUs and both counters equal to 128. Documentation and
publication follow that verified result; see chain-status.json for push status.

## Boundaries

Single global coherence transaction, AHB SINGLE beats, mandatory memory
writeback for M-to-S, no external DMA coherence or Owned state. No FPGA
timing/resources or DDR3 validation. Existing CPU error handling does not
provide precise cache/writeback exceptions. Multi-core remains separate from
main; open FPGA DDR3 initialization requires board verification. Earlier
experiment/ADR records retain their exact configuration and revision scopes.
