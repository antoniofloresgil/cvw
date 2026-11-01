# ADR 0016: Optional Smcdeleg/Ssccfg counter delegation

Status: **proposed**, implemented in the working tree on `adding-mpu-support`
above `776ae473b`. Date: 2026-10-21.

## Context and design

An S-mode kernel currently needs SBI calls to write machine HPM counters and
event selectors. Smcdeleg/Ssccfg permits machine firmware to grant S-mode
direct access to selected counter state. The extensions must be enabled as a
pair. One `SMCDELEG_SUPPORTED` configuration field represents both and stays
zero in all base configurations. Derived `smcdeleg_rv32gc` and
`smcdeleg_rv64gc` enable delegation; `pmu_deleg_rv32gc` and
`pmu_deleg_rv64gc` combine it with Sscofpmf and Smcntrpmf.

Implement `menvcfg.CDE` (bit 60), including `menvcfgh` on RV32.
`siselect` (0x150) stores a 12-bit select value. Its `sireg`,
`sireg2`, `sireg4`, and `sireg5` aliases map select values 0x40-0x5f
to counters, event selectors and RV32 high halves. Reserved aliases,
the `mtime` select 0x41, and undelegated or unimplemented counters trap.
Delegation requires both `menvcfg.CDE=1` and the selected `mcounteren` bit.
Fixed-counter configuration aliases also require Smcntrpmf; RV32 event
selector high halves require Sscofpmf. Supervisor aliases cannot read or
write MINH (bit 62).

`scountinhibit` (0x120) masks `mcountinhibit`: delegated bits are
read/write, while nondelegated bits read zero and retain their machine value.
When CDE is clear, access traps. Counter 1 remains reserved. Wally does not
implement H, Smaia or Smstateen, so their additional rules do not apply.

## Compatibility and limits

Base configurations and existing Linux images keep their SBI PMU path.
An enabled system needs matching firmware and Linux support: OpenSBI must
enable CDE and delegate counters, and the ISA description must match RTL.
RTL tests establish the direct CSR mechanism, not Linux adoption or a
measured reduction in `perf` overhead.

References: [Smcdeleg/Ssccfg v1.0](https://docs.riscv.org/reference/isa/v20260120/priv/smcdeleg.html)
and [Smcsrind/Sscsrind v1.0](https://docs.riscv.org/reference/isa/v20260120/priv/indirect-csr.html).
