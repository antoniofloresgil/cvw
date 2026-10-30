# Open-source FPGA flow with LiteX/LiteDRAM DDR3

This document describes the open-source (Yosys + nextpnr-xilinx) FPGA flow for
CORE-V-Wally on the Digilent Nexys Video, and in particular how external DDR3
memory is provided by LiteX/LiteDRAM instead of Vivado's MIG.

## Goal

Build a CORE-V-Wally SoC for the Nexys Video **without any Vivado-generated
IP**, using DDR3 for memory. The whole design (Wally + clocking + DDR3
controller/PHY + bus bridge) is synthesized, placed and routed by Yosys and
nextpnr-xilinx, and turned into a bitstream by `fasm2frames`/`xc7frames2bit`.

## Why not Vivado's MIG

Vivado's Memory Interface Generator (MIG) cannot be reused in an open-source
flow:

- it is delivered as **encrypted netlists plus a large set of implementation
  constraints**, not as portable RTL;
- the 7-series DDR3 PHY relies on `ISERDESE2`/`OSERDESE2`, calibrated
  `IDELAYE2`/`ODELAYE2`, `MMCM`/`PLL` and DDR data-group floorplanning;
- nextpnr-xilinx cannot import the MIG, and cannot apply its place-and-route
  requirements.

In other words, DDR3 via the MIG forces the entire implementation back into
Vivado. That defeats the purpose of the open-source flow.

## Decision: LiteX/LiteDRAM as the open DDR3 IP

