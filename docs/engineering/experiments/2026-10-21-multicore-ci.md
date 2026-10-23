# Automated multicore verification matrix

Status: **PASS** for the locally executed matrix and infrastructure checks. Source:
`multicore-support:67ec3d991201f0bb2d36a0420c26b67223b8ae49` plus uncommitted
recommendations 2 and 3. Design: proposed [ADR 0015](../decisions/0015-automated-multicore-verification.md).

## Changes and reproduction

Recommendation 3 is implemented through `tests/multicore/ci.py`, the new
Multicore GitHub Actions workflow and the ordinary regression's four added
cases. Linux remains separate. Run from the repository root:

```bash
source ./setup.sh
regression-wally --multicore
# Equivalent direct invocation, with an explicit artifact directory:
python3 tests/multicore/ci.py --work-dir sim/verilator/wkdir/multicore-ci-improvement3
# Or one independently selectable case:
python3 tests/multicore/ci.py --case mesi-banked
```

The single-default case compares single-hart peripherals with immutable
upstream ancestor `4ce065926c8096f34c77867c358f044ec1ea777e`; CI checks out
full history for this reason. The directed AMO assembly now names only its
required ISA (`rv64ia_zicsr_zifencei`), avoiding unnecessary assembler extension
requirements on the distribution toolchain, and links with `-nostdlib` because
the standalone assembly needs no C library. The same model also runs with
ordinary data cacheability, in addition to the forced uncacheable walker test.

Tools on this host: Verilator 5.036, RISC-V GCC 15.2.0, setup-selected
RISCV=/home/aflores/riscv. CI builds the same Verilator release and uses Ubuntu
24.04's bare-metal RISC-V compiler; remote execution is **NOT RUN** locally.

## Coverage and observed results

The final matrix completed with status 0 and all four cases PASS. The concrete
cases and coverage are listed in the [verification procedure](../verification.md#automated-multicore-matrix).

| Check | Observed verdict |
| --- | --- |
| Explicit topology lint | PASS, default one-hart plus two/three-hart bus, MSI and banked MESI: seven elaborations with the ordinary warning policy |
| Single-hart peripherals | PASS, four RV32/RV64/14/63-source comparisons, 12,000 common upstream transactions and the explicit corrections |
| Single-hart clock/reset | PASS, RV32i/RV64gc, bus enabled/disabled |
| Translated AMO/PTE A/D/LR-SC | PASS, ordinary cached data and forced uncacheable data, six and ten observed walker/AMO overlap cycles respectively |
| Common peripheral/bus/atomic units | PASS, four units in each of three multicore cases, including waits/errors, reservation invalidation and AMO exclusion |
| MSI/banked coherence units | PASS, 16 controller executions across RV32/RV64, 2/3 harts and latency 0/3, split equally across one-home MSI and two-home MESI |
| Burst units | PASS, RV32/RV64 and latency 0/3: four executions |
| Full-core atomic and smoke | PASS, 12 bus + 8 MSI + 8 MESI executions: 28 programs, plus the two single-hart translated AMO executions above |

Warm-build final case times were 8.82 s (single-default), 18.50 s (bus), 15.95 s
(MSI), and 17.49 s (MESI). Earlier cold builds of the controller profiles took
209.41 s and 152.56 s respectively on this host; these are observations, not
CI runtime guarantees.

Additional infrastructure checks passed:

- The ordinary regression's test-selection function selects all four cases,
  with `buildTests(deriv=True)` before workers and `--skip-deriv` in each child.
  ACT/Linux inputs were not built by this isolated selection check.
- Injecting a failing Verilator lint executable returns status 1, records FAIL
  and removes a stale case PASS. Failure artifacts are under
  `sim/verilator/wkdir/multicore-ci-failure-check/`.
- `python3 bin/regression-wally --multicore --dryrun` selects the shared runner
  without starting tests or generating configurations.
- The `--multicore` wrapper propagates a nonzero child status (23 injected for
  this check) rather than reporting a successful parent regression.
- `actionlint` 1.7.7 validates `.github/workflows/multicore.yml`; scoped
  pre-commit validates Python and YAML.

## Initial failed trial

The first MSI controller build failed in generated C++ with
`__Vfork_3__sync was not declared in this scope`. With Verilator 5.036,
`--output-split 0` for msi_tb/msifabric_tb avoids the split-coroutine generation
failure. The runner retains all concurrent SV stimuli and assertions; no RTL
change or suppressed warning is involved. The failed build log is retained at
`sim/verilator/wkdir/multicore-ci-improvement3/failed-trials/verilator-split.log`.

## Evidence and limits

Per-case work directories under
`sim/verilator/wkdir/multicore-ci-improvement3/` contain commands, lints, builds,
run logs and JSON results. The aggregate `results-all.json` identifies the
source commit, working-tree hashes, tool versions, effective config hashes,
options and elapsed time. CI uploads log/JSON artifacts even on failures.

Final aggregate `results-all.json` SHA-256:
`bddc4bcd9dfc268f6c563fb6690563c924393908026481b9b7bbb93a09e1ae4f`.
All recorded source hashes were rechecked against the final working tree.
An ignored repository-local archive preserves tested sources, logs, commands,
ELFs, source/config hashes, failed-trial diagnostics and the infrastructure
check script/output:
`sim/verilator/wkdir/multicore-ci-evidence-20261021/evidence.tar.gz`, SHA-256
`452e847179c1f8074149a2cd321caeb6cff68f26f40cc9266f3b66d412fe6bb8`.
This locator survives /tmp cleanup; it is not an external durable archive.

No full ACT regression, Linux boot, remote GitHub job, synthesis or hardware
test was run for this change. Bus error/controller tests establish only the
contracts they exercise, not precise CPU access-fault delivery. The sampled
matrix is not exhaustive cache-option or hart-count verification.
