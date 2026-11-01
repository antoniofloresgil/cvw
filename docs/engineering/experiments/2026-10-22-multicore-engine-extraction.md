# Multicore reservation and storage extraction

Status: **PASS for the checks below**. Source: `multicore-support:349263f55`
plus the recommendation-6 working tree identified by the final CI source hashes.
Comparison baseline: the unchanged RTL at
`349263f5575ae2a813cb28ff40b8a9f133dc6338`. No branch merge was performed;
the newer local main is not incorporated or validated by this result.
Decision scope: proposed [ADR 0018](../decisions/0018-multicore-engine-boundaries.md).

## Implementation and boundaries

- `multicore_reservations` owns per-hart LR/SC valid/address/size and retained
  SC results. The bridge supplies issue, completion, cross-home clear and local
  commit events. Grant selection, bus handshakes, reply states and AMO ownership
  remain in `ahbmulticore`/fabric.
- `multicore_icache_bank` owns instruction tags, validity and words. It receives
  explicit invalidation/fill events; the bridge retains refill sequencing,
  request buffering and mixed-geometry hazard suppression.
- `multicore_dcache_data` owns bulk data words, combinational local/word/line
  ports and clock-edge byte/line writes. The MSI/MESI controller keeps tags,
  permissions, snooping and transaction buffers. Word/line read selectors reuse
  ports where consuming controller states are disjoint.

Physical RAM allocation reuses recommendation 5's single package predicate.
No public SoC parameter, core pipeline port, configuration field, native single-hart
bypass or architectural error behavior changes. All-source flows discover the new
modules; explicit unit source lists now include their dependencies. Existing data
observation paths use a synthesis-excluded passive alias of the extracted storage.
This does not implement recommendation 9's general observation adapters.

The [storage/event contract](../interfaces/multicore-storage.md) defines edge
priorities, zero-cycle combinational reads, read-before-write sampling, whole-line
install plus byte merge, local-write concurrency and reset behavior. It explicitly
records the bandwidth and scheduling obstacles to synchronous BRAM replacement.
No synchronous RAM mode or inference/resource optimization is claimed.

## Reproduction

After successful setup and derivative generation:

```bash
source ./setup.sh
make deriv
lint-wally
python3 tests/multicore/check_engines.py --work-dir sim/verilator/wkdir/multicore-engines/units
python3 tests/multicore/ci.py --case all --skip-deriv --work-dir sim/verilator/wkdir/multicore-engines/ci
python3 tests/multicore/run.py --skip-deriv --shared-cache --suite atomic --cores 1 2 --latency 0 3 --cache-words 32 --work-dir sim/verilator/wkdir/multicore-engines/shared
python3 tests/multicore/run.py --skip-deriv --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --cache-words 8 --icache-words 8 --unit-only --latency 0 3 --work-dir sim/verilator/wkdir/multicore-engines/one-word
```

The bus CI case also selects check_engines automatically. It tests the three
extracted interfaces directly in RV32/RV64, including one/four-word I lines.
Each fixture has a finite simulated-cycle watchdog and a host execution timeout.
Keep derivative regeneration separate from concurrent model builds.

## Observed results

- Seven standard lints and seven CI topology lints passed with no warnings.
- Both direct engine fixtures passed: LR size/hazard checks, reservation consumption,
  sticky SC replacement, same-edge old/new LR word versus local commit, cross-home
  clear priority and partial-write granule invalidation. Storage checks cover
  partial/error I-fill visibility, one-word victim invalidation versus replacement,
  local/global I invalidation, combinational word reads, complete-line reads,
  line install plus byte merge with nonzero untouched bytes, independent local
  stores, metadata reset and retained data RAM contents.
- All four final CI profiles passed, including 16 real-adapter executions and six
  named negative endpoint checks, 28 full-core atomic/smoke executions, two native
  translated/cached AMO tests, 16 MSI/MESI coherence cases, four burst cases and
  common bus/atomic/peripheral checks. The existing 300-vector policy/DT suite
  also passed.
- Eight additional one-word private-cache cases passed: RV32/RV64, two/three harts,
  latency 0/3, private instruction banks and local D read/write paths enabled.
- The shared-cache cache unit and eight additional full-core atomic/smoke executions
  passed for one/two harts and latency 0/3, exercising the extracted reservation
  monitor with a one-hart serialized shared-cache path.
- 75 ordered PASS/traffic signatures match the pre-extraction evidence exactly:
  seven single-default signatures, 28 bus, 20 MSI and 20 MESI/banked. These include
  the 28 full-core programs' cycle counts and memory/local traffic counters. This
  is a directed behavioral/cycle comparison, not exhaustive formal equivalence.

The baseline is reused, revision-specific evidence from recommendation 5, not a
new run of older RTL. Before editing, all 391 baseline manifest source hashes were
checked against the clean parent checkout. The signatures and baseline manifest
hash were frozen in before-signatures.json. The final comparison is comparison.json.
The initial isolated fixture exposed a width warning in test address arithmetic;
it was corrected before the final fixture/CI run. Failed intermediate checks are
not counted as PASS.

## Evidence and limits

Evidence root: `sim/verilator/wkdir/multicore-engines/`. Final aggregate:
`ci/results-all.json`; direct fixtures: `ci/bus/engines/results.json`; baseline
and comparison: `before-signatures.json`, `comparison.json`. Additional logs:
`one-word/`, `shared/`, and `/tmp/cvw-engines-{ci,units,lint,shared,one-word,hooks}.log`.
The final aggregate records Verilator 5.036, RISC-V GCC 15.2.0 and exact
source/parameter hashes. All 396 recorded source hashes match the final tree.
Aggregate SHA-256:
`c3e33b3fc450d3977a0579e2c4fc9dd386fd04f0929f65831e2b76e792bf23db`.

A local archive of JSON/log evidence, baseline signatures and comparison results
is `sim/verilator/wkdir/multicore-engines/evidence-20261022/evidence.tar.gz`;
SHA-256: `9ba477089f152d5b641baee165fe44dbff438874c2eff0b02ea7bf57089498b3`.
It excludes compiled models and is not a remote durable backup.

No new Linux image build/RTL Linux or QEMU boot, complete ACT regression, formal,
four-state simulation, FPGA synthesis/resource/inference/timing or board boot was
run. Existing Linux results remain scoped to their original revisions. Tags and
coherence permissions remain controller metadata, so this is an incremental engine
boundary rather than a fully decomposed cache protocol. Recommendations 9–12 remain
separate proposed work. No merge into main or cross-branch capability claim follows
from these results.
