# ADR 0015: Optional Smcntrpmf filtering for fixed counters

Status: **proposed**, implemented in the working tree on
`adding-mpu-support` above `f1a5b7744`. Date: 2026-10-21.

## Context and design

Sscofpmf filters HPM counters 3-31, but `mcycle` and `minstret` still include
execution at all privilege levels. Add an independent
`SMCNTRPMF_SUPPORTED` configuration field. Base configurations retain zero;
`smcntrpmf_rv32gc`/`smcntrpmf_rv64gc` enable just this extension and
`pmf_rv32gc`/`pmf_rv64gc` enable both filtering extensions.

Implement the 64-bit machine CSRs `mcyclecfg` (0x321) and `minstretcfg`
(0x322), with RV32 high halves `mcyclecfgh` (0x721) and `minstretcfgh`
(0x722). Only MINH/SINH/UINH in bits 62:60 are writable; bit 63, the
unimplemented VS/VU fields and the WPRI fields read zero. Reset values are
zero so neither counter is filtered until software opts in. RV32 low-half
writes cannot erase high-half filter settings.

An increment requires both `mcountinhibit` permission and permission from
the corresponding configuration CSR. `mcycle` counts clock cycles in an
enabled mode; `minstret` counts only retired instructions in an enabled mode.
Wally updates `PrivilegeModeW` on the clock edge that processes a trap or
`xRET`, so the `xRET` retirement observes its originating mode. A faulting
instruction does not retire. Sscofpmf HPM events and overflow behavior stay
independent.

## Compatibility and verification

The configuration CSR is machine-only; this change does not implement
Smcdeleg/Ssccfg. Existing `pmu_linux` and board device trees describe base
targets with this extension disabled. An enabled Linux platform needs a
matching bitstream/configuration and device-tree ISA declaration before
OpenSBI or `perf` should use privilege filtering.

See the [verification record](../experiments/2026-10-21-smcntrpmf.md) for
RV32/RV64 CSR tests, combined-mode tests and full-core evidence. Linux boot,
FPGA synthesis/timing and board behavior with the new option remain separate
verification tasks.

Primary reference: [RISC-V Smcntrpmf v1.0](https://docs.riscv.org/reference/isa/v20260120/priv/smcntrpmf.html).
