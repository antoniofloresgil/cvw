# Shared translated core/bus atomic symbols

Status: **PASS for the checks below**. Source: `multicore-support:7c2a28642`
plus recommendation-11 working-tree changes. Proposed
[ADR 0020](../decisions/0020-corebus-atomic-symbols.md); interface:
[buffered core/bus contract](../interfaces/core-bus.md).

## Change and verification scope

The package cvw now owns explicitly two-bit COREBUS_NORMAL/LR/SC/AMO constants
with unchanged values 00/01/10/11. LSU translation, EBU IFU selection,
ahbmulticore, ahbmsifabric, multicore_reservations and corebus_contract use
those symbols instead of local constants or operation literals. The distinct
LSUAtomicM encoding is unchanged. All ports remain logic vectors with their
existing widths. No new compilation unit, cvw_t field, register, pipeline stage,
cache-state representation or datapath behavior is introduced.

The existing synthetic atomic/boundary fixtures retain literal wire codes,
providing an independent stimulus check of the encoding. No tests mirror the
new constant declarations. No DMA, CPU error recovery or FPGA claim follows.

## Reproduction and evidence

```bash
source ./setup.sh
make deriv
lint-wally
python3 tests/multicore/ci.py --case all --skip-deriv \
  --work-dir sim/verilator/wkdir/multicore-atomic-symbols/ci
```

Local evidence root: `sim/verilator/wkdir/multicore-atomic-symbols/`;
logs: `/tmp/cvw-atomic-symbols-{deriv,lint,ci}.log`. Raw simulator output stays
outside permanent documentation. The earlier capability matrix supplies the
frozen 75 PASS/traffic/cycle signatures in before-signatures.json. Its aggregate
SHA-256 is `0b97c7741549d4419a492528ea8a514bf00359d6f95dea59a751abafa8c29f05`.
All 399 baseline source hashes were compared against committed parent contents
(following tracked symlinks); the only difference is multicore.yml's subsequent
uv dependency fix. Thus the baseline RTL/fixtures match the parent. The
baseline simulations were not rerun for this comparison.

## Observed verdicts

- Seven standard lint configurations: PASS, with no errors or warnings.
- All four CI profiles: PASS (single-default, bus, MSI, MESI/banked).
  This retains seven explicit topology lints, RV32/RV64 peripheral/clock checks,
  the two ordinary/forced-uncacheable translated AMO programs, isolated RV32/RV64
  storage/reservation checks, 16 real-adapter runs, all six named negative
  endpoint cases, existing coherence/burst/error units and 28 full-core
  atomic/smoke runs. The policy and capability/guard checks also pass.
- All 75 baseline PASS/cycle/traffic signatures match exactly (7 single-default,
  28 bus, 20 MSI, 20 MESI/banked). See before-signatures.json and comparison.json;
  compare.py reproduces the final source-hash and signature checks.
- All 399 source hashes in ci/results-all.json match the final working tree.
  Final aggregate SHA-256: `55d2d4a360e439d6ba2ac67966c8c6ce69af833b620fa443ed4b80d726c10c49`.
  Tools: Verilator 5.036 and RISC-V GCC 15.2.0.
- Scoped pre-commit, relative documentation links and git diff --check: PASS.

Local evidence archive: `sim/verilator/wkdir/multicore-atomic-symbols/evidence-20261022.tar.gz`,
SHA-256 `f88025c29ffd95a5d9109c207621672fb1fc4d4e8b6e88383c31f3e435751034`. This is a local artifact, not a remote backup.

## Limits

No Linux boot, complete ACT regression, synthesis, FPGA
resource/timing/boot, formal or four-state simulation is part of this check.
