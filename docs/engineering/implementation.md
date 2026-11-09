# FPGA and ASIC implementation knowledge

State at 2026-11-09, `main` of the fork. This note says which implementation flows the repository has, where each is
documented, and how far each has been verified. The operational documents own the commands: the
[FPGA README](../../fpga/README.md), [open FPGA flow](../fpga-opensource-litedram.md), [Linux README](../../linux/README.md),
[Design Compiler README](../../synthDC/README.md), [open ASIC flow README](../../asic/librelane/README.md) and
[test board README](../../hardware/board/README.md). Documentation work alone establishes no synthesis, simulation or
hardware result.

## Flows and how far each has been verified

| Flow | Source of truth | Evidence boundary |
| --- | --- | --- |
| Simulation and regression (Questa, Verilator, VCS) | `bin/wsim`, `bin/regression-wally`, `bin/lint-wally`, [sim/](../../sim), the riscv-arch-test configuration in `config/<cfg>/act` ([CLAUDE.md](../../CLAUDE.md)); CI in `.github/workflows` (`lint.yml`, `multicore.yml`, `install.yml`) | Verilator is the default for the regression and needs no license. The fork's CI runs the Python lint on every PR and the multicore matrix when a PR touches the RTL, the configurations or the multicore tests (`multicore.yml`); the long simulations run locally. |
| FPGA with Vivado | [FPGA Makefile](../../fpga/generator/Makefile), [constraints](../../fpga/constraints), boards ArtyA7, vcu108, vcu118, genesys2, nexysa7, nexysvideo and qmtechk7; Nexys Video: `xc7a200tsbg484-1`, 20 MHz system clock, DDR3 from Xilinx MIG | Linux booted on the Nexys Video with it ([record](experiments/2026-10-20-nexysvideo-vivado.md)). Main commit `4985b3c6a` added the boot preparation and documentation; that commit is not evidence of a board boot. |
| FPGA with the open tools (Yosys + slang, nextpnr-xilinx 0.9.8 from openXC7 with `bin/installation/nextpnr-xilinx-lutram-clkinv.patch`, Project X-Ray) | [open flow](../fpga-opensource-litedram.md), [build-opensource.sh](../../fpga/generator/build-opensource.sh), [DDR3 bring-up](experiments/open-ddr3-bringup.md), [Wally runs the DDR3 initialization](experiments/2026-11-01-wally-runs-ddr3-init.md) | Only the Nexys Video has been verified on hardware: `fpgaopensource` (RV32IMC, 40 MHz) passed 973 DDR3 write/verify passes, and `fpganexysvideoopen` and `fpganexysvideo` (RV64GC, 12.5 MHz) boot OpenSBI and Linux to a BusyBox shell. Arty A7 and Nexys A7 build a reduced configuration with internal BRAM and have not been run. Do not transfer these results to other boards or clocks, or Vivado results to this flow. |
| ASIC synthesis with Design Compiler | [synthDC/Makefile](../../synthDC/Makefile), [synth.tcl](../../synthDC/scripts/synth.tcl), [PPA tooling](../../synthDC/ppa) | The tooling is the upstream one and has not been run for this fork. Its documented defaults differ from the inspected Makefile (`FREQ=10000`, `CONFIG=rv64gc`, `TECH=sky130` at `3585ff04e`): pass the intended parameters explicitly and record the effective constraints. A technology label does not identify a library revision or a PDK corner. |
| Open ASIC flow (LibreLane, IHP SG13G2 and SG13CMOS5L) | [asic/librelane](../../asic/librelane/README.md), [ADR 0022](decisions/0022-asic-microcontroller.md), [experiment record](experiments/2026-11-02-open-asic-flow.md) | `asic_soc_rv32imac` goes from RTL to a checked GDS with open tools only. Not fabricated, and no shuttle precheck has been run. See the numbers below. |
| RTL simulation of the chip (`make chipsim`, `make sramsim`, `make boardsim`) | [test_chip.py](../../asic/librelane/chip/test/test_chip.py) (cocotb and Verilator, with the IHP pad and SRAM models), [sram/](../../asic/librelane/sram), [board/sim](../../hardware/board/sim) | 15 `chipsim` tests: the bootloader (flash, UART, JTAG), atomics, PMP, the 64 KiB RAM, FreeRTOS, five Zephyr images and a halt of Zephyr's idle thread, the MCU peripherals and the instruction trace. All pass on the RTL; none runs on the netlist or on silicon. |
| Test board (KiCad 10) | [hardware/board](../../hardware/board/README.md), [ADR 0023](decisions/0023-mcu-test-board.md) | Rev A (chip soldered) and rev A-S (QFN 32 test socket) are generated and routed by Python scripts; the DRC reports no unconnected items or electrical violations (only silkscreen clipped by the board edge) and the schematic ERC is clean. Not fabricated. The socket's contact-to-pin map is unverified. |
| The chip on the Nexys Video (open tools) | branch `fpga-chip-nexysvideo` (not in `main`): `make nexysvideochip`, `fpga/src/fpgaChip.sv`, `docs/fpga-chip.md` on that branch | The bitstream builds in about 5 minutes (20,215 LUTs, 16 RAMB36), loads on the Nexys Video, and Zephyr's isolation demo runs on it through the UART bootloader (2026-11-09); that run is described in the branch's `docs/fpga-chip.md`. |

