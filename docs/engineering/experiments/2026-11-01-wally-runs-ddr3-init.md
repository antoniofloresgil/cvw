# Wally runs the DDR3 initialization (VexRiscv optional)

Date: 2026-11-01. Branch `wally-ddr3-init`, from `main` at `c2fa6bd94`.

Status: **steps 1 to 3 done** (generator option; RTL path for RV32, checked in
simulation and synthesis; firmware built, not run). Board work is not started. Nothing
here has run on the board yet, including the service-CPU build with the new top.

## Goal

Today the LiteDRAM core carries a small VexRiscv service CPU (with its own
ROM, SRAM, UART and timer) whose only job is to run the DDR3 JEDEC
initialization and PHY leveling (`sdram_init()` in LiteX's `liblitedram`)
through the PHY/DFII CSRs. Wally is held in reset until that CPU reports
`init_done`.

The goal is to let **Wally itself run that code** and to keep the VexRiscv as a
debugging alternative selected by a parameter, because it costs area and brings
a second CPU, a second firmware toolchain and a second UART to the design. The
background and the long-form design are in
[fpga-opensource-litedram.md](../../fpga-opensource-litedram.md) ("Future
design: run DDR3 bring-up without a service CPU").

## Constraints chosen for this work

- **Keep the diff against upstream small.** All new code goes in new files under
  `fpga/`. The Wally RTL (`src/`), `config/shared` and `bin/` are not touched.
  The fork-specific open-flow files (`fpga/generator/`, `fpga/src/fpgaOpenSource.sv`,
  the FPGA lines of `config/derivlist.txt`) are changed only where needed, and
  the existing AHB-to-Wishbone bridge is reused as it is.
- **The service CPU stays selectable.** `--init-cpu vexriscv` is the default
  until Wally's initialization works on the board; it flips to `none` only
  then. A run that fails on the board can always be compared with the known-good
  VexRiscv build.
- **The existing flow must not change while the new one is built.** Step 1 was
  checked by regenerating the RV64 variant with `--init-cpu vexriscv` and
  comparing it to the generated files in use: identical except timestamps and
  output paths.

## Plan

RV32 `fpgaopensource` (one clock shared with the DDR controller, 40 MHz) goes
first. RV64 `fpganexysvideo` (Wally at 12.5 MHz in its own clock domain)
follows, because its control bus needs a clock-domain crossing.

1. **Generator (done).** `gen_litedram.py --init-cpu {vexriscv,none}`.
2. **RTL (done for RV32, see below).** A second AHB-to-Wishbone path from Wally's external bus to
   `wb_ctrl`, decoded in `fpgaOpenSource.sv` (not in the uncore), in a new
   module. Open points to settle here:
   - which Wally address window reaches the CSRs (the generated map starts at
     0; the top can add an offset), and how it fits with the external-memory
     range of each configuration;
   - reset: Wally can no longer wait for `init_done`. It must start at power-up
     and boot from on-chip memory, and its accesses to the DDR must be held off
     (or fail visibly) until `init_done` rises;
   - `init_done` and `init_error` become CSRs that Wally writes; the LEDs and
     the UART mux that today follow the service CPU need a Wally equivalent.
3. **Firmware (done, see below).** Port `init_sequence()` (generated into `sdram_phy.h`) and
   `sdram_leveling()` (write leveling, read leveling, command-delay scan,
   bit-slip; about 600 lines of `liblitedram`) to Wally's bare-metal
   environment, with a `cdelay` calibrated for Wally's clock (the values are
   minimum delays, so erring long is safe). RV32: it runs from the IROM. RV64:
   it goes into the ZSBL, which already lives in the boot ROM.
4. **Board, RV32.** Read and write leveling, the memory test and the 973-pass
   write/verify run that the VexRiscv build already passes. Measure the real
   area after place and route. Flip the default to `none` if it works.
5. **RV64.** A clock-domain crossing for the control bus (Wally at 12.5 MHz,
   control bus in the 40 MHz system domain), the ZSBL change, and the Linux boot
   again.

The main risk is step 3 to 4: PHY calibration run by Wally. Timing of the CSR
accesses and the clock-domain behavior are what can differ from the service
CPU, and a failure shows up only on the board.

## Step 1: what the generator produces

`gen_litedram.py --init-cpu none` calls LiteX's standalone generator with
`cpu=None`. Compared with the VexRiscv build:

- no VexRiscv, ROM, SRAM, UART, timer or `ctrl` block;
- a Wishbone slave `wb_ctrl` for the CSRs (the generated wrapper
  `litedram_ddr.v` exposes it as `ctrl_*`: 32-bit data, 30-bit word address);
- no `uart_*` or `debug_cpu_*` ports in the wrapper, so the top must adapt in
  step 2;
- the LiteX software headers are generated (`csr.h`, `sdram_phy.h`, `soc.h`,
  `mem.h` under `init/software/include/generated/`), without compiling any
  firmware.

CSR map without a CPU (byte offsets from the start of `wb_ctrl`):

| Block | Offset | Notes |
|---|---|---|
| `ddrctrl` | `0x0000` | `init_done` at `0x0`, `init_error` at `0x4` |
| `ddrphy` | `0x0800` | PHY leveling and delay registers |
| `sdram` | `0x1000` | DFII control and phase injection |

With the service CPU the same blocks sit at `0xF0000000` plus `ctrl`, `timer0`
and `uart`. The DDR data path (`user_port_wally`, gated by `init_done` through
`block_until_ready` in shared-clock mode) is unchanged.

Usage:

```bash
source setup.sh
cd fpga/generator
./gen-litedram.sh                  # service CPU, as before
./gen-litedram.sh --init-cpu none  # no CPU; Wally will run the init code
```

## Expected benefit (Yosys, before place and route)

Flat `synth_xilinx -arch xc7` of the LiteDRAM core alone:

| Core | LUT | FF | RAMB36 | RAMB18 |
|---|---|---|---|---|
| With VexRiscv (RV64 variant) | 5187 | 4129 | 4 | 15 |
| With VexRiscv (hierarchical, default args) | 5272 | 4172 | 4 | 15 |
| `--init-cpu none` (default args) | 3251 | 2191 | 0 | 0 |

The VexRiscv alone is 1020 LUT and 887 FF. Removing the whole service block
saves about **2000 LUT, 1900 FF and about 11 RAMB36 equivalents**. Two caveats:
the `none` core was generated with the default 32-bit, single-clock port while
the RV64 one has a 64-bit port and a clock crossing, so the comparison is not
exact; and Wally's initialization code occupies on-chip memory, which takes
back part of the RAM saving. The real figure is measured in step 4.

## Repeating the measurement

```bash
YOSYS=$RISCV/oss-cad-suite/bin/yosys
cd <generated dir>
$YOSYS -p "read_verilog -sv litedram_core.v [VexRiscv_Min.v]; hierarchy -top litedram_core;
           synth_xilinx -top litedram_core -arch xc7 -flatten; stat"
```

Use a scratch output directory (`--output-dir`) so the generated files in
`fpga/generator/opensource-litedram/` are not overwritten.

## Notes for later steps

- LiteX derives the CSR base from the SoC memory map: with a CPU it is
  `0xF0000000`, without one it is `0`. The Wally side chooses its own window, so
  `csr.h` only needs its `CSR_BASE` set to that window when the firmware is built.
- In RV64 mode the whole `user_port_wally` is already crossed into Wally's clock;
  the control bus is not, and it is the part step 5 adds.
- Wally is currently held in reset by `ddr_ready` in `fpgaOpenSource.sv`; that
  line and the `UARTSout` mux are the two places the service CPU is visible at
  the top level.

## Step 2: the control path in the RTL (RV32)

No file under `src/` changed. What changed:

- `fpga/src/extbussplit.sv` (new): splits Wally's one external region
  (`HSELEXT`) into the DDR3 window (low half) and the CSR window (high half) by
  one address bit, and merges the two AHB responses. Each side is an unchanged
  `ahbwishbonebridge`; a bridge that is not selected returns `HREADYOUT = 1`, so
  the merged `HREADY` is the AND of both and the data comes from the side
  captured in the address phase.
- `fpga/src/fpgaOpenSource.sv`: instantiates the split and a second bridge
  (32-bit, 64 KiB window) to the generated wrapper's `ctrl_*` port. The window
  select bit is the top bit of `EXT_MEM_RANGE`, so the range must cover twice
  the visible DDR3. With a 64-bit bus (RV64) the control path is not wired
  (see below). Wally's reset no longer waits for `init_done` when
  `init_by_wally` is set, and the UART goes to Wally from power-up.
- `gen_litedram.py`: the wrapper now has the same ports in both modes
  (`init_by_wally`, `ctrl_*`, `uart_*`, `debug_cpu_*`); the unused ones are tied
  off. The SoC top instantiates it once and synthesis removes the dead side.
- `config/derivlist.txt`, `fpgaopensource` only: `EXT_MEM_RANGE` from
  `0x07FFFFFF` (128 MiB) to `0x0FFFFFFF` (256 MiB). DDR3 stays at
  `0x40000000`-`0x47FFFFFF`; the CSRs are at **`0x48000000`** (`ddrctrl` at
  `0x48000000`, `ddrphy` at `0x48000800`, `sdram` at `0x48001000`). Without a
  CPU in LiteDRAM the window reads as zeros.
- `build-opensource.sh`: `INIT_CPU=none` passes `--init-cpu none` to the
  generator (default `vexriscv`). `Makefile`: copies `extbussplit.sv` with the
  top.

While Wally initializes the DDR3, an access to the DDR3 window waits in
LiteDRAM's user port (`block_until_ready`) until the firmware writes
`init_done`, so a premature access hangs rather than returning garbage.

### Checks done

- `tests/fpga/tb_extbussplit.sv` (Verilator, self-checking): 13 pipelined AHB
  transfers through the split and both bridges, with a 4-cycle DDR slave and a
  2-cycle CSR slave: writes and read-backs on both sides, back-to-back on the
  same side, alternating sides, and one transfer outside the external region
  that must reach neither. It passes, and it fails on two injected bugs (data
  always taken from the DDR side; CSR select not qualified by `HSELEXT`).
- RV32 `fpgaopensource`, full Yosys synthesis (`synth_xilinx -flatten -abc9`)
  of the whole design, both modes:

  | Init | LUT | FF | RAMB36 | RAMB18 | RAM32M |
  |---|---|---|---|---|---|
  | `vexriscv` | 13021 | 10048 | 20 | 44 | 98 |
  | `none` | 10937 | 8641 | 16 | 29 | 62 |

  2084 LUT (16 %), 1407 FF, 4 RAMB36 and 15 RAMB18 less, before Wally's
  initialization code is added to its IROM.
- RV64 `fpganexysvideo` elaborates with the new top (service CPU, 64-bit bus,
  control path tied off).

Not checked yet: place and route, and the board. The service-CPU build with the
new top must pass the existing RV32 DDR3 test on the board again before the
default changes.

## Open problem for RV64: the CSR window would be cacheable

On RV64 (`fpganexysvideo`) the data cache is on, and Wally's PMA marks the whole
external region as cacheable and idempotent (`src/mmu/pmachecker.sv`). A CSR
window inside that region would be read and written through the D$: reads could
return stale lines, writes would reach the registers only on eviction, and a
line fill or write-back touches 64 bytes of registers at once. The firmware runs
in M-mode, where the core has no other way to mark an address uncached. RV32
(`fpgaopensource`, `rv32imc`) has no caches, so the problem does not exist there.

Options to decide before step 5:

1. **Svpbmt from the ZSBL.** Wally supports Svpbmt. The ZSBL could build a
   one-page table that maps the CSR window with `PBMT = IO` and run the
   initialization with `MPRV = 1`, `MPP = S`, so its loads and stores are
   translated and uncached. No RTL change, but it is the most complex firmware.
2. **A non-cacheable external region in Wally's RTL.** The cleanest hardware
   answer, but it changes `src/` (PMA and address decoders), which is what this
   work avoids for upstream merges.
3. **Keep the VexRiscv for RV64.** RV32 uses Wally-run init; the Linux build
   keeps the service CPU, which is already an option of the generator.

## Step 3: the firmware (`fpga/ddrinit/`)

`fpga/ddrinit/` builds one RV32 image that Wally runs from the IROM:

- LiteX's own `sdram_init()` (`liblitedram/sdram.c` and `accessors.c`) is
  compiled from the installed, pinned LiteX package, not copied into the
  repository. It runs `init_sequence()` from the generated `sdram_phy.h`, then
  read leveling and bit-slip (the A7 PHY of the Nexys Video has no write
  leveling), and writes `ddrctrl.init_done`/`init_error`.
- The headers come from the generator's output for `--init-cpu none`
  (`GENERATED`, by default `fpga/generator/opensource-litedram/init/software/include`);
  `CSR_BASE` is set to the Wally window, `0x48000000`, and `MAIN_RAM_BASE` to
  `0x40000000`.
- Own parts: `start.S` (gp, sp, `.bss`), `link.ld`, `main.c` (UART set-up,
  then `sdram_init()`, then a 64 KiB write/verify pass at `0x40000000` printed
  once per pass, forever), `printf.c` (the conversions liblitedram uses) and
  `shim/system.h` (empty cache hooks; RV32 has no caches).
- `SDRAM_TEST_DISABLE` drops LiteX's memtest/memspeed, which need a LiteX
  timer that does not exist without the CPU; `main.c` tests the memory instead.
- The image is 3.4 KiB (code and strings). The LiteX BIOS on the VexRiscv is
  about 29 KiB because it also carries a console, commands and the memory test.

```bash
source setup.sh
cd fpga/generator && ./gen-litedram.sh --init-cpu none   # headers
cd ../ddrinit && make && make install                     # overwrites fpga/src/boot.mem and data.mem
```

`make install` overwrites `fpga/src/boot.mem` and `data.mem`, which also hold
the Linux ZSBL for `fpganexysvideo`; back them up first.

### IROM, DTIM and constant data

In `fpgaopensource` the IROM and the DTIM both start at `0x80000000`:
instruction fetches go to the IROM and loads and stores to the DTIM. The DTIM
was never preloaded (`src/lsu/dtim.sv` has no `PRELOAD_ENABLED`, and
`ram1p1rwbe` only reads `data.mem` for 64-bit words), so an IROM program read
its strings and initialized data as zeros, as the earlier RV32 test showed.

Fix without touching `src/`: `PreProcessOpenSource` (`fpga/generator/Makefile`)
already patches the staged copy of the sources; two more `sed` lines enable the
DTIM preload and accept 32-bit words. The linker places code, read-only data
and initialized data contiguously from `0x80000000`, and the same image is
written to both `boot.mem` and `data.mem`: the IROM serves the code and the
DTIM the data at the same addresses. No other RAM in the design preloads, so the
patch only affects the DTIM.

### Not checked yet

- Nothing has run: there is no simulation model of the A7 DDR3 PHY in this
  flow, so the first run is on the board (step 4).
- `cdelay()` stays LiteX's busy loop. Its counts were chosen for a VexRiscv;
  Wally runs the loop in fewer cycles per iteration, so the delays are shorter.
  The JEDEC waits in `init_sequence()` (`cdelay(50000)` after reset, 10000 after
  CKE) still last milliseconds at 40 MHz against the 200/500 us required, but the
  short settle delays inside leveling (15 and 100 iterations) are a candidate
  if leveling misbehaves.
