# Current work

Checkpoint: 2026-10-18. Engineering code baseline: `main` at
`3585ff04e36a095188dfd5fbed39893cdc99114c`, before this documentation bootstrap.
Use `git rev-parse HEAD` for the current checkout revision.
This is a branch-scoped checkpoint, not an automatic branch-selection policy.

## Objective and local work

Establish persistent engineering knowledge while preserving existing workflow
documentation. Only the appended AGENTS section and `docs/engineering/` are
in scope. The documentation bootstrap is complete: the original AGENTS bytes
are preserved; local links, pinned source objects and preserved SMP evidence
were checked; pre-commit and `git diff --check` passed. No new RTL simulation
or hardware test was run for this task. The user has requested committing and
pushing this documentation on main. Use `git log -- AGENTS.md docs/engineering`
to identify the documentation commit; it does not merge the feature branches.

## Confirmed completed development

| Branch / revision | Confirmed state | Evidence |
| --- | --- | --- |
| `main:3585ff04e` | Development container; LF/CRLF rules (`c8b61c68a`); Nexys Video boot preparation (`4985b3c6a`) | Git history, `.devcontainer/`, `.gitattributes`, FPGA/Linux docs; no recovered board-boot verdict |
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

1. For multicore work, inspect `f655debae` and its existing test documentation;
   preserve evidence before cleanup. Revalidate the affected scope after any
   merge or architecture change; do not transfer its PASS to main automatically.
2. With Nexys Video access, resume the diagnostic matrix in the DDR record and
   record bitstream/tool hashes, observations and timing before claiming a fix.
   Moving initialization onto Wally remains a proposal, not completed work.
3. Refresh this checkpoint after a branch switch, completed change, newly
   observed failure or changed blocker. Do not begin these future engineering
   actions merely because they are listed here.
