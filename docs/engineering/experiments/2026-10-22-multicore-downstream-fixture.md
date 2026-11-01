# Shared downstream multicore test fixture

Status: implemented; standalone checker and all four standard CI cases PASS.

## Question and change

Can the one-home MSI and two-home banked-MSI benches share the downstream
pipelined AHB memory/fault model, passive protocol checks and common hart access
tasks without changing their topology-specific scenarios or results?

The benches now include `ahb_downstream_memory.svh` and
`ahb_master_tasks.svh`; both instantiate `ahb_downstream_checker.sv`. The
checker retains address/data stability checks across waits, SEQ continuity and
1 KiB boundary checks. The shared `access` task has a 10,000-cycle local
watchdog. Arbitration, bank routing, coherence scenarios, reference models,
reservation tests and overlap counters remain in their respective benches.

## Reproduction and evidence

Source baseline: `multicore-support:dfa738c602bfd9bd79e7cb6df49574952bad3b01`.
Verilator: 5.036 (`2025-04-27 rev v5.036`); compiler:
`riscv64-unknown-elf-gcc` 15.2.0. After `source ./setup.sh`, the shared fixture
negative tests run with:

```bash
python3 tests/multicore/check_downstream_checker.py --work-dir /tmp/cvw-downstream-checker
python3 tests/multicore/ci.py --case msi --work-dir sim/verilator/wkdir/multicore-ci-downstream-extraction-final
python3 tests/multicore/ci.py --case mesi-banked --work-dir sim/verilator/wkdir/multicore-ci-downstream-extraction-final
python3 tests/multicore/ci.py --case bus --work-dir sim/verilator/wkdir/multicore-ci-downstream-extraction-final
```

All four standard CI cases and the ten-case recommendation-10 matrix pass on
the extracted tree. Aggregate case times were 10.13 s (`single-default`),
25.20 s (`bus`), 16.69 s (`msi`) and 19.09 s (`mesi-banked`). The final
aggregate records 413 source hashes and source commit
`dfa738c602bfd9bd79e7cb6df49574952bad3b01`. Results are retained under
`sim/verilator/wkdir/multicore-ci-downstream-extraction-final/`. Aggregate
`results-all.json` SHA-256:

```text
e21bebe82f379288bf9a46e40717c8dc54b2d0215858a3f076edd8feac3e1da3
```

The aggregate feature interaction report SHA-256 is
`4081969d62d9eb577493289a074626f7b5e5c2fa7ad1a8602a9c172dfddd4f14`.

The standalone fixture passes valid INCR4 and stable write-wait traffic; two
intentional mutations fail with their named checker diagnostics: malformed SEQ
and changing write data during a wait. Both topology profiles pass with
assertions on, including RV32/RV64, latency 0/3, all existing read/write fault
positions, reset behavior, full-core smoke/atomic runs and lint. The bus case
also integrates the checker mutation test alongside the existing boundary,
observation and engine fixtures.

Pre-extraction model logs are in the ignored
`sim/verilator/wkdir/multicore-ci-option-interactions-final/` directory from
the preceding validated source. Post-extraction logs are in
`sim/verilator/wkdir/multicore-ci-downstream-extraction-final/`. Comparison of
the eight one-home MSI and twelve banked-MSI functional logs found all 20
behavioral signatures identical after excluding Verilator's source line,
wall-time and CPU-time lines. This includes exact SEQ, local-store, traffic and
overlap counts plus PASS verdicts. During extraction, the first comparison
found that the old sequential-beat count intentionally survived a mid-test
reset. The shared checker was adjusted to preserve that behavior; the final
20-log comparison then passed.

## Limits

The checker is passive and simulation-only. The shared memory fixture models
fault behavior needed by these tests; it does not qualify precise CPU error
delivery, external DMA coherence, FPGA timing or arbitrary topology scaling.
The watchdog bounds each common access task, while scenario synchronization
loops continue to use the existing bench-level timeout.
