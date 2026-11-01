# Current work

Checkpoint: 2026-10-23, branch `opensource-fpga-bitstream`.
Integration inputs: feature `f950a775310e7613d22f409bcaaec81f8a8a646e`
and `main:1d567764895321b64a9b8e28d0b77ca4b9eb0aac` (official upstream
`89479dd09`). Use `git rev-parse HEAD` for the resulting merge revision.

The `opensource-fpga-bitstream` branch was merged into `main` (PR #22, then
continued by `wally-ddr3-init`, PR #23) and deleted (local and `origin`) on
2026-11-01. Its commits, including those cited in these documents as
`opensource-fpga-bitstream:<hash>`, are all reachable from `main`, and its last
commit `2043ea59a` can recreate it.

The `adding-mpu-support` branch (PMU counters) was merged into `main` (PR #25,
`da9e9c21c`) and deleted (local and `origin`) on 2026-11-01. Its commits are
all reachable from `main`, and its last commit `d0d11792c` can recreate it.

## Current integration

Merge main into the open FPGA branch to reduce future integration work.
Retain LiteDRAM, the service CPU, DDR reset gating, AHB/Wishbone bridge and
32-bit boot-ROM preload. Main's optional multicore implementation is now
available in this branch; the FPGA wrapper still uses one hart by default.
The [integration record](experiments/2026-10-23-open-fpga-main-integration.md)
records this merge's checks and evidence boundaries.

Combined-source validation passed: seven standard configuration lints plus
`fpgaopensource`, five RV64 directed tests, all four multicore CI profiles
and their feature-interaction suite, a 32/64-bit ROM preload fixture,
FPGA wrapper port elaboration with an empty LiteDRAM stub, open/Vivado recipe
dry runs and all-file pre-commit checks. No new datapath or topology changes
were added beyond the combined branch inputs. The merge is local; publication
is a separate operation.

Open-flow DDR3 now works on the connected Nexys Video (2026-10-28). The cause
was the pinned gatecat nextpnr-xilinx `8f178fc6`. The same Yosys netlist passed
on hardware when placed and routed by Vivado, and failed with that nextpnr.
The installer now uses openXC7 nextpnr-xilinx 0.9.8 plus a local placer
legality patch. With it, the LiteDRAM BIOS passes leveling and its memory test.
In the full `make nexysvideo FLOW=opensource` bitstream, Wally completed 971
DDR3 write/verify passes with no errors. HCLK timing at 40 MHz is marginal
(38.99 to 44.5 MHz across builds). See the
[DDR3 record](experiments/open-ddr3-bringup.md).

Open-flow Linux boots on the Nexys Video (2026-10-29) with
`make nexysvideo FLOW=opensource OPENCONFIG=fpganexysvideo`: RV64GC at 12.5 MHz
in its own clock domain (LiteDRAM CDC), the ZSBL in the boot ROM, and the SD
card written for the Vivado flow. OpenSBI 1.7 and Linux 6.19.14 reach the
BusyBox shell with 512 MiB; an 8 MiB file in `/tmp` has the correct MD5.
Getting there needed an AHB-to-Wishbone bridge fix (burst beats were dropped),
DSP48 inference, a CARRY4 netlist pass for nextpnr's atomic carry packer, and
balanced-tree rewrites of `popcnt` and `lzc` (5.7 to 14.9 MHz). The ZSBL now
rewrites the device-tree clocks to its own frequency. ACT and periph tests pass
on rv64gc, rv32gc and rv32imc with Verilator, except `WALLY-uart-01`, which
also fails on the unchanged branch head. On 2026-10-30 the RV32 open-flow
design (`fpgaopensource`, 40 MHz) was rebuilt with these changes and passed 973
consecutive DDR3 write/verify passes on the board; that build also fixed the
LiteDRAM generator's shared-clock mode, which the Linux work had broken.

## Wally runs the DDR3 initialization (merged, PR #23)

Branch `wally-ddr3-init`, merged into `main` by PR #23. The VexRiscv service CPU inside the LiteDRAM core
becomes optional (`gen_litedram.py --init-cpu {vexriscv,none}`) and Wally runs
the initialization and leveling code itself; the VexRiscv stays as a debugging
alternative. Done on the Nexys Video for RV32 (`fpgaopensource`: Wally runs
LiteX's `sdram_init()` from its IROM, saves 2763 LUT and 1407 FF) and RV64
(`fpganexysvideoopen`: a stage 0 initializes the DDR3 through a new uncached
`EXT_IO` PMA window, then the ZSBL boots Linux; saves 2334 LUT and 1151 FF).
Both level the DDR3 exactly as the service CPU did. Plan, design, measurements
and the verification are in
[experiments/2026-11-01-wally-runs-ddr3-init.md](experiments/2026-11-01-wally-runs-ddr3-init.md).

## PMU counters (merged, PR #25)

Branch `adding-mpu-support`, merged into `main` by PR #25 (`da9e9c21c`). Main `4ce065926` (official upstream through
`89479dd09`) was integrated into PMU feature parent `8cb89bab9`; main
`568a9ed65` (multicore, open FPGA flow, Wally-run DDR3 initialization, `EXT_IO`)
was merged in again on 2026-11-01, and the checks below predate that merge. Synthesizable
Zicntr/Zihpm counters, the OpenSBI event map and Linux `perf stat` support are
preserved. `csrc.sv` kept the PMU parent's non-comment RTL tokens.

Combined-source checks PASS: six PMU CSR/event configurations, eight board
DTS, ten RTL lints and the full-core HPM test. A fresh single-core Linux PMU
run also passed at 121,617,639 cycles with seven counter checks and actual
`perf stat`. See the
[PMU/main integration record](experiments/2026-10-21-pmu-main-integration.md)
for parent revisions, model and image hashes, commands and evidence limits.

Optional Sscofpmf hardware is committed as `f1a5b7744` with RV32/RV64
derived configs. The directed 14-case PMU run, nine RTL lints and a full-core
`hpmcounters.elf` simulation passed; see
[ADR 0014](decisions/0014-sscofpmf-counter-overflow.md) and the
[verification record](experiments/2026-10-21-sscofpmf.md).

Smcntrpmf fixed-counter filtering is committed as `776ae473b`.
Eighteen directed cases, 13 RTL lint elaborations and the
full-core M/U/M transition and HPM regression checks pass. See
[ADR 0015](decisions/0015-smcntrpmf-fixed-counter-filter.md) and its
[verification record](experiments/2026-10-21-smcntrpmf.md). Linux `perf` with
fixed-counter privilege filters subsequently passed at 163,215,722 RTL
cycles; see the [Linux experiment](experiments/2026-10-21-smcntrpmf-linux.md).
FPGA synthesis/timing and physical-board behavior remain unverified.
The multicore RTL arrived with the 2026-11-01 merge of main. The PMU now
also counts the cache events of the private multicore caches, and per-hart
counters, Sscofpmf interrupts and cache events pass with 2 and 3 harts; see the
[multicore PMU record](experiments/2026-11-01-pmu-multicore.md).

Smcdeleg/Ssccfg counter delegation is committed as `45911b806`, with one
configuration switch for the required pair. The
directed RV32/RV64 CSR suite, six RTL lint elaborations and the RV64
full-core M/S/M test have passed. A separate `pmu_deleg_linux` Linux image
and kernel S-mode direct-CSR probe passed in a Linux RTL boot at
123,214,564 cycles, followed by the existing `perf stat` integration.
The first image used `loglevel=6`, which suppressed the probe's `pr_info`
message; a `loglevel=7` rerun made the direct-access PASS marker visible.
Normal Linux `perf` still programs counters through SBI, so no performance
benefit from direct programming has been measured. FPGA timing and board
operation remain unverified. See [ADR 0016](decisions/0016-smcdeleg-ssccfg-counter-delegation.md)
and the [experiment](experiments/2026-10-21-smcdeleg-ssccfg.md).

An Sscofpmf Linux sampling image using Linux 6.19.14 and OpenSBI 1.7 has
passed on `pmu_deleg_linux` RTL at 143,791,780 cycles. Privilege-filtered
branch counts, direct overflow samples, actual `perf stat`, and actual
`perf record` with 147 sample records all passed. See the
[sampling experiment](experiments/2026-10-21-sscofpmf-linux.md) and the
[software compatibility matrix](pmu-software-compatibility.md). The latter
also records that this Linux PMU driver still uses SBI for programming,
despite hardware support for Smcdeleg/Ssccfg.

The PMU mode-attribution change tags early-stage and multicycle events with
their initiating privilege mode for Sscofpmf filtering. Directed RV32/RV64
tests and three full-core lint configurations pass. **Pending:** repeat the
full-core HPM simulation with a Verilator version that compiles the testbench's
dynamic-string `$system` call. The installed 5.022 generates an undefined
`VL_SYSTEM_IN` call; the current attempt never started the simulation and is
not a PASS. See the
[mode-attribution experiment](experiments/2026-10-21-pmu-event-modes.md).

The PMU modularization moves fixed events/mode tags and optional
counter control/delegation into two new modules while retaining the existing
`csrc` CSR interface and storage. All 22 directed PMU cases, board DTB checks
and ten full-core lint configurations passed; see
[ADR 0017](decisions/0017-pmu-module-boundary.md) and the
[refactor experiment](experiments/2026-10-21-pmu-modules.md). Full-core
simulation remains pending on the Verilator `$system` compilation issue above.

## Future work

Complete open flow: add an open-source ASIC flow (Yosys with OpenROAD, through
OpenROAD-flow-scripts or OpenLane, on an open PDK such as sky130 or gf180) next
to the open FPGA flow, so Wally can go from RTL to both bitstream and GDS with
free tools. It belongs on its own branch after the open FPGA optimization pass.
Today the repository has no OpenROAD integration: `synthDC/` is a
synthesis-only Design Compiler flow, and no routed ASIC result exists (see
[implementation status](implementation.md)). Points to plan: the full RV64GC
core is large for a multi-project wafer shuttle, so a smaller configuration
such as `rv32imc` is the likely first target; the caches need SRAM macros from
the PDK through the `USE_SRAM` path; and a submission needs DRC/LVS signoff.

## Inherited main checkpoint

The following checkpoint is preserved from the main input. Its historical
multicore verdicts are not new runs of this combined branch.

Branch: `main`. On 2026-10-22, `multicore-support` source commit
`06d1baab69435abb13efd195ac675134f787da90` was fast-forwarded into main from
`origin/multicore-support`; the integration includes current main commit
`a6f312a2d8f7ccff54f6353d846751aae0e5c200`. This replaces the pre-integration
snapshot below. The `multicore-support` branch was deleted (local and
`origin`) on 2026-11-01; its commits, including those cited below as
`multicore-support:<hash>`, are all reachable from `main`, and its last commit
`06d1baab6` can recreate it. The remote Multicore workflow passed on feature commit
`75c805457c29c1ba992027ab934d84f48b55085b`; Lint passed on integration commit
`06d1baab6`. No full ACT regression, new Linux boot, FPGA qualification, DMA
coherence or precise CPU bus-error implementation is claimed.

Historically integrated main `4ce065926` (official upstream
`89479dd09`) into feature parent `f9f7a83be`. Configurable hart/interrupt/
atomic interfaces and optional MSI/MESI private caches are preserved; private
I/D defaults remain 8 KiB and single-core coherence bypass remains.

At that historical integration, combined-source validation passed: controller/peripheral checks, 41 full-core
runs, RV32/RV64 directed tests, configuration/FPGA lint and scoped pre-commit.
Fresh native Linux SMP passed after 347,795,562 cycles with both CPUs online
and atomic/protected counters 128/128. See the
[integration record](experiments/2026-10-20-multicore-upstream-integration.md)
for exact revisions, model/log hashes and evidence scope.

Completed objective (2026-10-21): implement recommendation 1 from the
[maintenance review](experiments/2026-10-21-multicore-maintainability-review.md)
on parent `ce02cf1ad`, following accepted
[ADR 0013](decisions/0013-multicore-memory-subsystem-boundary.md).
Memory topology and capability assertions now live in `multicore_memory_system`;
SoC parameters, hart/uncore hierarchy and clock/reset ownership are preserved.
No CPU/peripheral/cache-engine behavior or base configuration was changed.

Focused validation passed: seven standard lints, four structural checks,
two RV32 integration lints, 40 matched before/after program comparisons
(80 executions), and seven native RV64/RV32 directed programs. Fresh two-hart
RTL Linux SMP passed after 339,802,249 cycles with both CPUs online and
atomic/protected counters 128/128; see the
[extraction record](experiments/2026-10-21-memory-subsystem-extraction.md).
No merge into main was performed.
Recommendation 2 was implemented on parent `67ec3d991`:
single-hart CLINT/PLIC use upstream-shaped modules with explicitly scoped
generic corrections, multi-hart implementations live in separate modules,
no-bus clock/reset outputs match upstream, and cached LSU atomic metadata
follows walker ownership. See proposed [ADR 0014](decisions/0014-single-hart-peripheral-isolation.md)
and the [compatibility record](experiments/2026-10-21-singlecore-compatibility.md).
Seven lints, four peripheral comparisons (12,000 common transactions), two
clock/reset cases, translated AMO/PTE updates with a negative mutation, bus/
peripheral units and 12 full-core atomic/smoke executions passed. No new Linux
or private-cache regression was run. The unsupported cacheless/virtual-memory
trial was rejected by the existing configuration assertion, then removed from
the test runner; it is not a PASS. Recommendations 2 and 3 were committed and
pushed together as `8ecb9ef1b` on `multicore-support`.
Recommendation 3 was committed in that revision: shared
`tests/multicore/ci.py` cases for single-default, bus, MSI/one-home and
MESI/two-home configurations are selected by ordinary regression and the new
Multicore workflow. `regression-wally --multicore` runs only this matrix.
It includes explicit multi-hart lint, controller wait/error/ordering checks
and full-core programs; Linux remains separate. All four final cases passed:
seven topology lints, four single-hart peripheral comparisons, two clock/reset
checks, two translated AMO programs, 16 coherence and four burst unit runs,
common bus/peripheral/atomic units, and 28 full-core atomic/smoke programs.
Workflow actionlint, scoped pre-commit, ordinary regression selection and
failure/stale-result propagation checks passed. Remote GitHub execution and
the complete ACT regression were not run. See proposed [ADR 0015](decisions/0015-automated-multicore-verification.md)
and the [matrix record](experiments/2026-10-21-multicore-ci.md).
Recommendation 4 was committed and pushed as `e8162b462`:
the [buffered core/bus contract](interfaces/core-bus.md) specifies address
acceptance, delayed/live write payloads, atomic sideband, AMO exclusion/pairing,
retained SC results and ERROR/flush/reset semantics. A reusable port checker
and engine assertions add simulation checks without changing the datapath or
single-hart bypass. Real ahbinterface/busfsm/EBU fixtures are selected by CI:
RV32/RV64, two/three harts, one/two homes, latency 0/3, and six named negative
cases. Final validation passed: all four CI cases, 16 real-adapter executions,
six named negative fixtures, seven standard and seven topology lints, 28
full-core atomic/smoke programs, the existing coherence/burst/peripheral matrix
and scoped pre-commit. MEM3 retention is explicitly checked via BusCommitted/
BusStall while pipeline stall remains asserted across an IFU reply. Source
hashes of the final aggregate and both boundary manifests match the final tree.
No new Linux, remote CI, full ACT regression or hardware verification was run.
See proposed
[ADR 0016](decisions/0016-core-bus-temporal-contract.md) and the
[boundary record](experiments/2026-10-21-core-bus-contract.md).
Other review recommendations and proposed ADR statuses remain unchanged.

Follow-up static review at `e8162b462` confirms recommendations 1–4 are present.
At that reviewed source, 5 (configuration/policy ownership) and 6 (engine
decomposition) remained pending.
The [post-refactor review](experiments/2026-10-21-multicore-post-refactor-review.md)
proposes additional recommendations 9–12: simulation observation adapters,
feature-interaction coverage, shared atomic symbols and reusable downstream test
infrastructure. Prioritize the observation boundary and complementary coverage
before further RTL extraction. All 378 sources in the final CI manifest match
the reviewed checkout; no new simulations or functional refactors were performed.
These recommendations remain proposals; no merge into main was performed.

Recommendation 5 is implemented on parent `e8162b462`: shared schema/profiles,
generated SV parameters and validation, one physical RAM predicate, and effective
RTL/DT/image-manifest checks. Public SoC parameters and 8 KiB private defaults are
preserved; topology remains outside cvw_t. All four final CI cases, the 300-vector
policy/DT negative suite, seven standard lints, eight additional shared-cache
full-core runs and Linux harness build/reuse passed. No new Linux boot or hardware
result is claimed. See proposed [ADR 0017](decisions/0017-multicore-configuration-policy.md)
and the [configuration record](experiments/2026-10-21-multicore-configuration-policy.md).
Recommendation 6 was still pending at that source; additional recommendations
9–12 remain proposals. No merge into main was performed.

Recommendation 6 is implemented on parent `349263f55`: LR/SC reservations and
sticky SC results, instruction banks and data-word arrays have separate modules.
Bridge arbitration/AMO locks and MSI/MESI metadata/control preserve their cycle
behavior in the compared tests.
The [storage contract](interfaces/multicore-storage.md) specifies ports, edge
priorities and current combinational-read/line-wide bandwidth before any BRAM work.
All four final CI cases, seven standard lints, isolated RV32/RV64 engine fixtures,
eight one-word coherence cases and eight shared-cache full-core runs passed.
All 75 frozen baseline PASS/cycle/traffic signatures match. See proposed
[ADR 0018](decisions/0018-multicore-engine-boundaries.md) and the
[extraction record](experiments/2026-10-22-multicore-engine-extraction.md).
No new Linux, FPGA, formal or main integration result was obtained.

Recommendation 7 is implemented on parent `1a40aaac2`: canonical capability
metadata separates available hart-path behavior, unsupported DMA/precise HRESP
features and unverified FPGA/arbitrary-count qualification. Requirements fail before
builds and per-case CI evidence has explicit execution scope. Experimental SoC/Linux
harnesses enforce fault-free bus execution; transport fault injection remains separate.
All four final CI profiles, capability/guard negative fixtures, seven standard lints
and Linux harness compilation passed; all 75 baseline signatures match. See proposed
[ADR 0019](decisions/0019-multicore-capability-scope.md), the
[capability/DMA/error contract](interfaces/multicore-capabilities.md) and the
[execution record](experiments/2026-10-22-multicore-capability-scope.md).
No new DMA/architectural-error implementation, Linux boot, FPGA or scaling
qualification is claimed. Recommendations 8 and 9–12 remain separate proposals.

Remote Actions at `af35521ac` passed bus/MSI/MESI but failed single-default
because uv was absent during ordinary-testbench ELF conversion. The workflow
now installs uv and exports its Python tool environment. Fresh conversion and
both AMO/walker modes pass locally with an isolated PATH; remote confirmation
is pending. See the [focused fix record](experiments/2026-10-22-multicore-actions-uv-fix.md).

Recommendation 8 reconciles the completed 8 KiB implementation with
[ADR 0012](decisions/0012-private-cache-default-capacity.md), now **accepted**
by explicit user instruction on 2026-10-22. ADR 0010 is also **accepted** by
subsequent explicit user instruction on that date, for the optional implemented
AHB cache-line burst path; no new hardware qualification is implied.
ADRs 0009, 0011 and 0014–0019 remain **proposed** despite implementation and tests; pre-existing accepted
ADRs retain their scope. Publication and acceptance are separate from runtime
qualification. See the [reconciliation record](experiments/2026-10-22-multicore-documentation-reconciliation.md).

Recommendation 11 is implemented on parent `7c2a28642`: translated core/bus
atomic symbols now have one definition in package cvw, reused by LSU, EBU,
bridge/fabric arbitration, reservations and the temporal checker. Two-bit wire
encodings, ports and LSUAtomicM's distinct representation remain unchanged.
Seven standard lints and all four CI profiles pass, including all six named
negative endpoint cases. All 75 baseline PASS/cycle/traffic signatures match;
all 399 final manifest source hashes match the tree. No new Linux boot or FPGA
qualification was performed. See proposed [ADR 0020](decisions/0020-corebus-atomic-symbols.md)
and the [execution record](experiments/2026-10-22-corebus-atomic-symbols.md).
Recommendation 9 is implemented on parent `4986fa5f8`: passive test-only cache,
bridge, SoC and fabric adapters isolate internal arrays, generated paths and
numeric permission/FSM/transfer encodings. Expected reference data and scenario
sequencing remain independent. Architectural lookup now rejects duplicate dirty
owners; retained CI checks inject duplicate owners/bad mappings and run unchanged
RV32/RV64 scenarios against reordered internal encodings. All four final CI
profiles and seven standard lints pass, including 21 observation executions
and seven expected observation failures. All 75 baseline main-log signatures
and 92 unit output/counter lines match; all 407 final source hashes match.
A one-hart atomic run also passes with unused private capacities zero.
No new Linux boot or FPGA result is claimed. See proposed [ADR 0021](decisions/0021-multicore-test-observation.md)
and the [execution record](experiments/2026-10-22-multicore-test-observation.md).
At that checkpoint recommendations 10 and 12 were pending; recommendation 10
has since been implemented below and recommendation 12 is implemented in this
update.

FPGA synthesis/timing and dual-core Nexys Video boot remain unverified. PMU
support was later merged into `main` (PR #25).

Recommendation 10 is implemented in the current `multicore-support` worktree:
the automated CI adds ten focused RV64 cache/SoC interactions and a JSON report
that maps supported features and selected risky pairs to case verdicts, with
unsupported, unverified and uncovered scope explicit. The complementary suite
and aggregate four-profile CI passed. An isolated
local-writes case also corrected a stale expected value in the controller
scoreboard; RTL is unchanged. See the
[option-interaction experiment](experiments/2026-10-22-multicore-option-interactions.md).
Recommendation 12 is implemented: MSI and banked-MSI benches now share the
pipelined downstream memory/fault fixture, passive AHB protocol checker and
bounded master access tasks. The standalone checker fixture accepts legal
traffic and requires malformed-SEQ and unstable-write-data mutations to fail.
The 8 MSI and 12 banked-MSI pre/post functional logs match exactly after
excluding source line numbers and simulator wall-time fields; both profiles
pass at RV32/RV64 with their configured latencies. See the
[downstream fixture record](experiments/2026-10-22-multicore-downstream-fixture.md).
Recommendations 1–12 and their recorded checks are now integrated into main.
The remaining DMA coherence, precise CPU error-delivery and hardware/scaling
qualification work is explicitly outside this branch's experimental scope;
see the [capability contract](interfaces/multicore-capabilities.md).
