# Passive multicore test observation extraction

Status: **PASS for the checks below**. Source: `multicore-support:4986fa5f8`
plus recommendation-9 working-tree changes. Proposed
[ADR 0021](../decisions/0021-multicore-test-observation.md); interface:
[observation contract](../interfaces/multicore-observation.md).

## Implemented scope

Cache/bridge type bindings isolate arrays, raw state codes and scheduling probes
in simulation-only adapters. Permissions use a test-owned vocabulary mapped from
DUT symbols. SoC/fabric adapters own generated hierarchy and geometry bindings;
architectural-word lookup combines RAM with a single matching Modified snapshot,
rejecting duplicate dirty owners instead of selecting the last one. Image loading
and memory/local/UART counters are kept in the SoC adapter with their original
edges and count semantics. Scenarios and independent reference arrays retain
expected values, byte masks, permissions, traffic and sequencing.

No src/ RTL, configuration or production port changes. Only explicit experimental
simulation source lists include the new package/bindings. Ordinary CI's bus case
now retains sentinel mapping, duplicate-owner, mapping-mutation and unchanged
scenario/reencoded-RTL tests. Reencoding copies alter cache permission (S/M/E),
FSM and transfer values while retaining invalid=0 for the RTL's aggregate reset.
No working source is mutated by the runner.

## Reproduction

```bash
source ./setup.sh
make deriv
lint-wally
python3 tests/multicore/check_observation.py \
  --work-dir sim/verilator/wkdir/multicore-observation/contracts
python3 tests/multicore/ci.py --case all --skip-deriv \
  --work-dir sim/verilator/wkdir/multicore-observation/final
```

Preliminary runs under ci/ and final-ci/ were stopped before completion and
are not counted as PASS or FAIL. The final run under final/ includes the
independent bridge conflict geometry and inactive-private-option isolation.
No warning category was disabled.

## Baseline and evidence

Evidence root: `sim/verilator/wkdir/multicore-observation/`. The reference is
recommendation-11's four-profile matrix, aggregate SHA-256
`55d2d4a360e439d6ba2ac67966c8c6ce69af833b620fa443ed4b80d726c10c49`.
All 399 recorded source hashes match committed parent `4986fa5f8` contents,
following tracked symlinks. Its 75 PASS/traffic/cycle signatures were frozen
in before-signatures.json; these baseline simulations were not rerun.

Final evidence is final/results-all.json, bus/observation.log and
bus/observation/results.json below final; each targeted build has command,
source/mutation/binary identities and run logs. Top-level logs are
`/tmp/cvw-observation-{deriv,lint,final}.log`. Preliminary contracts/trial
outputs remain separate from final matrix evidence.

## Observed verdicts

- Seven standard lint configurations: PASS, with no errors or warnings.
- All four final CI profiles: PASS (single-default, bus, MSI, MESI/banked),
  including seven topology lints, 16 real-adapter runs and all six original
  named negative endpoint cases, common peripheral/atomic units, 28 full-core
  atomic/smoke runs and two ordinary/forced-uncacheable translated AMO programs.
- The retained observation checker: all 21 executions PASS. Six RV32/RV64
  sentinel configurations cover one/two homes, one/four-word lines and I/D
  capacity orderings. Each duplicate-owner injection triggers its exact fatal
  diagnostic; the corrupted word mapping triggers the independent sentinel
  assertion. Eight original/reencoded real one-home/banked scenario executions
  retain semantic and SEQ signatures. All seven expected failures are explicit,
  not arbitrary process failures. Its canonical source hashes match final files.
- All 75 frozen main-log PASS/cycle/traffic signatures match exactly. All 92
  permission/local-store/local-reply/overlap/SEQ/PASS lines across 20 coherence
  and burst unit logs also match the baseline. See comparison.json; compare.py
  reproduces the final source and output comparison.
- An additional one-hart full-core atomic run passes with requested private
  capacities zero (inactive options), at 3,679 cycles. Inactive observer geometry
  is isolated from those options. See inactive-options/command.json, results.json
  and run.log; no new multicore profile is qualified by this bypass test.
- All 407 source hashes in final/results-all.json match final files. Tools:
  Verilator 5.036, RISC-V GCC 15.2.0. Aggregate SHA-256:
  `a8947891c0d8881f87e734c7c5727e81646cc315646b92be49c6b69a5fa2bfa0`.
- Scoped pre-commit, relative documentation links and git diff --check: PASS.

Local evidence archive: `sim/verilator/wkdir/multicore-observation/evidence-20261022.tar.gz`,
SHA-256 `b427424371055bd62736c29e74a7cbce6d56f521611789adab4f4614b2899920`. This is a local artifact, not a remote backup.

## Limits

No new Linux boot, whole ACT regression, formal, four-state/commercial-simulator
run, FPGA synthesis/inference/resource/timing or board boot was performed.
The observers do not add coherence transactions or qualify new production
profiles. Query-time dirty-owner rejection is not a global ownership proof.
Recommendations 10 and 12 remain separate proposed work; no branch merge or
automatic acceptance of ADR 0021 follows from these checks.
