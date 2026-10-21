# ADR 0017: shared multicore configuration and physical memory policy

Status: **proposed**; implemented on `multicore-support` parent `e8162b462`.
Implementation/testing does not automatically accept this decision.

## Context and proposed choice

Recommendation 5 of the maintenance review identified independently maintained
parameter defaults, validation, physical cacheability and Linux platform metadata.
Preserve topology outside `cvw_t` while retaining the existing named SoC parameters.

Use `config/multicore/schema.json` for parameter types/defaults, named profiles and
supported-combination rules. A small expression translator generates the SV
validation function from the expressions evaluated by Python. Checked-in generated
macros centralize public parameter declarations and forwarding without requiring
an installed Python package during ordinary RTL builds. `multicore_t` lives beside,
not inside, `cvw_t`. Pre-commit and CI reject a stale generated header.

Keep the RAM allocation predicate in one package function used by all four engines,
including local cache probes. Keep defensive module-local geometry/protocol checks
for standalone controller instantiation; do not force unit fixtures to satisfy a
full-SoC profile. No cache controller or reservation state machine is decomposed.

Evaluate effective core configuration using a small SV report fixture with the
same includes and topology parameters as the Linux/test tops. Derive Linux DT ISA,
MMU, memory/peripheral windows, IRQ and cache properties from that report. Record
it in image and CI manifests. Reject disagreement between current RTL, requested
options, image manifest, DTS and compiled DTB before build/reuse/run.

## Alternatives and consequences

Adding multicore topology to `cvw_t` would mix platform assembly and CPU ISA data.
A second hand-written Python validator would preserve the original drift risk;
a Python parser for config.vh would duplicate SystemVerilog elaboration semantics.
Replacing every public parameter with one struct would break existing named
instantiations and command-line overrides. Generated declarations preserve those
interfaces at the cost of a regeneration step and an explicit macro include.

8 KiB private I/D deployment defaults remain width-dependent; small stress profiles
are separate. Core ports, memory timing, atomic behavior and single-hart bypass
are unchanged. The generated header is versioned, so synthesis does not run Python.
Linux remains a deliberately bounded RV64/Sv39 image recipe with fixed boot placement
and explicit platform clock. Its checks now require Verilator/dtc even for QEMU.
Old manifests need image regeneration; model/checkpoint compatibility checks remain
strict. A schema edit does not imply new supported hardware capabilities.

## Verification

Run the generation freshness check, `check_profiles.py`, standard lint and the
four-case multicore CI matrix. Cross-language rule vectors, address boundaries,
actual RV32/RV64 defaults and negative RTL/manifest/DTS/DTB consistency checks guard
the new ownership boundary. See the [implementation record](../experiments/2026-10-21-multicore-configuration-policy.md)
for exact evidence and limits. A model build is not a Linux boot or FPGA result.
