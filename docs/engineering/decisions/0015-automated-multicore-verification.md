# ADR 0015: per-change multicore verification matrix

Status: **proposed**; implemented on the working tree based on
`multicore-support:67ec3d991`, together with recommendation 2's changes.
Acceptance remains separate from implementation and verification results.

## Context

Recommendation 3 of the [maintenance review](../experiments/2026-10-21-multicore-maintainability-review.md)
identified that ordinary lint, regression and CI never selected NCORES>1.
Directed coherence tests and full-core programs already existed, but depended
on someone invoking them manually. Linux SMP takes too long for each change.

## Proposed integration

Use `tests/multicore/ci.py` as the shared per-change entrypoint, with four
independently selectable cases: single-default, bus, msi and mesi-banked.
The [verification procedure](../verification.md#automated-multicore-matrix)
defines each case's concrete scope. Default execution runs every case.

A dedicated GitHub Actions workflow selects these cases for relevant pushes
and pull requests, and allows manual dispatch. The ordinary regression also
selects all four cases; `regression-wally --multicore` runs only this matrix
without ACT inputs or Linux. Each case explicitly lints its topology and uses
the existing Verilator benches/programs. Linux remains a separate procedure.

The enclosing runner generates derivatives once before starting tests.
Ordinary regression passes `--skip-deriv` to case runners and generates them
before its worker pool. This prevents concurrent readers from seeing the
directory disappear during regeneration. Case work directories are distinct.

Failures propagate through nonzero status; summaries record source/config
hashes, tools, effective options, timing and verdict. Selected stale PASS
files are removed before builds. CI uploads diagnostic logs and JSON even on
failure. Verilator is pinned to the repository's 5.036 baseline. The small
32-word private banks stress eviction and are not deployment defaults.

## Alternatives and costs

Keeping manual commands would preserve the original verification gap.
Adding Linux to every PR would increase runtime and image/toolchain requirements
without replacing directed bus-error and controller tests. Duplicating test
programs in CI would create a second maintenance surface; this proposal reuses
the existing runners instead. Four jobs cost more than single-hart lint but
isolate failures and can run independently on CI workers.

The matrix samples supported profiles; it is not a Cartesian product of every
cache option or a proof of arbitrary hart counts. RTL Linux, FPGA synthesis,
timing and board tests retain separate result scopes. See the
[execution record](../experiments/2026-10-21-multicore-ci.md).
