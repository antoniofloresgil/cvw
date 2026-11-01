# Explicit multicore capability and qualification scope

Status: **PASS for the checks below**. Source: `multicore-support:1a40aaac2`
plus the recommendation-7 working tree identified by the final CI source hashes.
Decision: proposed [ADR 0019](../decisions/0019-multicore-capability-scope.md);
public scope: [capability/integration contract](../interfaces/multicore-capabilities.md).
No branch merge was performed.

## Implemented scope

The shared profile schema now distinguishes implemented hart-path coherence,
unsupported external DMA coherence/precise CPU HRESP delivery, and unverified
multicore FPGA/arbitrary-hart qualification. Path-specific reports identify native
bypass, uncached serialization, shared write-through and private write-back behavior,
including retained dirty ownership and possible partial memory effects on errors.
The CLINT range is explicitly addressability; Linux's maximum is an image-recipe
bound. Legal overrides remain available for experiments without implying evidence.

Capability reports distinguish topology-only descriptions from core/topology
constraint validation and never label that validation as runtime qualification.
Effective SV reports and Linux manifests include canonical capability metadata;
DT generation rejects edited/stale claims. Optional --require-capability checks
reject unavailable properties before compilation, for every requested hart count.
Schema version 2 adds capability-contract version 1; existing Linux image manifests
must be regenerated through the maintained builder.

CI results separately name the executed full-core counts, widths and latencies,
transport-only injected-error scope and NOT RUN Linux/FPGA qualification. Existing
single-default native compatibility tests retain their separate scope. The new
experimental soc_tb/Linux fault guard stops on global or hart-side HRESP outside
reset. It does not alter CPU error propagation; failed SC with OKAY remains legal.
Intentional error injection remains in the controller/adapter fixtures.

The integration contract defines prerequisites/acceptance criteria for coherent
or isolated noncoherent external writers, precise request-associated CPU errors,
dirty-writeback policy, FPGA and per-count scaling evidence. It implements none
of those future hardware interfaces. No coherence engine, CPU retirement datapath,
DMA ingress, trap delivery, rollback or automatic retry is added.

## Reproduction

```bash
source ./setup.sh
make deriv
python3 config/multicore/profiles.py --describe --profile ci-msi
python3 tests/multicore/check_capabilities.py --work-dir sim/verilator/wkdir/multicore-capabilities/units
lint-wally
python3 tests/multicore/ci.py --case all --skip-deriv --work-dir sim/verilator/wkdir/multicore-capabilities/ci
```

An unsupported property is rejected before a build:

```bash
python3 tests/multicore/run.py --profile ci-msi --require-capability external_dma_coherence
```

This command intentionally fails; it is not a DMA test. Generation of a profile,
DTB or model must not be recorded as hardware/scaling/boot qualification.

## Observed validation

- Shared schema generation freshness, seven standard lints, scoped pre-commit
  and documentation link checks passed.
- Capability tests exercised native bypass, uncached, shared one-hart, MSI and
  banked MESI paths. Unsupported/unverified requirements are rejected; forged DMA
  availability metadata is rejected. Counts 2/3/4/8/4095 in topology-only reports
  remain unqualified for arbitrary scaling; no large-count RTL model was built.
- Both unsupported DMA and a mixed 1/2-hart request requiring the buffered coherent
  path were rejected before model creation. The latter checks each count rather
  than accepting the matrix just because its maximum count uses the buffered path.
- The full-core guard passes reset/fault-free execution. BAD_GLOBAL and BAD_HART
  exit nonzero with the specific transport-only/fault-free diagnostic; arbitrary
  process failure or timeout is not accepted as detection.
- All four final CI profiles passed, including the capability suite, 300 Python/SV
  policy vectors and DT consistency checks, isolated engine fixtures, seven topology
  lints, 16 real adapter executions, six named negative endpoints, 28 full-core
  atomic/smoke runs, two native AMO programs, 16 coherence and four burst cases,
  and common peripheral/bus/atomic tests. Transport error/writeback checks still
  execute separately and do not acquire architectural recovery qualification.
- All 75 frozen baseline PASS/traffic/cycle signatures match parent-source evidence
  exactly. Thus the tested fault-free program cycle/traffic behavior is unchanged.
- A two-hart MSI Linux harness model compiled with the new guard and canonical
  metadata. It used synthetic DT/manifest fixtures for --build-only, not bootable
  software images; this is compilation evidence only.

The baseline reuses recommendation-6 evidence. All 396 baseline source hashes were
checked against committed parent `1a40aaac2`, following tracked linker-script
symlinks to their file contents. The baseline aggregate SHA-256 is
`c3e33b3fc450d3977a0579e2c4fc9dd386fd04f0929f65831e2b76e792bf23db`.
No new baseline simulation is claimed.

## Evidence and limits

Evidence root: `sim/verilator/wkdir/multicore-capabilities/`. Final matrix:
`ci/results-all.json`; capability/guard checks:
`ci/single-default/capabilities/results.json`; exact comparison:
`before-signatures.json`, `comparison.json`. Linux compilation metadata is under
`linux-model/`. Logs include `/tmp/cvw-capabilities-{ci,units,profiles,lint,hooks,linux-model}.log`.

The final aggregate records Verilator 5.036 and RISC-V GCC 15.2.0. All 399 source
hashes match the final tree. Aggregate SHA-256:
`0b97c7741549d4419a492528ea8a514bf00359d6f95dea59a751abafa8c29f05`.
Local evidence archive: `sim/verilator/wkdir/multicore-capabilities/evidence-20261022.tar.gz`
(SHA-256 `9a7f5a17f8fa1213296a3f93b904e39ce3a8085ee29a8681429a6f12d0a0b772`). This is a local artifact, not a remote backup.

No external DMA/coherent-ingress test, precise CPU HRESP trap/recovery test,
new Linux software image build or Linux/QEMU boot, arbitrary-count execution,
full ACT regression, formal, four-state run, FPGA synthesis/inference/resource/
routed timing or board boot was performed. The capability report preserves those
limits instead of promoting parameter validity or a transport PASS into evidence.
Historical results remain scoped to their original revisions. Recommendations
8 and 9–12 remain separate proposed work.
