# Open-tool DDR3 bring-up: unresolved checkpoint

Status: **DDR initialization and memory test still fail on hardware; read-path
timing is narrowed but the cause is unresolved.**

The initial checkpoint below was recovered on 2026-10-18 from branch
`opensource-fpga-bitstream:23ba9c2a7`. It has since been retested on the
connected Nexys Video; see the 2026-10-23 follow-up.

## Scope and existing design record

Target: Nexys Video, Artix-7 `xc7a200tsbg484-1`. The branch's
[LiteDRAM flow document](https://github.com/antoniofloresgil/cvw/blob/23ba9c2a7511988e5bc954134505ac48d8777b35/docs/fpga-opensource-litedram.md)
already explains Yosys/nextpnr-xilinx, LiteX/LiteDRAM, the VexRiscv service CPU,
AHB/Wishbone bridge, memory map and shared system clock (40 MHz bring-up).
Consult its scripts for exact constraints. Wally remains reset until
`init_done && !init_error && !sys_rst`; the service CPU owns initialization
and UART before handoff. This differs from the main Vivado/MIG flow.

## Evidence and uncertainty

- Commit `0437faadd` adds the open flow; `23ba9c2a7` adds diagnostics and its
  commit message explicitly states initialization still fails.
- In that revision, `fpga/generator/gen_litedram.py` reports in a code comment
  that the service CPU boots in RTL simulation but its first hardware data
  access was `0x8` instead of `0x72a0`. It changes the VexRiscv **register-file**
  `ram_style` from `block` to `distributed` as an isolation experiment.
  This is a recovered observation, not independently inspected hardware logs.
- `fpga/src/fpgaOpenSource.sv` exposes reset/fetch/ACK/error, ROM-instruction,
  SRAM-copy and first-data-address diagnostics on selectable LEDs. Their
  presence proves instrumentation exists, not that DDR calibrated successfully.
- The user recalled progress when ROM/RAM did not use BRAM, but was unsure
  how far boot got. Treat that as a hypothesis. ROM, SRAM and the CPU register
  file are different inference targets; the implemented register-file change
  does not confirm a ROM/SRAM diagnosis or a working workaround.
- Exact failing bitstream hash, active dependency/tool versions, complete LED/
  UART observations and routed timing reports are missing from recovered
  evidence. Timing/area numbers in the flow narrative are not a newly verified
  physical result for this diagnostic revision.

Main was subsequently integrated on this feature branch; see the
[2026-10-19 integration record](2026-10-19-open-fpga-main-integration.md)
for executed RTL checks. The 2026-10-23 hardware follow-up below supersedes
the earlier statement that board access was unavailable.

## 2026-10-23 hardware follow-up

Test revision: `opensource-fpga-bitstream:fc2fc7063385a9d3659d997007ad57e74f1e65aa`.
The feature branch's merge base with `origin/main` was
`1d567764895321b64a9b8e28d0b77ca4b9eb0aac`. These tests used a standalone
LiteDRAM/VexRiscv diagnostic image, not the integrated Wally SoC or Linux.

Before the board test, the open-flow Yosys handoff was corrected. Deleting
`$buf` cells removed their loads and left 499 undriven wires in the generated
netlist. The build now runs `bufnorm -reset`, maps `$buf` with Yosys's
`techmap.v`, cleans unused wires, removes `$scopeinfo`, and asserts `check`.
`bufnorm -conn` was also rejected because this pinned Yosys loses the inout-pad
alias. The focused fixture in `tests/fpga/check_netlist_cleanup.py` checks both
ordinary and bidirectional aliases and confirms the old deletion is rejected.
With the corrected handoff, the service CPU's first data address on hardware
was `0x72a0`, matching the firmware initializer; this resolves the earlier
`0x8` first-access observation for this diagnostic image, but does not prove
DDR reads work.

Three 80 MHz standalone images were built with `PROBE_CONNECT_BUFFERS=2`,
`PROBE_ROUTER=router1`, and the board's tested `ddram_reset_n` setting of
`LVCMOS15`. The generated FASM's single VREF feature was changed from 675 mV to
750 mV before frame/bit generation. All three were loaded over JTAG. The final
sample image used bitstream SHA-256
`f941961fbcdf372dd94a1e5e896568f732ed5201969801423191644ab52f1142`; its
post-route estimate passes 80 MHz (88.35 MHz for the service CPU clock; DDR
PHY clock 320 MHz / 640 MT/s). The Yosys post-cleanup check reported zero
problems. The earlier VREF/reset tests,
all four read-phase and write-phase overrides, MPR reads, and the prior 40 MHz
build also failed to produce valid DDR data; raising the CPU clock is not a
fix.

The latest image captures DQ after IDELAY on `sys4x_clk`, around the first
`rddata_valid` window with FPGA DQ output disabled. Its first four samples
(one immediately before the window, the first inside it, and the next two)
were all `16'hffff`. The OR of all four DFI read-data phases while valid was
`32'h00000000`. The direct ISERDES-Q probe separately saw both 0 and 1 in most
lanes during valid windows, while DFI read data remained zero. Across repeated
frames the BIOS reported `init_done=1`, `init_error=1`; earlier BIOS telemetry
reported all-zero read leveling and a failed memory test (256/256 bus errors,
8191/8192 address errors and 524288/524288 data errors).

This narrows the problem to the external DDR data window or its alignment with
LiteDRAM's delayed read-valid/ISERDES path. The follow-up phase90 probe samples
the outputs of the DQS input buffers (not the output pins) on the PLL's
90-degree `sys4x_dqs_clk`: all eight samples for both lanes, before and after
the read window, were high (`32'hffffffff`). Eight-cycle DFI histories show
both `rddata_en` and the internal READ command in phase 3 only (`32'h80000000`
for each history). Across 53 repeated UART frames, this is stable; the frames
also report `init_done=1` and `init_error=1`. No external DDR command-pin
waveform was captured, and a finite digital sample cannot rule out a shorter
DQS transition between sample edges. The data still cannot distinguish a
DRAM that is not driving from displaced sampling or a command/PHY timing issue,
so this remains a diagnostic hypothesis rather than a confirmed root cause.

The final phase90 diagnostic bitstream SHA-256 is
`6aa12730e112c6dbe10b4fe41418f990c968121e1a922b5bbfc3de2285e9dec0`; it is
in `probe-80mhz-ddr-strobe/probe-vref750.bit` under the artifact directory
below. It passed the 80 MHz post-route service-CPU timing target (97.26 MHz).
This volatile image is what remains loaded on the board; it does not test Wally
or Linux.

The reproducible hardware artifacts and UART logs are outside the repository
at `/datos/cvw-artifacts/ddr3-bringup-20261023/`, especially
`probe-80mhz-dq-window-samples/` (bitstream, FASM, route/synthesis reports and
UART capture) and `probe-80mhz-dq-iserdes/`. The pinned host tools reported
Yosys `0.69+152` (`6f876ae0e-dirty`), nextpnr-xilinx `8f178fc6`, LiteX
`8c01073a`, and LiteDRAM `74522f71` at test time; the full LiteX composite
version was recorded in `$RISCV/versions/litex.version`.
The JTAG image is volatile and is not a Wally/Linux boot image.

## Next experiment

Snapshot DFI CKE and RESET_N, including each phase, at the first internal READ
and `rddata_en` event; then verify how those signals map into the DDR output
serializer and compare with a Vivado/MIG or external command waveform. This
will check whether the memory is enabled and out of reset when read commands
are issued. Preserve the failing image and source, firmware, constraint, and
bitstream hashes. Require successful calibration plus memory testing before
claiming DDR works; require Wally execution separately before claiming the
full handoff works.

The documented plan to run initialization directly on Wally (commit
`3b30ba6b6`) remains **proposed/deferred**, explicitly conditional on first
getting the service-CPU flow working. It is not an accepted replacement or
completed implementation. The branch narrative predates some diagnostics;
check the pinned code before repeating its older next-step list.
