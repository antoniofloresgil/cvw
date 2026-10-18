# Open-tool DDR3 bring-up: unresolved checkpoint

Status: **FAIL reported; hardware retest BLOCKED by board access**.
Recovered 2026-10-18 from available discussion and branch
`opensource-fpga-bitstream:23ba9c2a7`. No new build or board test was run here.

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

## Next experiment when hardware is available

Preserve a failing baseline and vary ROM, SRAM and register-file inference
independently. Record source/generated-gateware/firmware/bitstream hashes,
tool pins (including the installer's LiteX version record), constraints and
timing reports. Observe actual reset, fetch and reset-vector data, first data
address, ACK/error and firmware SRAM copy, then UART and DDR init status.
Require calibration plus memory testing before claiming DDR works; require
Wally execution separately before claiming the full handoff works.

The documented plan to run initialization directly on Wally (commit
`3b30ba6b6`) remains **proposed/deferred**, explicitly conditional on first
getting the service-CPU flow working. It is not an accepted replacement or
completed implementation. The branch narrative predates some diagnostics;
check the pinned code before repeating its older next-step list.
