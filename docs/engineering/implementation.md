# FPGA and ASIC implementation knowledge

The existing [FPGA README](../../fpga/README.md),
[Linux README](../../linux/README.md) and
[Design Compiler README](../../synthDC/README.md) own the operational flows.
No synthesis, implementation or board programming was performed for this
documentation task.

## Recovered flow boundaries

| Flow | Source of truth / checked facts | Evidence boundary |
| --- | --- | --- |
| Nexys Video, Vivado | [FPGA Makefile](../../fpga/generator/Makefile), [board constraints](../../fpga/constraints/constraints-nexysvideo.xdc), [DDR3 script](../../fpga/generator/ddr3-nexysvideo.tcl); target `xc7a200tsbg484-1`, 20 MHz system clock | Main commit `4985b3c6a` added boot preparation/documentation; that commit is not evidence of a successful board boot |
| Nexys Video, open tools | `23ba9c2a7`, [DDR3 experiment](experiments/open-ddr3-bringup.md) and its pinned flow document | Verified on the connected Nexys Video at `0513738ad`/`e8a62d239` (branch `opensource-fpga-bitstream`): `fpgaopensource` (RV32, 40 MHz) passed 973 DDR3 write/verify passes; `fpganexysvideo` (RV64GC, 12.5 MHz) booted OpenSBI and Linux to a BusyBox shell. Do not transfer these results to other boards, branches or clocks, or Vivado validation to this flow |
| ASIC synthesis | [synthDC/Makefile](../../synthDC/Makefile), [synth.tcl](../../synthDC/scripts/synth.tcl), [PPA tooling](../../synthDC/ppa) | Design Compiler synthesis/PPA tooling is present; no new area, timing or power results recovered here |

The Nexys Video boot explanation already documents the built-in initramfs and
the first three SD partitions containing DTB, OpenSBI and kernel. An expanded
ext4 data partition does not enlarge the built-in root filesystem. Earlier
card preparation/expansion was user-reported; the exact image hash and a
successful board boot are not recoverable from the available evidence.

Synthesis defaults in `synthDC/README.md` differ from the inspected Makefile
(`FREQ=10000`, `CONFIG=rv64gc`, `TECH=sky130` at `3585ff04e`). Pass intended
parameters explicitly and record effective constraints. A technology label
alone does not identify a library revision or PDK corner.

## Recording a physical implementation experiment

Extend an existing result record or add one under `experiments/` with:

- Source commit/patch, configuration, top module, board/part or PDK and exact
  library versions/corners, tools and seed, scripts and input hashes.
- Clock period/frequency, utilization/density targets, I/O constraints,
  uncertainty, exceptions and memory macro assumptions.
- Stage actually reached: synthesis estimate, placed, clock-tree synthesized,
  routed, post-route timing/physical verification, or measured hardware.
- Reports for area/resources, WNS/TNS and unconstrained paths, clock trees,
  routing/congestion and power assumptions/activity source. Label pre-route
  estimates separately from parasitic-aware timing and measured power.
- Failed timing/DRC checks and unexecuted checks, plus what each optimization
  changed and which comparable baseline it used. Screenshots supplement
  reproducible reports; they do not substitute for them.

No revision-specific OpenROAD study, routed ASIC result, PDK characterization
or multicore FPGA resource/timing result was recovered. Do not infer these
from scripts, textbook examples or the Linux RTL result.
