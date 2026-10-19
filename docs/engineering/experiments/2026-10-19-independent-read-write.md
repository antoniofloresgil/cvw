# Independent read hits during writes

Date: 2026-10-19. Branch: `multicore-support`, Git base `8ac2d4d6b`, plus
uncommitted stage-5 and this refinement. **PASS for the checks below; Linux for this refinement NOT RUN.**
The source-captured [stage-5 experiment](2026-10-19-private-l1.md) is the
comparison baseline, not proof for this change.

## Objective and implementation

Allow private I hits and ordinary private D read hits while another hart
writes a different physical word. Preserve blocking for the same word,
including byte stores, and preserve reservation/AMO ordering. Only
`ahbmulticore` changes functionally (the MSI module receives a comment update); its buffered addresses feed a full-word
hazard comparison shared by the I-enabled and I-disabled paths.
See [ADR 0005](../decisions/0005-independent-read-write-overlap.md).

The unit bench adds a positive overlap check for each read path, with
same-index/different-tag addresses, plus concurrent byte writes versus hot
reads of the same word. Its monitor rejects local replies that overlap a
write to that word. Three-hart cases also require two read hits to complete
simultaneously during the third hart's write. Existing dirty evictions, remote intervention, failures,
reset, randomized reference-model operations and hot-read AMO exclusion
remain active.

## Reproduction and scope

After `source ./setup.sh`:

```bash
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --unit-only --latency 0 3 --work-dir /tmp/wally-overlap-unit
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --suite atomic --cores 1 2 3 --latency 0 3 --work-dir /tmp/wally-overlap-soc
```

Exact expanded capacity/performance matrices and commands are in the local
helpers `/tmp/wally-write-overlap/units.py`, `regress.py` and `lint.py`.
No derivgen runs concurrently with these builds; existing generated configs
are used. Raw logs and binaries stay in that directory, outside tracked docs.

The 12 unit configurations cover RV32/RV64, two/three harts, waits 0/3,
capacities 2/4/8, and I-only/D-only/combined enables. Each executes directed
checks and 2,000 deterministic randomized operations. Nine full-core models
run atomic, smoke and UART images, matching the earlier 27-run comparison.
These are test scope/criteria until the final observed results below.

## Observed results

- **PASS:** 17 lint/structural checks: seven ordinary configurations,
  eight MSI parameter cases up to four harts, and two XML elaborations proving
  complete single-core removal with the feature requests off/on.
- **PASS:** 12 final controller configurations, directed checks plus 24,000
  deterministic randomized operations total. Independent I/D hits complete
  during writes, including two readers alongside one writer in three-hart
  cases. Same-word/byte-write conflicts remain blocked. Error/reset recovery,
  LR/SC and AMO tests remain active.
- **PASS:** all 27 full-core executions (atomic, smoke and UART) across nine
  parameter combinations. UART cases require exactly four THR writes. The
  single-hart atomic case remains exactly 7,446 cycles, matching the baseline.
- **PASS:** two negative controls: the frozen blanket-blocking arbiter fails
  the positive overlap requirement; a deliberately unsafe byte-address-only
  comparison fails the same-word safety check. Their nonzero model exits are
  expected, identified as such in negative-results.json. Fixtures stay outside
  the source tree and are not implementation failures.
- **PASS:** pre-commit checks and affected relative documentation links.

The baseline is the frozen stage-5 source manifest
`13911abc7b94ef3eb341fc2146f0802d8fef469b576a2b0ec3ea62a5c5971a65`.
All source differences are the arbiter logic, its directed tests and the MSI
module's explanatory comment. Only the arbiter changes functionally. Tooling:
Verilator 5.022 development v5.020-157-g2b4852048, G++ 11.4.0, bare-metal GCC
13.2.0 and Python 3.10.12; exact output is in tool-versions.json.

Atomic-program cycle comparison (RV64, RAM latency 3):

| Case | Harts | D words | I words | Before | After |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | 2 | 8 | off | 31,788 | 31,788 |
| ionly | 2 | 8 | 64 | 13,164 | 12,606 |
| donly | 2 | 8 | off | 32,768 | 32,784 |
| both | 2 | 8 | 64 | 12,778 | 12,325 |
| three | 3 | 8 | 64 | 18,960 | 18,553 |
| default | 2 | 256 | 256 | 12,374 | 11,989 |

With both options and 8-word D / 64-word I banks, cycles fall from 12,778 to
12,325, **3.55% fewer**. The 256-word I/D case improves from 12,374 to 11,989
(**3.11% fewer**). D-only is slightly slower on this workload: changed polling
interleaving can increase work, so this is not a universal speedup claim.
Cycle/traffic results for every suite are in results.json. Added physical
address comparators have not been measured for FPGA area or clock timing.

Source snapshot SHA256:
`47a6283001c3af3b68f2c81019234f71836bf50d889e27215fd16495e474024f` (sources.json).
Compact logs, test images, source inputs and metadata are archived locally in
`sim/verilator/wkdir/multicore/verification-write-overlap-20261019/`.
artifact-sha256.json identifies archive contents. These paths are host-local,
not remote archives; large models and checkpoints remain outside Git.

No Linux result for this refinement, FPGA timing or arbitrary-N behavior is
inferred from these controller/bare-metal results.


## Separate Linux run

`/tmp/wally-linux-l1-20261019/` continues running the **earlier stage-5 binary**
SHA256 `216da1b11e854984766b9adca9223f359a399d416ee024c836e3b3d4f636eb59`.
Its original inputs are frozen under
`sim/verilator/wkdir/multicore/verification-l1-20261019/inputs/` and identified
by its model.json. Editing the checkout does not change that executable.
Its eventual PASS/FAIL applies to those original inputs, not to ADR 0005.

For a strict resume after changing this checkout, use the frozen runner and
inputs, after sourcing the repository tool environment:

```bash
python3 sim/verilator/wkdir/multicore/verification-l1-20261019/inputs/linux/smp/run.py --work /tmp/wally-linux-l1-20261019 --reuse --resume --checkpoint /tmp/wally-linux-l1-20261019/resume.checkpoint --cycles 1500000000
```

Do this only after the original runner has stopped; its work-directory lock
rejects concurrent use. Do not rebuild, overwrite its model or relabel its
checkpoint as the new implementation. A Linux test of the new refinement
would need a separate model/work directory; it has not been started.
