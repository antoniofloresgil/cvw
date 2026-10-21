# ADR 0014: Optional Sscofpmf for Wally's HPM counters

Status: **proposed**, implemented in the working tree on
`adding-mpu-support` above `92c007ae5`. Date: 2026-10-21.

## Context and selected design

Wally's existing Zihpm counters count fixed events selected by nonzero
`mhpmeventn`; they had no standard overflow status, overflow interrupt or
privilege filtering. Add `SSCOFPMF_SUPPORTED` to `cvw_t`, defaulting to zero in
all base configurations. Derived `sscofpmf_rv64gc` and `sscofpmf_rv32gc`
enable the feature without changing existing board and Linux targets. They
require an S-mode configuration with Zihpm counters.

Keep the existing event mapping in bits 55:0. Add the standard `mhpmeventn`
OF/MINH/SINH/UINH fields; VS/VU inhibition and reserved fields read zero
because Wally has no H mode. On RV32, `mhpmeventnh` exposes the upper half of
each 64-bit selector. A hardware increment wrapping the 64-bit counter sets
sticky OF. An overflow while OF was clear sets LCOFIP once; software clears
pending state through `mip` or delegated `sip`. Control-field writes and
counter writes cannot themselves signal an overflow. `scountovf` exposes OF to
M mode and exposes only `mcounteren`-allowed bits to S mode; it is read-only.

Expand the interrupt register path to bit 13: LCOFIE in `mie`/delegated
`sie`, LCOFIP in `mip`/delegated `sip`, optional `mideleg` bit 13 and trap
cause 13. Preserve the existing 12-bit behavior when the option is clear.
Hardware set wins if software clears LCOFIP in the same cycle.

## Scope and verification

This is synthesizable RTL. The fixed events still have no programmable event
crossbar. The source signals for some cache and stall events originate before
M stage. The PMU now carries the initiating privilege mode alongside D-to-M
load/store stalls and holds it for cache stalls, delayed cache-miss notifications
and division busy cycles. Retired and M-stage events use the current instruction
mode; cache accesses are counted when issued. Directed tests cover a mode
transition while these earlier events remain pending. Speculative
instruction-cache activity is still counted; the result is not claimed as
precise security accounting. No H-mode filtering, FPGA timing or board
verification is claimed. See the
[mode-attribution experiment](../experiments/2026-10-21-pmu-event-modes.md)
for the new checks.

Directed RV32/RV64 tests and full-core checks are recorded in the
[Sscofpmf experiment](../experiments/2026-10-21-sscofpmf.md). The base
`pmu_linux` device tree intentionally does not advertise the extension;
firmware and software integration for sampling requires a matching enabled
target and separate validation.

Primary reference: [RISC-V Sscofpmf v1.0](https://docs.riscv.org/reference/isa/v20260120/priv/sscofpmf.html).
