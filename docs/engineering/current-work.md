# Current work

Checkpoint: 2026-10-19, branch `opensource-fpga-bitstream`.
Integration inputs: open-flow `23ba9c2a7511988e5bc954134505ac48d8777b35`
and `main:82d0b80f7d1471f224fc5a8fc307d75f5eb26f53`, including official upstream
`712ee9719467e9e9987cebd55926ae8e01b08770`.
Use `git rev-parse HEAD` for the resulting checkout revision.
This is a branch-scoped checkpoint, not an automatic branch-selection policy.

## Objective and completed integration

Merge main now to reduce later integration work while preserving the open
FPGA flow. README and package-installer conflicts were resolved by retaining
the FPGA tools and dependencies alongside main's Fedora and conditional
Vivado ncurses handling. FPGA dependencies are also selected for Fedora.
No RTL changes beyond the combined branch inputs were required.

Eight configuration lints, 18 directed RV32/RV64 RTL tests, package-selection
checks and branch-specific pre-commit checks passed. FPGA top elaboration
with a LiteDRAM interface stub completed with three clock/reset-model
warnings. See the [integration record](experiments/2026-10-19-open-fpga-main-integration.md)
for exact scope and limitations. The merge is prepared locally; publishing
is a separate operation. No FPGA synthesis, routing or board test was run.

## Branch boundaries and unresolved issues

- **Open FPGA DDR3 remains unresolved.** Service-CPU/BRAM diagnosis needs
  board access; ROM, SRAM and register-file inference must be distinguished.
  The remembered progress without BRAM is a hypothesis, not a confirmed fix.
  Follow the [DDR3 experiment](experiments/open-ddr3-bringup.md).
- **Physical implementation not rerun.** This host lacks the installed
  LiteX environment, nextpnr-xilinx, chip databases and Yosys Slang plugin.
  Port elaboration with a stub does not validate the service CPU, firmware,
  DDR training, routed timing or Wally's hardware handoff.
- **Multicore is separate.** `multicore-support:35cb2093b` contains main and
  the completed two-hart RTL Linux SMP revalidation, published to origin.
  It is not merged into this single-core open FPGA branch or main. Inspect
  that branch's scoped integration record before reusing its results.
- **Main remains separate.** `main:82d0b80f7` contains the earlier official
  upstream integration; this merge does not add open FPGA support to main.
- The two existing untracked directories `addins/riscv-arch-test-cvw/` and
  `addins/riscv-dv/` were left untouched. The existing clean submodule
  checkouts already match the merged pointers.
- Local experiment artifacts are not remote archives. There is no new board,
  ASIC, full ISA/nightly, lockstep or code-coverage result.

## Next actions, conditional on the user's objective

1. With the pinned FPGA tools installed, regenerate LiteDRAM/firmware and
   synthesize/route the combined revision; record hashes and timing domains.
2. With the Nexys Video available, execute the DDR diagnostic matrix and
   require calibration, memory testing and Wally execution separately.
3. Moving DDR initialization onto Wally remains proposed/deferred; do not
   begin that migration merely because it is described in the flow document.
