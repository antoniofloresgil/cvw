# Current work

Branch: `multicore-support`. Private I/D defaults are now 8 KiB per hart;
MESI/bursts remain optional, and single-core coherence bypass is retained.
The user requested this conditional change after both 2 KiB Linux baselines
passed, followed by matched performance simulations. Small-cache fixtures
remain explicitly small. See [ADR 0012](decisions/0012-private-cache-default-capacity.md).

Completed 2 KiB Linux baselines, two harts/two homes/32-byte I/D lines:
- Burst/MSI: PASS at 413,832,376 cycles.
- Burst/MESI: PASS at 388,367,974 cycles.
Both have two CPUs and shared counters 128/128, recorded in their experiments.
Earlier focused MESI checks passed 18,000 random operations, 24 full-core
runs and 15 lint/structural checks. Private first writes improved 3.39% at
2 KiB; the other short programs were unchanged. These are separate from the
capacity comparisons below. Scope: this feature branch and simulation.

Capacity follow-up PASS: 18,000 small-cache random operations, 16 matched
full-core comparisons and 15 lint/structural checks. Fresh 8 KiB Linux SMP
PASS at 347,795,562 cycles, two CPUs and counters 128/128. See the
[capacity comparison](experiments/2026-10-20-private-cache-capacity.md) for
configuration, observed reductions/regressions and source/model/log identities.
Defaults remain configurable. Validated changes prepared for publication to origin/multicore-support.
FPGA synthesis remains unexecuted.
Nexys Video dual-core implementation is future work.
