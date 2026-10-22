# ADR 0012: 8 KiB private-cache defaults

Status: **accepted** for configurable private-cache defaults on
`multicore-support`, explicitly approved by the user on 2026-10-22.
Requested 2026-10-20; implementation and capacity evidence were published in
`f9f7a83bebcb4a3f4156f561a7adcdd74628c9ce`. Acceptance follows the user's
instruction, not an automatic promotion from a PASS record. Other ADR statuses
are unchanged. FPGA implementation/area/timing qualification is outside this acceptance.

## Context and decision

Use 8 KiB per private instruction cache and 8 KiB per private data cache per
hart, retaining configurable capacities and smaller controller/stress fixtures
to provoke replacements and conflicts. The alternative was to retain the
previous 2 KiB defaults; a fixed, non-configurable capacity was not selected.
The requested larger defaults and the measured workload results support this
choice without assuming a benefit for every workload.

Private RTL defaults use `8192/(AHBW/8)`: 1,024 words for a 64-bit AHB or
2,048 for a 32-bit AHB. Linux RV64 private-mode builders/DTB defaults use
1,024 words. Shared-cache and explicitly sized historical tests retain their
own capacities; old manifests retain their original capacity interpretation.
These defaults do not enable private caches in the native single-core bypass.

Following recommendation 5, the current default owner is
[config/multicore/schema.json](../../../config/multicore/schema.json), consumed
by Python builders/runners and the generated SV configuration header. See
[the profile definition](../../../config/multicore/README.md) and
[ADR 0017](0017-multicore-configuration-policy.md) for that separate refactor;
accepting this capacity decision does not accept ADR 0017.

## Implementation and verification

The original deferred seven-file overlay in `/tmp/wally-default8k-20261020/`
is historical preparation, not pending work or a workflow to reapply.
The [capacity experiment](../experiments/2026-10-20-private-cache-capacity.md)
records both frozen 2 KiB burst/MSI and MESI Linux baselines passing before
the defaults changed. It records the completed small-cache regression,
15 lint/structural checks and matched two-hart/two-home 2 KiB versus 8 KiB
atomic/smoke/UART/exclusive tests at RAM latency 0 and 3.

That historical experiment reports 8 KiB RTL Linux SMP PASS at 347,795,562
cycles versus 388,367,974 for its matching 2 KiB MESI baseline, both with two
CPUs and counter/protected values 128/128. Kernel/SBI/init binaries were
unchanged; DTB geometry and its RAM-image copy changed. Source/model/log/image
identities and the workload-specific comparisons belong to that experiment.
No simulation was rerun for this documentation reconciliation.

## Consequences and limits

Single-core coherence bypass, protocol selection defaults, home count, line
size and concurrency limits are unchanged by the capacity decision. Larger
caches do not improve every workload: the recorded latency-3 smoke test takes
more cycles at 8 KiB. Simulation results do not establish FPGA frequency,
BRAM inference, area or board boot. Two harts contain 32 KiB of private I/D
data capacity in total, excluding metadata and buffers.

FPGA synthesis/qualification remains future work and is not authorized by
this decision. The current capability limits remain those in the
[capability contract](../interfaces/multicore-capabilities.md).