[LiteX](https://github.com/enjoy-digital/litex) + [LiteDRAM](https://github.com/enjoy-digital/litedram)
provide an open DDR3 controller and PHY that synthesize with Yosys/nextpnr. The
Nexys Video is already supported upstream in
[`litex-boards`](https://github.com/litex-hub/litex-boards)
(`litex_boards/targets/digilent_nexys_video.py`), which uses the `MT41K256M16`
module (256M x 16 DDR3) and the `A7DDRPHY`, including the calibration logic.

Wally only consumes the **LiteDRAM controller + PHY** at the bus level: the
AHB/Wishbone bridge attaches to a single LiteDRAM user port. Internally the
standalone generator still instantiates a small LiteX SoC (a VexRiscv service
CPU with its ROM/SRAM and CSR interconnect) because DDR3 initialization and
leveling are software-controlled; none of that is exposed to Wally.

### LiteX is an installed tool, not a vendored dependency

LiteX is a host-side code generator (Python), so it is handled like the rest of
the open-source FPGA toolchain (Yosys, nextpnr, prjxray): installed into
`$RISCV`, version-pinned, and never committed as RTL.

- `bin/installation/litex-install.sh` creates `$RISCV/litex-venv` and installs
  `migen`, `litex`, `litedram`, `liteeth` and `litex-boards` from **pinned
  commits** (non-editable installs, which are reliable on recent
  Python/setuptools). It records the composite version in
  `$RISCV/versions/litex.version`.
- It also creates the nextpnr chipdb aliases LiteX expects
  (`xc7a200t-sbg484.bin`, `xc7a100tcsg324.bin`), because LiteX derives the
  chipdb filename from the full part name while the FPGA toolchain installs
  chipdbs named after the die.
- `setup.sh` exports `LITEX_VENV`, `PRJXRAY_DB_DIR` and `CHIPDB`.
- `bin/wally-tool-chain-install.sh` invokes it right after the FPGA toolchain.

## Gateware generation

`fpga/generator/gen_litedram.py` (driven by `gen-litedram.sh` / `make litedram`)
uses the **official LiteX standalone core generator** (`litedram.gen`) with a
`vexriscv` service CPU. This is essential: LiteDRAM's DDR3 initialization and
PHY leveling are **software-controlled** routines that run through the DFII/CSR
registers (`sdram_init()`), so a raw `LiteDRAMCore` never becomes usable on its
own.

The generator emits, into `fpga/generator/opensource-litedram/`:

- `litedram_core.v` (the LiteX core), plus `VexRiscv_Min.v` and the ROM/SRAM
  `.init` images;
- `litedram_ddr.v`, a small in-repo wrapper that instantiates the core, adds a
  power-on reset, and renames the ports to the ones the board top expects
  (`sys_clk`, `init_done`, `init_error`, `uart_*`, `wb_*`, DDR3 pads);
- `litedram_ddr.xdc`, with the DDR3 pin and timing constraints.

The ROM image is loaded with `$readmemh`, whose paths are rewritten to absolute
ones after generation so Yosys finds them regardless of its working directory
(this must happen *after* copying `platform.sources`, which would otherwise
overwrite the patched file).

## Clocking

The DDR controller always runs at `sys_clk_freq = 40 MHz` (DDR3 at 320 MT/s).
`litedram_ddr` exports Wally's clock as `wally_clk`, in one of two ways:

- **Shared clock** (default, `fpgaopensource`): `wally_clk` is the DDR
  controller's `sys_clk`, so the AHB/Wishbone bus needs no clock-domain
  crossing.
- **Separate clock** (`gen_litedram.py --user-clk-freq`, used by the
  `fpganexysvideo` Linux configuration): the LiteDRAM PLL gets one more output
  for Wally, and the crossbar port crosses into it through LiteDRAM's own
  asynchronous FIFOs (`LiteDRAMNativePortCDC`). The bridge itself stays
  single-clock. This lets Wally run slower than the DDR controller, which the
  RV64GC design needs because it does not close timing at 40 MHz.

Wally is held in reset (`reset_ext`) until the DDR initialization firmware
reports `init_done` without `init_error`, and the board UART is switched from
the initialization firmware to Wally once the DDR is ready.

## Bus bridge: AHB-Lite slave to Wishbone master

`src/uncore/ahbwishbonebridge.sv` connects Wally's external-memory AHB port to
LiteDRAM's Wishbone slave.

- Every AHB transfer, including each beat of a cache-line burst, becomes one
  Wishbone transaction. The next beat's address phase coincides with the
  current beat's Wishbone ack, so the bridge goes straight to the next request
  instead of returning to idle; otherwise every other burst beat would complete
  without reaching the DDR.
- The data width is Wally's `AHBW` (32 or 64 bits); the Wishbone port has the
  same width and LiteDRAM converts it to its 128-bit native port.
- Byte enables come from `HWSTRB` (the AHB write strobe used throughout the
  uncore), not from `HSIZE`.
- The region select is **registered** in the bridge. The SoC exposes the
  *combinational* `HSELEXT`; using it directly would close a loop
  `HREADYOUT -> HSELEXT -> HSIZE -> HREADY -> HTRANS` through the core's bus
  FSM and the address decoder.
- `HRESP` is always `OKAY`; the bridge inserts AHB wait states (`HREADYOUT`,
  driven by the Wishbone `ack`) until the transaction completes.

## Memory map

The open flow builds one of two configurations, selected with `OPENCONFIG`:

| Configuration | ISA | Boot | DDR3 window |
|---|---|---|---|
| `fpgaopensource` (default) | RV32IMC | program in the 64 KiB IROM at `0x80000000` | `0x40000000`, 128 MiB |
| `fpganexysvideo` | RV64GC (as in the Vivado flow) | ZSBL in the boot ROM, Linux from the SD card | `0x80000000`, 512 MiB |

The bridge uses `HADDR[28:0]` as the offset into the 512 MiB device; both bases
are aligned to their windows.

## Build flow

`fpga/generator/build-opensource.sh` (for the Nexys Video):

1. generates the LiteDRAM gateware (`gen-litedram.sh`);
2. merges the DDR3 pin constraints into the board constraints, dropping the
   `clk100`/`cpu_reset_n`/`create_clock` entries that the board XDC already
   provides under the SoC's own port names;
3. reads the Xilinx cell libraries (`cells_sim.v`, `cells_xtra.v`) and
   `litedram_ddr.v` (with `read_verilog`, which tolerates parameter overrides
   on blackboxes, unlike `read_slang`), then the Wally sources with
   `read_slang`;
4. runs `synth_xilinx` (with DSP48 inference, and with ABC9's final `&verify`
   disabled: it does not finish on the RV64GC design), deletes `$buf` and
   `$scopeinfo` cells (left over from reading the DDR3 Verilog hierarchically),
   and writes the JSON;
5. runs `fix-carry4-outputs.py`. In a slice, a carry position's sum `O[i]` and
   carry `CO[i]` leave through the same output mux, so Yosys CARRY4 cells that
   use both have no legal placement for nextpnr's atomic carry packer. The
   script recomputes those carries as `O[i+1] ^ S[i+1]` in a LUT2. The atomic
   packer keeps carry chains on the dedicated CO-to-CI cascade; the legacy
   `XC7_LEGACY_CARRY4_SPLIT` packer routes each carry bit through the fabric
   and made a 56-bit comparator take 58 ns;
6. runs nextpnr-xilinx and produces the bitstream with
   `fasm2frames`/`xc7frames2bit`.

To build the Linux configuration:

```bash
cd $WALLY/fpga/generator
make nexysvideo FLOW=opensource OPENCONFIG=fpganexysvideo
```

This also builds the ZSBL for the open-flow clock (`SYSTEMCLOCK`, 12.5 MHz) and
passes that clock to the LiteDRAM generator. The ZSBL sets every
`clock-frequency` and `timebase-frequency` property of the device tree it loads
from the SD card to `SYSTEMCLOCK`, so an SD card written for the Vivado flow
(20 MHz) boots unchanged.

## Hardware bring-up telemetry

Because there is no logic analyzer in the open-source flow, bring-up uses the
board's five user LEDs (`GPO[4:0]`, `LD0`..`LD4`). The mapping is temporary and
lives in `fpga/src/fpgaOpenSource.sv`:

| LED  | Signal |
|------|--------|
| LD0  | `clk100` activity (input clock + BUFG alive) |
| LD1  | `init_done` |
| LD2  | `init_error` |
| LD3  | `debug_cpu_active`: sticky bit set once the service CPU writes its SRAM |
| LD4  | sticky bit set once the service CPU starts a UART frame (BIOS printing) |

`debug_cpu_active` is injected into the generated `litedram_core.v` by
`gen_litedram.py` (a small post-processing step). The BIOS clears `.bss` and
builds its stack in SRAM, so this bit only lights when real firmware executes;
the UART sticky bit requires the BIOS to reach `uart_init()`/`printf()`.

## Current status and limitations

- The open flow requires openXC7 nextpnr-xilinx 0.9.8 with
  `bin/installation/nextpnr-xilinx-lutram-clkinv.patch`, installed by
  `bin/installation/fpga-toolchain-install.sh`. The earlier gatecat revision
  produced bitstreams whose DDR3 reads always failed. See
  `docs/engineering/experiments/open-ddr3-bringup.md`.
- On the Nexys Video, the LiteDRAM BIOS passes read leveling and its memory
  test. Wally then reads and writes DDR3 at `0x40000000` without errors.
- **Linux boots** with `OPENCONFIG=fpganexysvideo` (2026-10-29): the ZSBL loads
  OpenSBI and Linux 6.19 from an SD card written for the Vivado flow, the
  kernel sees 512 MiB, detects the SD card and reaches the BusyBox shell.
  Wally runs at 12.5 MHz; nextpnr reports 13.3 to 14.9 MHz across builds. The
  remaining critical path (fetch PC to the `csrc` counters, about 33 LUT
  levels) is about 90% routing delay, so the next timing work is placement
  quality rather than RTL.
- With `fpgaopensource`, the design runs at 40 MHz. Programs boot from the
  IROM at `0x80000000`, where the DTIM also sits, so IROM programs cannot read
  constant data from the IROM. Its DDR3 result above predates the DSP and
  atomic carry changes and has to be rechecked.
- The LED telemetry above remains as bring-up instrumentation.

## Future design: run DDR3 bring-up without a service CPU (TODO)

> **Do this only after the current blocker is resolved and Wally+DDR3 runs on
> hardware with the VexRiscv service CPU.** Keeping the service CPU for now
> minimizes the number of variables during bring-up; this migration removes it
> afterwards.

The service CPU is not intrinsically required for DDR3: it exists because
LiteDRAM performs JEDEC initialization and PHY leveling in **software**
(`sdram_init()` in `liblitedram`) driven through the DFII/PHY CSRs, and the
standalone generator supplies a small VexRiscv (with its own ROM/SRAM) to run
that software. Xilinx's MIG does the same calibration in hardware, but it is
closed and cannot be reused in this flow.

### What LiteDRAM exposes without a CPU

With `cpu_type=None` (`litedram/gen.py`, the `cpu_type is None` path) the core
instantiates **no CPU, no ROM, no SRAM and no timer**, and exposes a control
Wishbone master, `wb_ctrl`, to the top level. Because `add_sdram` is called with
`with_soc_interconnect = (cpu_type is not None)`
(`litex/soc/integration/soc.py`), the DDR is *not* placed on the SoC bus in this
mode, so:

- `wb_ctrl` reaches the **CSRs only**: `ddrphy_*`, `sdram_dfii_*` and `ddrctrl`
  (`init_done`/`init_error`) at `0xF0000000` (64 KiB), per the generated
  `csr.json`;
- the **DDR data path** stays on the existing `user_port_wally` crossbar port
  (mapped at `0x40000000`), which is gated by `init_done`
  (`block_until_ready`).

### What the bring-up code must do

All of it is 32-bit MMIO; no FPU and no CPU-specific features are needed:

- `init_sequence()` (generated into `sdram_phy.h`): a short JEDEC sequence of
  CSR writes (reset, CKE, MR2/MR3/MR1/MR0, ZQ calibration) plus `cdelay`;
- `sdram_leveling()` (`liblitedram/sdram.c`): write leveling, read leveling,
  command-delay scan and bit-slip. These use the DFII data CSRs
  (`sdram_dfii_pi*_wrdata`/`rddata`) directly, so they also run purely over
  `wb_ctrl` and never touch the mapped DDR;
- `cdelay()` is a `nop` busy loop (`software/include/hw/common.h`);
- the final `memtest`/`memspeed` is optional (`SDRAM_TEST_DISABLE`) and is the
  only part that uses the mapped DDR (through the user port).

### Where the bring-up code lives

It cannot run from DDR, since DDR is exactly what it initializes. It must reside
and execute in Wally's **on-chip memory**:

- the program image in the **IROM** (64 KiB at `0x80000000` in the
  `fpgaopensource` configuration), and
- the stack / writable data in the **DTIM** (64 KiB at `0x80000000`).

That is the same role a ZSBL/BootROM plays in the Vivado flow. The only change
from the current design is that today the ROM/SRAM belong to the VexRiscv inside
the LiteDRAM core, whereas here they are Wally's own on-chip memories.

### What Wally needs

1. Two paths (or one address-decoded AHB-to-Wishbone bridge) from Wally's
   external AHB port: the CSRs at `0xF0000000` to `wb_ctrl`, and the DDR at
   `0x40000000` to `user_port_wally` (which already exists).
2. The ported `init_sequence` + `sdram_leveling` running in Wally's bare-metal
   environment, reusing the generated `csr.h`/`sdram_phy.h`, with a `cdelay`
   implementation.
3. Wally writes `ddrctrl_init_done` when done; the user port's
   `block_until_ready` gating then releases the DDR data path.
4. `gen_litedram.py` generated with `cpu=None` and without `compile_software`
   (and without the firmware dependencies).

### Benefits

A single CPU: removes the VexRiscv, its ROM/SRAM and the whole firmware
toolchain (`pythondata-cpu-vexriscv`, `pythondata-software-picolibc`,
`pythondata-software-compiler-rt`, `meson`, `ninja`), reducing both area and the
install footprint.

### Costs and risks

- Porting and **validating the PHY calibration** on Wally is the bulk of the
  work (~600 lines of `liblitedram`), and is where the risk sits.
- `cdelay` is calibrated to the CPU/clock; it must be re-derived (the values are
  minimum delays, so erring long is safe).
- Address maps must be reconciled: the CSRs occupy `0xF0000000` in Wally's
  external window, Wally keeps the IROM at `0x80000000`, and the DDR stays at
  `0x40000000` (Wally declares a 128 MiB `EXT_MEM_RANGE`, whereas LiteX's own
  SoC mapping would only expose 16 MiB).
- The existing AHB bridge to the user port is reused, but its verification scope
  changes, and the service-CPU reset/clock bring-up work becomes obsolete.
