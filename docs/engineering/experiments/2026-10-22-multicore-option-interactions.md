# Complementary multicore option-interaction coverage

Status: recommendation 10 implemented; targeted matrix and aggregate CI PASS.

## Question and scope

Do selected private/shared-cache options work independently and in risky pairs
outside the existing four named profiles? The regular profiles grouped local
reads/writes, private I-cache, forwarding, MESI, banks and bursts, so they did
not preserve evidence for several isolated choices.

The complementary matrix adds ten targeted RV64 simulations using existing
MSI, fabric, shared-cache and SoC benches. It is intentionally not a Cartesian
product. `tests/multicore/check_feature_interactions.py` runs the declared cases
and writes a machine-readable report mapping every supported feature and chosen
risky pair to cases and verdicts. `tests/multicore/run.py --focus` compiles only
the relevant cache or SoC target, avoiding repeated unrelated bus/peripheral
unit builds.

Cases cover minimal one-word MSI; local reads and local writes enabled alone;
MESI with one home and cache-to-cache forwarding; banked MSI without bursts;
single-home MSI with bursts; unequal I/D capacities and both line-size
orderings; shared-cache unit plus one- and two-hart SoC runs; and private
options on the single-hart bypass. Existing CI profiles remain responsible for
their RV32, latency 0/3, two/three-hart and broader full-core scope.

## Reproduction

From the repository root:

```bash
source ./setup.sh
python3 tests/multicore/ci.py --case all --work-dir sim/verilator/wkdir/multicore-ci-option-interactions
```

CI generates derivative configurations before running cases. For the
complementary suite alone, generate them first with `perl bin/derivgen.pl`, then
run `python3 tests/multicore/check_feature_interactions.py --work-dir
/tmp/cvw-feature-interactions`.

The report includes source commit, Verilator version, source hashes, per-case
commands, options, logs, semantic/traffic observations, and PASS/FAIL verdicts.
It also identifies external DMA coherence and precise CPU HRESP delivery as
unsupported; FPGA multicore timing/boot and arbitrary hart-count qualification
as unverified; and the full option product and unselected pairs as uncovered.

## Findings and limitations

The ten complementary targeted simulations and all four standard CI cases
passed on the implementation tree based on `2b944c085add77ecab7c08904ccc946447f0577b`.
The standard case times were 26.09 s (`single-default`), 67.46 s (`bus`),
23.42 s (`msi`) and 40.56 s (`mesi-banked`). The complementary case times are
recorded individually in JSON. The reads-only, writes-only,
and minimal MSI cases run two-hart RV64 controller benches at latency 0;
the selected MESI, banked and burst cases also use latency 0. Shared-cache and
private one-hart cases run full-core smoke with latency 0. Exact commands,
source hashes, tool version, logs and traffic counters are retained in the
ignored `sim/verilator/wkdir/multicore-ci-option-interactions-final/` output.
The aggregate recorded 408 source hashes, Verilator 5.036 and GCC 15.2.0.
Aggregate `results-all.json` SHA-256:
`c182787b02ef74841f00185ea92c72d8db4447db2f601b59d3f62a1ff0388901`.
Feature report SHA-256:
`5b0adb300d5e521778c8d0281f122317d98d69575ba4e2a081f608e867f78771`.

The isolated local-writes case exposed a stale expected value in
`msi_tb.sv::local_m_checks`: after checking a local byte store and peer
intervention on word 128, the later LR check still used the pre-store reference
value. Updating that scoreboard entry made the isolated case pass; no RTL
behavior changed.

This matrix is targeted RV64 evidence, not exhaustive parameter independence.
It does not establish Linux boot, RV32 behavior for every combination, FPGA
timing/boot, arbitrary hart scaling, DMA coherence or precise architectural
bus-error delivery. The existing CI profiles retain wider RV32, hart-count and
latency checks. Results do not qualify hardware or merge the feature branch to
main.
