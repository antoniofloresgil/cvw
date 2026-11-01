# PMU checks

`csrc.sv` retains the counter/selector CSR storage and read mux;
`pmuevents.sv` generates Wally's fixed events and mode tags, while
`pmucountercontrol.sv` implements optional filters, overflow and delegated
indirect access. The directed runner compiles all three modules explicitly.

After sourcing setup.sh, run `python3 tests/pmu/run.py --work /tmp/pmu-unit`.
The directed Verilator configurations cover RV32/RV64 and COUNTERS=3/8/32,
including permissions, fixed event sources, retirement gating, enable/inhibit
and rollover. Sscofpmf-on runs check M/S privilege filtering, RV32 high
`mhpmevent` CSRs, 64-bit overflow, sticky OF, `scountovf` visibility and its
read-only behavior. The interrupt test checks LCOFIP/LCOFIE in machine and
delegated supervisor modes, one-shot pending state, software clearing and trap
cause 13. Off runs check that these features stay unavailable. The same command
checks the generated OpenSBI mapping and all real board DTBs. Full-core
coverage uses tests/coverage/hpmcounters.S.

`make deriv` creates `sscofpmf_rv64gc` and `sscofpmf_rv32gc` from the standard
configs. Their `SSCOFPMF_SUPPORTED` parameter is set, while all base targets
keep it clear. Select a matching firmware device tree before advertising
`sscofpmf` to an OS; the existing board DTBs describe the base targets.

`smcntrpmf_rv64gc` and `smcntrpmf_rv32gc` enable mode filtering for
`mcycle`/`minstret`; `pmf_rv64gc` and `pmf_rv32gc` enable both extensions.
The directed suite checks the independent filters and RV32 high CSR halves.
`smcntrpmf.S` exercises a real M-to-U-to-M transition on the RV64 core.
Linux/OpenSBI and actual perf stat integration are documented in
[linux/pmu](../../linux/pmu/README.md). Counter RTL is synthesizable; these
fixtures are simulation verification, not a synthesized-board verdict.

`smcdeleg_rv64gc`/`smcdeleg_rv32gc` enable Smcdeleg and Ssccfg together.
`pmu_deleg_rv64gc`/`pmu_deleg_rv32gc` also enable Sscofpmf and
Smcntrpmf. The directed suite checks S-mode counter/selector access, M-mode
MINH preservation, unsupported alias traps and delegation permission gates.
The RV64 full-core `smcdeleg.S` program checks `menvcfg.CDE`,
`siselect`, `sireg*` and `scountinhibit` across an M-to-S-to-M
transition.