## The chip, `asic_soc_rv32imac`, as of the last full flow

RV32IMAC with 16 PMP entries, the JTAG debug port with 4 triggers and the E-Trace instruction trace (whose buffer is the
last 8 KiB of the RAM), the MCU peripherals (timer with PWM and capture, watchdog, I2C, RTC), 64 KiB of RAM in eight
IHP SRAM macros, and a bootloader in the BOOTROM that loads a program from an SPI flash or over the UART.
In SG13G2, at a 50 ns clock, in a 2.752 mm die:

| Item | Value |
| --- | --- |
| Standard cells | 90,429 (1.21 mm², 61 % of the area outside the macros) |
| Setup / hold | +3.41 ns in the slow corner / +0.04 ns in the fast corner |
| KLayout DRC, LVS, antenna, disconnected pins | 0 errors each |
| Magic DRC | only the waived findings (1,414 inside the macros) |
| Power | 19 mW |

The sources of these numbers are the run directory (`asic/librelane/work/asic_soc_rv32imac/runs/RUN_*`, git-ignored)
and the [README](../../asic/librelane/README.md), which also lists the earlier results and the DRC policy. The die is the
largest that passes the KLayout antenna rule `Ant.e` at the input pads, so the chip cannot grow without a new layout.
Any RTL change to the SoC or to `chip/boot.S` (the bootloader is preloaded in the BOOTROM) invalidates the GDS and needs a
new physical run of about 8 hours. At 45 ns the PMP comparators missed setup by 0.12 ns, and the maximum slew and
capacitance findings of the last run have not been reviewed.

## What is not established

- No chip, board or shuttle submission exists; no silicon measurement exists.
- The IHP shuttle precheck of the GDS has not been run.
- The firmware (FreeRTOS, Zephyr) has run on the RTL, and Zephyr's demo on the FPGA build of the chip; neither has run on silicon.
- Revision-specific Design Compiler or OpenROAD results for upstream Wally configurations, and multicore FPGA resource
  or timing results, have not been recovered. Do not infer them from scripts, textbook examples or the Linux RTL result.

## Nexys Video boot

The Nexys Video boot explanation already documents the built-in initramfs and the first three SD partitions containing DTB,
OpenSBI and kernel. An expanded ext4 data partition does not enlarge the built-in root filesystem. Earlier card
preparation and expansion was user-reported; the exact image hash and a successful board boot with that card are not
recoverable from the available evidence.

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
