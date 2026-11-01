# ADR 0017: PMU logic outside the common counter CSR module

Status: **proposed**, implemented on `adding-mpu-support` above
`e6a459188`. Date: 2026-10-21.

## Context and selected design

The PMU branch added fixed event mapping, privilege tags, Smcntrpmf filters,
Sscofpmf overflow handling and Smcdeleg/Ssccfg access logic to Wally's
existing `csrc.sv`. Keeping all of this inside the common CSR module enlarges
the overlap with future upstream counter changes.

Keep `csrc.sv` as the owner of counter and selector CSR storage, ordinary CSR
reads and the established `csrc` interface. Move fixed event generation and
event-mode tracking to `pmuevents.sv`. Move fixed-counter filter CSRs,
increment gating, overflow detection and delegated indirect counter access to
`pmucountercontrol.sv`. A small set of event, counter and CSR signals crosses
the module boundary; neither the core nor configuration interfaces change.
When Sscofpmf and Smcntrpmf are disabled, their tag and filter registers are
elaborated away as before.

Moving the entire original `csrc.sv` to a replacement module would leave a
large conflicting deletion against upstream. A textual include would reduce
file length but would not define an explicit interface. The two helper modules
keep upstream's counter bank and CSR read mux visible in their existing file.

## Scope and verification

This is a structural refactor, intended to preserve CSR behavior and event
timing. The directed PMU test runner must compile both new modules explicitly;
the regular full-core source glob includes them automatically. The
[refactor experiment](../experiments/2026-10-21-pmu-modules.md) records the
executed checks and any remaining limits. FPGA area/timing and a full-core
simulation with a suitable Verilator version remain unverified.
