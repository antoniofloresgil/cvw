# Nexys Video Vivado bitstream

## Scope and inputs

On 2026-10-20, built the existing Nexys Video Vivado target from `main` at
`82d0b80f7d1471f224fc5a8fc307d75f5eb26f53`. No RTL, constraints or build
scripts were changed. Configuration: `fpganexysvideo`, top `fpgaTop`, part
`xc7a200tsbg484-1`, CPU 20 MHz, DDR3 512 MiB, maximum SD clock 10 MHz.
The flow includes `small-debug.xdc` ILA instrumentation and uses the
`Performance_Explore` implementation strategy; no custom seed was specified.

Tool: Vivado 2024.2, SW Build 5239630, production speed file 1.23.
Existing cached IP was reused, including the Nexys Video 20 MHz MMCM and
DDR3 MIG. `addins/vivado-boards` was already checked out at
`36f34ab687b7fa9c778b779d027f3bce63b3ace9`, different from the superproject
gitlink; it was preserved. Ethernet dependency:
`c180b22ed5f4112d0ef35b2c5ac1acc45f9ebb5d`.
The external input manifest records hashes of 259 source/configuration/IP
files, including the regenerated bootloader memory inputs.

## Reproduction

From the repository root on this host:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
source ./setup.sh
make -C fpga/generator nexysvideo SHELL=/bin/bash '.SHELLFLAGS=-o pipefail -c' </dev/null
```

The shell override propagates Vivado failures through the Makefile's `tee`
pipelines. This build recompiles the zero-stage bootloader and regenerates
the copied RTL/configuration. Rebuilding IP on a clean machine requires the
board dependency and Vivado IP versions recorded above; this run does not
establish clean-cache reproducibility.

## Observed results

- Synthesis PASS: 0 errors, 0 critical warnings; 2626 ordinary warnings.
- Routed timing PASS for specified constraints: WNS +0.303 ns, TNS 0;
  WHS +0.021 ns, THS 0; no pulse-width violations.
- Routing: all 97,799 routable nets fully routed, 0 routing errors.
- Default DRC: 671 warning findings, no error or critical-warning findings.
  Bitstream generation completed successfully with 0 errors or warnings.
- Final utilization, including debug cores: 56,071 LUTs (41.66%),
  42,474 registers (15.78%), 92.5 BRAM tiles (25.34%), 25 DSPs (3.38%).
- CPU-domain worst setup path: HPTW `PTEReg/q_reg[22]` to data-cache
  `CacheWays[1]/word[2]` BRAM data input; data delay 49.464 ns, including
  39.801 ns routing, 50 logic levels, slack +0.303 ns at a 50 ns period.
  This implementation leaves little margin for a higher CPU frequency.
  A higher-frequency build and new timing closure are required to validate
  any increase; no maximum-frequency sweep was performed.

Timing coverage is limited by the existing constraints: `check_timing`
reports 8 inputs without input delay and 10 outputs without output delay
(GPIO, UART, SD and reset ports). There are no unconstrained internal
endpoints or unclocked register/latch pins. Timing PASS is not evidence of
complete external-interface timing coverage.

## Evidence and limitations

Generated bitstream: `fpga/generator/WallyFPGA.runs/impl_1/fpgaTop.bit`.
ILA probes: adjacent `fpgaTop.ltx`. The generated Vivado project is
`fpga/generator/WallyFPGA.xpr`.

Bitstream SHA-256:
`ecf56e9b9306d34b1ade9e83ca40de4b4da039af82906963e2823aeb79c31819`.

Host-local evidence directory (outside Git):
`/datos/cvw-artifacts/nexysvideo-vivado-20261020/`. It contains `build.log`,
`input-manifest.json`, archived bitstream/probes, `SHA256SUMS`, standard flow
reports, and `verify.tcl` with supplementary routed timing/DRC/route/resource
reports. The prior bitstream and reports were preserved under `previous/`.
Hashes in `SHA256SUMS` identify the exact artifacts; this directory is not
a repository-contained or remote archive.

## Hardware boot verification

Later on 2026-10-20, with the user's microSD installed, programmed this exact
bitstream into Nexys Video `210276BEBE99` through Vivado Hardware Manager.
The working hardware target is
`localhost:3121/xilinx_tcf/Digilent/210276BEBE99B`, device `xc7a200t_0`.
The unsuffixed target exposes no devices. Programming was volatile FPGA
configuration; no configuration flash or SD imaging operation was performed.

UART: FTDI `AV0JX7Y5`, `/dev/ttyUSB2`, 115200 baud, 8N1, no flow control.
Capture started before programming. Its first lines are the previously loaded
Nexys Video demo, followed by Wally after programming. The raw Wally output
includes NUL bytes; `uart-clean.log` removes only NULs for readability.

Observed hardware Linux boot **PASS to console**:

- Bootloader initialized SD SPI at 10 MHz, read GPT and loaded DTB at
  `0x9f000000`, OpenSBI at `0x80000000`, kernel at `0x80200000`.
  Kernel load completed at bootloader time 27.21680 seconds.
- OpenSBI v1.7 identified one HART, Nexys Video and a 20 MHz timer.
- Linux 6.19.14 reported 512 MiB physical RAM, entered `/init` and started
  BusyBox v1.37.0 from the built-in root filesystem.
- Linux detected the 29.5 GiB SDHC card and partitions `p1 p2 p3 p4`.
- The startup profile ran example commands as root, listed processes and
  filesystems, and reached `WallyHostname login:` on UART.

Observed userspace issues: network startup failed because `/sbin/ifup` is
absent; `crond` reported missing `/var/spool/cron/crontabs`. Neither prevented
the console from appearing. No network functionality was established.

Evidence: external `boot/program.tcl`, `boot/program.log`, `boot/uart.log`
and `boot/uart-clean.log` under the evidence directory above. The SD's exact
image hash and firmware/kernel build provenance were not verified from the
card; version strings above are observed console output. Successful boot
establishes DDR use in this run, but is not a standalone DDR calibration
measurement, memory stress test or validation of the separate open FPGA flow.
