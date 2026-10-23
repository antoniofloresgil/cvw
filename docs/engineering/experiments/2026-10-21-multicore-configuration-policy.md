# Shared multicore configuration and physical memory policy

Status: **PASS for the checks below**. Source: `multicore-support:e8162b462`
plus the recommendation-5 working tree identified by the final CI source hashes.
No merge into main was performed. Decision: proposed
[ADR 0017](../decisions/0017-multicore-configuration-policy.md); policy usage:
[profile definition](../../../config/multicore/README.md).

## Change and scope

Recommendation 5 now has one schema for public topology fields/defaults, named
profiles and supported-combination rules. Python evaluates those expressions;
the generator translates them to the checked-in SV validator. Generated
parameter/forwarding macros keep the existing SoC parameter names and overrides
while removing independent declarations in the memory subsystem and wrappers.
`multicore_t` is separate from `cvw_t`; the latter's fields are unchanged.

All four optional memory engines, including the local D-cache probes, call one
physical RAM allocation function. Neither the RAM predicate nor the controller
state machines change behavior. Standalone controller geometry/protocol assertions
remain defensive local contracts. Public 8 KiB I/D deployment defaults remain;
stress capacities are explicit named profiles. Maintained test/Linux runners pass
resolved parameters explicitly instead of relying on independent bench defaults.

A small configuration fixture evaluates actual SystemVerilog localparams and
shared derivations. CI manifests record the resulting core and topology values.
Linux build/run and DT generation consume this report for ISA/MMU, RAM/MMIO ranges,
PLIC source count/UART IRQ and cache properties. The selected RTL advertises the
actual eight-byte UART aperture and configured 64 MiB PLIC aperture in the DT,
replacing the earlier hardcoded DT window sizes. These DT changes have compile
and consistency evidence, not a fresh Linux boot verdict.

Image manifests include effective configuration and policy version/hash. Before
build/reuse/run, current RTL, options, manifest compatibility fields, artifact
hashes, generated DTS and compiled DTB must agree. Old image manifests require
regeneration; old models/snapshots are not silently accepted. The fixed Linux
boot/image placement and clock recipe remain explicit limitations. Verilator and
`dtc` are required for these checks, including QEMU selection.

## Reproduction

```bash
source ./setup.sh
make deriv
python3 config/multicore/profiles.py
python3 tests/multicore/check_profiles.py --work-dir sim/verilator/wkdir/multicore-policy/profiles
lint-wally
python3 tests/multicore/ci.py --case all --skip-deriv --work-dir sim/verilator/wkdir/multicore-policy/final-ci
python3 tests/multicore/run.py --skip-deriv --shared-cache --suite atomic --cores 1 2 --latency 0 3 --cache-words 32 --work-dir sim/verilator/wkdir/multicore-policy/shared
```

Use a separate work directory when running the Linux image builder; derivative
regeneration must finish before concurrent simulation builds. `--profile` selects
a named configuration; explicit flags override it, including `--no-...` booleans.
The final CI run used already generated derivatives and unchanged RTL sources.

## Observed checks

- Generation freshness and scoped pre-commit passed. The freshness check also
  rejects a deliberately stale header; a separate injected stale-policy failure
  invalidated an old CI PASS and wrote a FAIL summary.
- 300 deterministic Python/SV rule vectors passed, exercising valid input and
  every one of the 12 current rule error codes. RAM low/high boundaries, disabled
  RAM, MMIO exclusions and an external RAM region above 4 GiB passed.
- Real RV32/RV64 SV defaults match Python, including width-dependent 8 KiB private
  capacities. Shared/MSI Linux profiles compile to DTBs from elaborated config.
  UART address/IRQ and PLIC source mutations change the DT; topology disagreement
  is rejected. Independently stale RTL, manifest, DTS and DTB mutations are rejected
  even when an altered artifact's hash is updated to match it.
- Seven standard lints passed without warnings, and the four final CI profiles
  passed, retaining seven topology lints, 16 real-adapter executions and six named
  negative endpoint checks, 28 full-core atomic/smoke runs, two translated AMO
  single-hart programs, coherence/burst/controller/peripheral checks and the new
  policy suite.
- The extra shared-cache run passed its cache unit and eight full-core atomic/
  smoke executions: one/two harts, RAM latency 0/3, 32 shared words. Common bus,
  atomic and RV32/RV64 peripheral units also passed.
- A fresh two-hart Linux harness model compiled with the new public parameter
  mapping, and `--build-only --reuse` accepted its matching metadata. This used
  a synthetic manifest/DT fixture to exercise model preparation, not bootable
  Linux images; no software execution is claimed.

Initial development lint exposed unsized SV literals/boolean Verilator overrides;
the generator/argument formatter now emits explicitly sized values. Those failed
intermediate checks are not counted as PASS. The final matrix ran after source
freeze, and its recorded source hashes were compared to the working tree.

## Evidence and limitations

Evidence root: `sim/verilator/wkdir/multicore-policy/`. The final CI aggregate is
`final-ci/results-all.json`; per-case JSON/logs include effective configurations.
Additional evidence is under `profiles/`, `shared/` and `stale-guard/`.
Top-level execution logs are `/tmp/cvw-policy-ci.log`,
`/tmp/cvw-policy-profiles.log`, `/tmp/cvw-policy-shared.log`,
`/tmp/cvw-policy-linux-build.log`, `/tmp/cvw-policy-linux-reuse.log` and
`/tmp/cvw-profile-lint.log`. The final aggregate records Verilator 5.036 and RISC-V GCC 15.2.0.
All 391 recorded source hashes match the final tree. Aggregate SHA-256:
`4ff28a30daa54911e210d6e88e137f1fb0e8c17994c0261210979d42a7e2fd19`.

A local archive of JSON/log/DT evidence and Linux model identity is
`sim/verilator/wkdir/multicore-policy/evidence-20261021/evidence.tar.gz`;
SHA-256: `e495edcbd2c08b2bfcbbed4ad84c461ebd3ab5e16cba5166acc13e830d92e9b9`.
It excludes compiled models and is local evidence, not a remote durable backup.

No new Linux/OpenSBI image build or Linux/QEMU boot, full ACT regression, formal,
four-state simulation, FPGA synthesis/timing/boot or remote CI verdict was obtained.
No new DMA coherence, precise CPU error delivery or supported arbitrary-hart claim
follows from centralizing configuration. Recommendations 6 and 9–12 remain separate.
