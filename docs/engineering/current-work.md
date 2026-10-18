# Current work

Checkpoint: 2026-10-18. Integration inputs: fork `main` at `50ad3a44a`
and official upstream `main` at `712ee9719467e9e9987cebd55926ae8e01b08770`.
Completed code integration: merge `e21d2a9e2`, published to `origin/main`;
all commits reachable from that upstream revision are included.
Use `git rev-parse HEAD` for the current checkout revision.
This is a branch-scoped checkpoint, not an automatic branch-selection policy.

## Objective and local work

Integrate the 88 upstream-exclusive commits into main and publish to origin,
preserving fork changes. The merge applied without conflicts; the Ubuntu
package/derivative recipe combinations were inspected. Two explicit RAM/ROM
casts were adjusted for installed-Verilator width checking. Seven lint
configurations and 18 directed RTL tests passed; see the
[integration record](experiments/2026-10-18-upstream-integration.md) for exact
scope, environment adaptations and evidence. No FPGA or ASIC run was done.

The knowledge bootstrap was published as `50ad3a44a`; original AGENTS content
remains preserved. Use `git log --merges` for the integration commit and
`git rev-parse HEAD` for the actual current revision.

## Confirmed completed development

| Branch / revision | Confirmed state | Evidence |
| --- | --- | --- |
| `main`, upstream integration | Official `712ee9719` integrated over `50ad3a44a`; fork container, line endings, Nexys Video and knowledge documentation retained | [Integration validation](experiments/2026-10-18-upstream-integration.md); no board-boot verdict |
| `multicore-support:f655debae` | Stages 1/2 (`17fcce818`) and stage 3 committed and pushed to origin; shared-cache Linux SMP test PASS on two Wally RTL harts | [ADR 0002](decisions/0002-shared-multicore-cache.md), [run record](experiments/2026-10-18-linux-smp.md) |
| `opensource-fpga-bitstream:23ba9c2a7` | LiteDRAM/VexRiscv diagnostics committed; DDR bring-up still reported failing | [Unresolved DDR record](experiments/open-ddr3-bringup.md) |

Multicore and the open FPGA flow are separate branches, not merged into this
main revision. The two existing untracked directories
`addins/riscv-arch-test-cvw/` and `addins/riscv-dv/` predate this task and must
remain untouched. Generated multicore evidence remains locally available
even though its source files are absent from the main checkout.

## Unresolved issues and knowledge gaps

- **DDR retest blocked by board access:** distinguish service-CPU startup,
  ROM/SRAM/register-file inference and actual DDR calibration. The remembered
  improvement without BRAM is an unverified hypothesis, not a resolved cause.
- **Multicore hardware not verified:** no synthesis/route/resource result or
  FPGA Linux SMP verdict; no private-cache MESI/DMA coherence validation.
  Linux RTL PASS covers two harts, not every supported parameter value.
- **Evidence portability:** SMP logs/manifests are on this host in ignored or
  external directories. They are not a repository-contained or remote archive.
- **Documentation drift:** preserved AGENTS suite/`--fcov` advice differs from
  current scripts; see [verification notes](verification.md). The HPTW design
  document has a historical branch header and a verification plan, not a new
  result. Synthesis README defaults differ from its Makefile.
- No exact historical SD image hash, complete earlier DDR observation log or
  revision-specific ASIC physical results were recovered. No access to
  unavailable conversations is assumed.

## Next actions, conditional on the user's engineering objective

1. For multicore work, inspect `f655debae` and account for main's updated
   MMU/hazard interfaces before integrating branches. Preserve evidence and
   revalidate the affected scope; do not transfer its older PASS automatically.
2. With Nexys Video access, resume the diagnostic matrix in the DDR record and
   record bitstream/tool hashes, observations and timing before claiming a fix.
   Moving initialization onto Wally remains a proposal, not completed work.
3. Refresh this checkpoint after a branch switch, completed change, newly
   observed failure or changed blocker. Do not begin these future engineering
   actions merely because they are listed here.
