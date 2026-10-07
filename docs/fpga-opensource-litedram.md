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

## Clocking decision: a single clock domain

The SoC and the DDR controller share **one clock domain**. `litedram_ddr`
exports its `sys_clk` and the SoC runs on it (`sys_clk_freq = 40 MHz` for the
Nexys Video bring-up), so the AHB/Wishbone bus needs no clock-domain crossing.
Wally is held in reset (`reset_ext`) until the DDR initialization firmware
reports `init_done` without `init_error`, and the board UART is switched from
the initialization firmware to Wally once the DDR is ready.

A CDC in the bridge was considered and rejected: the bus is wide
(address + 32-bit data + strobes) and non-posted, so a correct crossing needs a
bidirectional asynchronous FIFO/handshake (not a two-flop synchronizer), adding
latency, area and metastability risk. Since Wally is the only master of the
DDR3, unifying the clock is simpler and sufficient. The trade-off is that Wally
is limited to the DDR controller's `sys` frequency; that is acceptable because
the open-source flow already closes at around 50 MHz.

## Bus bridge: AHB-Lite slave to Wishbone master

`src/uncore/ahbwishbonebridge.sv` connects Wally's external-memory AHB port to
LiteDRAM's Wishbone slave.

- With caches disabled, `HBURST` is fixed to `SINGLE`, so only single `NONSEQ`
  transactions occur; no burst support is needed.
- Byte enables come from `HWSTRB` (the AHB write strobe used throughout the
  uncore), not from `HSIZE`.
- The region select is **registered** in the bridge. The SoC exposes the
  *combinational* `HSELEXT`; using it directly would close a loop
  `HREADYOUT -> HSELEXT -> HSIZE -> HREADY -> HTRANS` through the core's bus
  FSM and the address decoder.
- `HRESP` is always `OKAY`; the bridge inserts AHB wait states (`HREADYOUT`,
  driven by the Wishbone `ack`) until the transaction completes.

## Memory map

To avoid conflicting with the boot ROM, DDR3 is mapped at a dedicated base
rather than at `0x80000000`:

| Region   | Base         | Size   |
|----------|--------------|--------|
| IROM     | `0x80000000` | 64 KiB |
| DDR3     | `0x40000000` | 128 MB |

`config/derivlist.txt` sets `EXT_MEM_SUPPORTED=1`, `EXT_MEM_BASE=0x40000000`
and `EXT_MEM_RANGE=0x07FFFFFF` for the `fpgaopensource` configuration.

The bridge uses `HADDR[26:0]` as the DDR3 word-offset, which is correct because
`0x40000000` is aligned to the 128 MB window.

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
4. runs `synth_xilinx`, deletes `$buf` and `$scopeinfo` cells (left over from
   reading the DDR3 Verilog hierarchically), and writes the JSON;
5. runs nextpnr-xilinx at 40 MHz and produces the bitstream with
   `fasm2frames`/`xc7frames2bit`.

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

- The full open-source bitstream (Wally + LiteDRAM core with its initialization
  firmware + bridge, single clock domain) **builds and programs** on the Nexys
  Video (`DONE=1`). It **passes timing at 40 MHz** (`HCLK` reported at
  `~51 MHz`; the combined design does not close at 50 MHz because Wally and the
  LiteX service CPU/L2 cache share the `sys` domain).
- Programs still **boot from the IROM** at `0x80000000`; DDR3 is mapped as extra
  memory at `0x40000000`. Booting from DDR3 would require a BootROM/ZSBL
  reorganization (as in the Vivado flow).
- **The DDR3 path is not validated on hardware, and the blocker is now
  localized to the service CPU.** The bring-up telemetry above shows:
  - `clk100` toggles (LD0) and the PLL locks (the external `sys_rst` was
    observed released and `sys_clk` running in an earlier build), so the input
    clock, BUFG, PLL and system clock are healthy;
  - `init_done` (LD1) and `init_error` (LD2) both stay low, and neither the SRAM
    sticky (LD3) nor the UART sticky (LD4) ever asserts.
  - Since the BIOS is compiled to run from the ROM before touching DDR3, "no
    SRAM writes and no UART frame" means the **VexRiscv service CPU is not
    executing the BIOS at all**; DDR3 initialization/leveling is never reached.
- This is **not** a firmware-image problem: the reset vector and first
  instructions in `litedram_core_rom.init` (`0b00006f`, `j 0xb0 <crt_init>`)
  match `bios.elf` exactly, and the routed netlist / FASM do carry the ROM's
  `INIT_xx` BRAM contents.
- The remaining suspects are therefore the service CPU's **reset
  sequencing** (`sys_rst | litedramcore_reset`) or its **clock/fetch path**
  inside the standalone core, not the ROM or DDR PHY.
- nextpnr only reports timing for `HCLK`, `clk100` and the IDELAY clock. The DDR
  PHY's `sys4x` domain is not constrained in this flow and must be checked
  separately.
- The AHB bridge is verified in isolation (Verilator) and by full-design
  synthesis.

### Next steps

1. Extend the same `gen_litedram.py` injection with two more sticky taps and put
   them on LEDs: the service CPU's actual reset (`sys_rst | litedramcore_reset`)
   and instruction-fetch activity (`litedramcore_ibus_cyc`). That distinguishes
   three cases: CPU held in reset, CPU never fetching, or CPU fetching but
   trapping (e.g. bus decode). These taps were prototyped but not built or
   tested yet.
2. Fix or re-integrate the service CPU reset/clock accordingly.
3. Constrain and verify the DDR PHY `sys4x` domain.
4. Only then map programs to DDR3 / reorganize the boot path.

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
