# Current work

Checkpoint: 2026-10-19. Checkout: `multicore-support`. Integration inputs:
`f655debaed2bda8dfa7635d1a78a8f32f66bffa7` and
`main:82d0b80f7d1471f224fc5a8fc307d75f5eb26f53`. Main already contains
official upstream `712ee9719467e9e9987cebd55926ae8e01b08770`.
Use `git rev-parse HEAD` for the current checkout revision.
This is a branch-scoped checkpoint, not an automatic branch-selection policy.

## Objective and local work

Merge main into the published multicore branch without rewriting its history,
then revalidate the combined RTL before continuing development. The merge
applied without text conflicts; shared atomics, hart IDs, derivative recipes,
walker-owned FP controls and per-hart WFI/hazard wiring were inspected.
Validation is in progress; see the
[integration record](experiments/2026-10-19-multicore-main-integration.md).

## Confirmed development boundaries

| Branch / revision | State | Evidence |
| --- | --- | --- |
| `main:82d0b80f7` | Official `712ee9719` integrated and published; fork container, line endings, Nexys Video and knowledge documentation retained | [Main integration](experiments/2026-10-18-upstream-integration.md) |
| `multicore-support:f655debae` | Original stages 1/2 and shared-cache Linux SMP implementation, previously published | [ADR 0002](decisions/0002-shared-multicore-cache.md), [original SMP run](experiments/2026-10-18-linux-smp.md) |
| `multicore-support`, combined sources | Main merged into the feature branch; current revalidation is recorded separately from the original PASS | [Current integration](experiments/2026-10-19-multicore-main-integration.md) |
| `opensource-fpga-bitstream:23ba9c2a7` | LiteDRAM/VexRiscv diagnostics committed; DDR bring-up still reported failing | [DDR record](experiments/open-ddr3-bringup.md) |

This integration updates the feature branch; it does not merge multicore back
into main or integrate the open FPGA branch. The existing untracked directories
`addins/riscv-arch-test-cvw/` and `addins/riscv-dv/` predate this work and must
remain untouched.

## Unresolved issues and knowledge gaps

- **DDR retest needs board access:** distinguish service-CPU startup,
  ROM/SRAM/register-file inference and actual DDR calibration. The remembered
  improvement without BRAM remains an unverified hypothesis.
- **Multicore hardware not verified:** no synthesis/route/resource result,
  FPGA Linux SMP verdict, private-cache MESI or external-DMA coherence result.
  A two-hart Linux result cannot establish arbitrary-N Linux support.
- **Evidence portability:** logs/manifests remain in local ignored or external
  directories, not a remote archive. Preserve them before cleaning the host.
- **Documentation drift:** preserved AGENTS suite/`--fcov` advice differs from
  current scripts; see [verification notes](verification.md). Historical HPTW
  plans and synthesis defaults must be checked against executable sources.
- No exact historical SD image hash, complete earlier DDR observation log or
  revision-specific ASIC physical results were recovered.

## Next actions

1. Complete combined-source verification and record the integration commit.
2. Continue multicore development from this updated feature branch, preserving
   the shared-cache/atomic contract and parameter-specific verification.
3. With Nexys Video access, resume the diagnostic matrix in the DDR record.
   Moving initialization onto Wally remains a proposal.
