# ADR 0013: isolate the multicore memory subsystem

Status: **accepted** for the structural extraction requested on 2026-10-21.
Branch: `multicore-support`, implementation based on `ce02cf1ad`.

## Context

The [maintenance review](../experiments/2026-10-21-multicore-maintainability-review.md)
identified memory topology assembly in the upstream SoC top as a major source
of future merge conflicts. Arbitration, shared-cache/private-cache selection,
banked coherence, local-hit wiring and capability checks occupied that top.

## Decision

Move those declarations, generate branches and assertions unchanged into
`src/ebu/multicore_memory_system.sv`. The SoC forwards its existing parameters,
per-hart AHB requests plus HATOMIC, per-hart responses plus SCFail, and the
shared uncore AHB interface. Cache-probe/commit and owner signals are internal
to the new module. Capacity units and all parameter defaults are unchanged.

The SoC continues to own reset synchronization, HCLK/HRESETn, hart instances,
interrupt routing and uncore instantiation. Preserve `core`, `harts[h].core`
and `uncoregen.uncore` hierarchy. Memory internals now live below
`memory_system`; update the multicore testbench's white-box observations.
The boundary introduces no registers or bus adapters.

NCORES=1 with SHARED_CACHE=0 keeps its combinational bypass, including ignoring
unused private-cache options. NCORES=1 with SHARED_CACHE=1 still selects the
shared cache. Effective MSI remains NCORES>1 && PRIVATE_DCACHE. Preserve every
existing capability rejection, including the CLINT hart-count bound.

## Alternatives and consequences

Keeping assembly in the SoC retains a large upstream conflict surface.
Duplicating the SoC or core for SMP would duplicate upstream maintenance.
A parameter/profile redesign could reduce repeated declarations but changes
an independent interface and is deferred. This decision keeps the public SoC
parameter list for existing wrappers, FPGA flows and simulation scripts.

Only the existing SoC RTL changes; CPU, peripherals, cache engines and base
configuration files are unchanged. Testbench cache/arbiter probe paths change.
Synthesis/source discovery must include the new module, as the existing
recursive RTL source collectors do. No FPGA synthesis or timing claim follows
from this extraction.

## Verification and scope

See the [extraction experiment](../experiments/2026-10-21-memory-subsystem-extraction.md)
for lint, structural checks, before/after functional comparisons and Linux
results. Compare against the parent feature branch, not upstream main:
pre-existing peripheral/atomic differences from main remain separate review
items. Other proposed ADRs and review recommendations retain their status.
