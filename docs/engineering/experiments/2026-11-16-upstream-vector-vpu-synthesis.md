# Upstream `vector` branch (RVV VPU) on an Artix-7: synthesis of `rv64gc` against `rv64gcv` (2026-11-16)

What the vector unit of upstream's `vector` branch (openhwgroup/cvw, `2e233f3cb`, PR #2070) costs in FPGA resources, and what it is, read from the RTL.  The branch is a work in
progress (a vector unit in the style of RISC-V "V", not a neural-network unit like the AI unit of ADR 0024); it is 301 commits behind this repository's `main` (merge base
2026-11-06) and was not merged.  A local copy is the branch `vector` (fork: `origin/vector`).

## What it is

`src/vpu/` (22 files) instantiated in `wallypipelinedcore` when `ZVE32X_SUPPORTED`:

- `vcontroller` (with `vdecoder`, `vdispatcher`, `lmulsequencer`) decodes a vector instruction, splits LMUL > 1 into micro-ops and sends each to an execution unit (EU) that is free and able.
- EUs: integer (`vieu`, `VPU_INT_EU` = 2, each with `vlane`s of `valu`, `vmul`, `vshifter`; the parameters `VPU_INT_NO_MUL*` exist in the configuration but `vpu.sv` instantiates two identical `vieu`), one load/store interface (`vlsuif`) to the core's LSU, and
  floating-point EUs (`src/vpu/fpeu/`: `vflane`, `vfma`, `vfcvt`) that are **not instantiated** (`// *** add FPU` in `vpu.sv`).
- Completion: a queue of program order (`queue.sv`, depth 4 x EU) and a buffer of results (`svrf.sv`) let the EUs finish out of order; the oldest entry commits into `vregfile`.
- `vconfig` runs `vsetvli`, `vsetivli` and `vsetvl` in the scalar pipeline.  `hazard.sv` has its own vector stall and flush signals.
- Configurations `rv64gcv` and `rv32gcv` (`config/derivlist.txt`) set `ZVE32X`...`ZVFH` to 1 with `VLEN` = 256; `rv64gc` and `rv32gc` keep the vector off.
- The core is touched in `hazard.sv`, `ieu/controller.sv`, `ieu/datapath.sv`, `lsu/lsu.sv`, `ifu/bpred/bpred.sv`, `ifu/ifu.sv`, `cvw.sv` and `wallypipelinedcore.sv`.

Implemented (`tests/vector/act/rv64gcv/passing-Vx64.txt`, ACT through `bin/vector-act`): `vadd`, `vsub`, `vand`, `vor`, `vsll`, `vsrl`, `vsra`, `vmul`, `vmv.v.*`, `vmv.x.s` in the
`.vv`, `.vx` and `.vi` forms, and unit-stride loads and stores of one element.  Missing, from the comments in the RTL: `vl` is fixed to 1 in `vieu`, loads and stores move
element 0 only, no masks (byte mask all ones), no reductions, slides or gathers, `vcpop.m`/`vfirst.m` without a result, the multiplier is a 64-bit `A * B` whatever SEW,
only `vset` updates `vl`, `vtype` and `vstart`.

## Synthesis

Vivado 2024.2, `xc7a200tsbg484-1` (the Nexys Video), `synth_design -mode out_of_context -flatten_hierarchy rebuilt`, top `wallypipelinedcore` through the wrapper of
`synthDC/scripts/wrapperGen.py`, 20 ns clock, same flow and same RTL for both configurations (`rv64gc` has the VPU off, so the difference is the VPU).  Work in a git worktree
(`/datos/tmp/vector-wt`, no `setup.sh`), script and reports in `/datos/tmp/vector-synth/` (outside git).

| | `rv64gc` | `rv64gcv` | difference |
|---|---|---|---|
| Slice LUTs | 40,733 (30.3 %) | 52,261 (38.8 %) | +11,528 (+28 %) |
| Registers | 24,563 | 34,839 | +10,276 |
| DSP48 | 25 | 45 | +20 |
| BRAM tiles | 81 | 81 | 0 |

The `vpu` instance alone: 11,493 LUT, 10,219 registers, 20 DSP.  Inside it: `svrf` 1,272 LUT and 4,320 registers (the largest user of registers), `vieu[0]` 4,341 LUT and `vieu[1]` 1,574 LUT, both with 10 DSP
(the multiplier; the LUT difference between two identical instances was not investigated, probably logic merged across them), `vlsuif` 891 LUT and 360 registers, `vcontroller` 244 LUT, `vconfig` 207 LUT.  `vregfile` is
built from registers, not BRAM.

For scale: Coral NPU's Zvt matrix engine alone was 508,898 LUT on the same device (ADR 0024 study); this VPU is about 11.5 thousand LUT, but it does much less.

## With the floating-point units connected

The FP EUs are not connected upstream, so their cost was measured apart: `VPU_FP_EU` x `VPU_FP_LANES` = 2 x 4 = 8 instances of `vflane` (FMA, divide and square root, convert,
compare, sign injection, classify, reciprocal estimates; half, single and double precision), driven from ports so that synthesis keeps them (same flow, 50 ns clock).  Connecting them
into `vpu.sv` pruned them (the result went nowhere), which is why they are measured as a separate module and added.

| | LUT | Registers | DSP48 | BRAM |
|---|---|---|---|---|
| 8 x `vflane` | 66,470 | 6,888 | 72 | 0 |
| `rv64gcv` core without FP EUs (above) | 52,261 | 34,839 | 45 | 81 |
| **sum: `rv64gcv` with the FP EUs** | **118,731 (88 % of the device)** | **41,727** | **117** | **81** |
| `rv64gc` (VPU off) | 40,733 | 24,563 | 25 | 81 |

One lane is about 8.3 thousand LUT, 6,010 in `vflane` itself of which the divider (`fdivsqrt`) takes about 2,400 and the FMA about 600 LUT with 9 DSP.  Eight dividers are a choice
of the configuration (one per lane), not a need: fewer or shared dividers would cut the total.  The worst path of a lane alone, in synthesis, is about 50 ns (slack -0.011 ns at 50 ns):
longer than the integer core's 38.6 to 40.4 ns, so the FP lanes would set the clock.  The sum is an estimate (separate synthesis, no control, no glue, no placement); the real
design would be below it in logic shared with the core and above it in glue.  It does not fit the Nexys Video's Artix-7 200T with room for routing at 20 MHz.

`vflane.sv` of the branch does not elaborate as it is: it instantiates `fcmp`, `fsgninj` and `fclassify` with `#(P)` (the core's `cvw_t`) where those modules take `fpu_t`.  The
measurement used a copy with `#(FP)`; upstream has not connected it yet, so the error has not shown.

## Limits

- The first table is a lower bound: it leaves out the floating-point EUs (next section).  `VLEN` = 256 (default); the register file in flip-flops grows linearly with it.
- Synthesis only, no placement or routing, core alone (no uncore), unconstrained ports.  The worst setup slack at 20 ns is -18.6 ns (`rv64gc`) and -20.4 ns (`rv64gcv`): the path
  starts at the PTE register of the page-table walker in both, so it is inherited from the core; for `rv64gcv` it ends at `vregfile`.  Use the two figures to compare, not as an
  achievable clock.
- The branch was not built or simulated here: the ACT vector tests need a fork of riscv-arch-test (`bin/vector-act`, README in `tests/vector/act/`).

## Next

Follow `upstream/vector` (`git fetch upstream`); repeat the measurement when the FP EUs are connected and `vl` is real; run `bin/vector-act` if RVV in Wally becomes of interest (for example to
run auto-vectorized code of SPEC).
