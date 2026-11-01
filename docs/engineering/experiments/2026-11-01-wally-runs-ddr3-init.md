# Wally runs the DDR3 initialization (VexRiscv optional)

Date: 2026-11-01. Branch `wally-ddr3-init`, from `main` at `c2fa6bd94`.

Status: **steps 1 to 5 done, verified on the Nexys Video.** On RV32
(`fpgaopensource`) Wally initializes the DDR3 from its IROM, the default for RV32
builds. On RV64 (`fpganexysvideoopen`, a new open-flow configuration) a stage 0
in Wally initializes the DDR3 through an uncached `EXT_IO` window added to
Wally's PMA, then the ZSBL boots Linux. The service CPU stays available with
`INIT_CPU=vexriscv`, and `fpganexysvideo` (the Vivado configuration) keeps it.

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
4. **Board, RV32 (done, see below).** Read leveling, the memory test and the
   64 KiB write/verify run that the VexRiscv build already passes. Measure the
   real area after place and route. Flip the default to `none` if it works.
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

## Step 4: on the board (RV32, 2026-11-01)

Two bitstreams from the same sources, `make nexysvideo FLOW=opensource`
(`fpgaopensource`, 40 MHz, default nextpnr seed), each programmed on the Nexys
Video and its UART recorded for 60 s:

- **A, service CPU** (`INIT_CPU=vexriscv`, `ddrinit` built with `SKIP_INIT=1`):
  checks that the new top did not break the existing path. The LiteDRAM BIOS
  ran read leveling and `Memtest OK`; Wally then printed its banner (the first
  RV32 IROM program whose strings print, thanks to the DTIM preload) and
  completed 1575 passes of 64 KiB write/verify with 0 errors.
- **B, Wally initializes** (`INIT_CPU=none`, `ddrinit`): Wally printed its
  banner, ran `sdram_init()` through the CSR window at `0x48000000`, found the
  same read-leveling result as the VexRiscv (bit-slip 1, delay 20+-10, both
  modules, clean windows), wrote `init_done`, and completed 1727 passes of
  64 KiB write/verify with 0 errors.

nextpnr after place and route (one seed each; the frequency difference is
within seed-to-seed variation):

| Build | SLICE_LUTX | SLICE_FFX | RAMB36 | RAMB18 | CARRY4 | HCLK |
|---|---|---|---|---|---|---|
| A, VexRiscv | 18308 | 10048 | 20 | 44 | 588 | 40.55 MHz |
| B, Wally | 15545 | 8641 | 16 | 29 | 515 | 42.58 MHz |
| Saved | 2763 (15 %) | 1407 | 4 | 15 | 73 | |

The `cdelay()` concern from step 3 did not show: leveling matched the service
CPU's. Each build took about 3 minutes.

### Defaults after this step

- `build-opensource.sh` picks `INIT_CPU=none` for RV32 and `vexriscv` for RV64;
  `INIT_CPU=vexriscv` brings the service CPU back for debugging.
- With `none`, the DDR3 is usable only after a program in the IROM has run the
  initialization: `fpga/ddrinit` is that program, and other RV32 programs must
  start with its `sdram_init()` call (or be built on top of it).
- `gen_litedram.py` itself still defaults to `vexriscv`, so running the
  generator by hand behaves as before.

### Repeating it

```bash
source setup.sh
cp fpga/src/boot.mem fpga/src/data.mem <backup dir>/   # the Linux ZSBL lives there
cd fpga/generator && ./gen-litedram.sh --init-cpu none
make -C ../ddrinit install
make nexysvideo FLOW=opensource                        # RV32, INIT_CPU=none by default
openFPGALoader -b nexysVideo opensource-nexysvideo/nexysvideo.bit
# UART at 115200: banner, read leveling, then "pass N errors 0 total 0"
```

## RV64 check of the new top (2026-11-01)

The first RV64 (`fpganexysvideo`) build with the new top routed (14.51 MHz)
but **did not boot**: the ZSBL loaded the device tree at `0x9F000000` and
OpenSBI at `0x80000000`, and then nothing more appeared on the UART. Cause, a
bug from step 2: the top picked the CSR window with the top bit of
`EXT_MEM_RANGE`. On RV32 that range is twice the visible DDR3, but on RV64 it
is exactly the 512 MiB of DDR3, so bit 28 is a DDR3 address bit. Every access
from `0x90000000` up went to the control side, which is tied off on a 64-bit
bus (writes dropped, reads zero), and the device tree was lost. Step 2 tied off
the control bus for 64 bits but not the select.

Fix: `HAS_CTRL` (32-bit bus) gates the select, so without the control path the
whole region goes to DDR3 as before step 2. The rebuilt bitstream (14.89 MHz,
seed 2, 20 min) booted OpenSBI v1.7 and Linux 6.19.14 to the BusyBox login in
316 s; `uname`, `/proc/cpuinfo` (rv64imafdc, sv48) and `free` (about 512 MiB)
look right. Option 2 below replaces the bit with an explicit `EXT_IO` window,
which removes this class of mistake. The split testbench only covers the
32-bit case; this is what the board check was for.

## Step 5 decision: option 2, a non-cacheable I/O window in Wally's PMA

Decided on 2026-11-01: RV64 gets option 2 (the cleanest hardware answer), once
the RV64 build with the new top has booted Linux on the board. The other two
options stay documented above. The constraint is the same as for the whole
branch: keep the changes orthogonal to what arrives from upstream.

### Why the problem exists (summary)

With caches on, Wally's PMA marks all of `EXT_MEM` cacheable and idempotent. A
CSR window inside it would be read and written through the D$ in 64-byte lines:
reads return stale copies, writes reach the registers late and drag 15
neighbors with them, and some LiteX CSRs act on every write (DFII command
issue). The ZSBL runs in M-mode, where only the PMA decides cacheability.
Cache-block operations (Zicbom) do not help, because they also work on whole
lines.

### Design

A new optional PMA region, `EXT_IO`, that lies **inside** `EXT_MEM` and that the
PMA treats as I/O: not cacheable, not idempotent, no atomics. It does not change
how the bus is decoded: the accesses still leave the core through `HSELEXT`, and
the FPGA top keeps splitting them as it does for RV32. So:

| File | Change |
|---|---|
| `src/cvw.sv` | three fields next to `EXT_MEM_*`: `EXT_IO_SUPPORTED`, `EXT_IO_BASE`, `EXT_IO_RANGE` |
| `config/shared/parameter-defs.vh` | the three matching lines |
| `config/<base>/config.vh` (6 files) | `EXT_IO_SUPPORTED = 0` plus base and range, next to `EXT_MEM_*` (derivgen can only override parameters that exist in the base configuration) |
| `src/mmu/pmachecker.sv` | one more `adrdec` for `EXT_IO`; `Cacheable`, `Idempotent` and `AtomicAllowed` exclude it |
| `config/derivlist.txt` | the FPGA configurations set `EXT_IO_*` |

Not touched: `adrdecs.sv` and its `SelRegions` width, the uncore, the SoC ports,
the testbenches. With `EXT_IO_SUPPORTED = 0` the decoder is constant 0 and
every existing configuration is unchanged; the regression must show that.

All additions are new lines next to `EXT_MEM_*`, so an upstream change conflicts
only if it edits those same lines. The change is generic (any SoC with a
peripheral behind the external port needs it), so it is also a candidate to
propose upstream.

### Step 5 as built

The plan above held for the PMA. Three points changed while building it; the
text below is what the branch does.

- **A separate configuration, `fpganexysvideoopen`.** `fpganexysvideo` is also
  the Vivado configuration, and the ZSBL takes `EXT_MEM_RANGE` from it to place
  the device tree at the end of memory (the plan wrongly said the ZSBL kept its
  own value). So the new derivative, only for the open flow, inherits
  `fpganexysvideo` and adds: `EXT_MEM_RANGE` 1 GiB, `EXT_IO` at `0xA0000000`
  (64 KiB), and the stage-0 memories below. `fpga/generator/Makefile` passes the
  ZSBL the real DDR3 size (512 MiB) for this configuration. Vivado and
  `fpganexysvideo` are unchanged, and `OPENCONFIG=fpganexysvideo` still builds
  the RV64 design with the service CPU.
- **Clock crossing in RTL, not in LiteX.** Putting LiteX's
  `wishbone.ClockDomainCrossing` on `wb_ctrl` would have meant restructuring the
  generated core. `fpga/src/wbcdc.sv` is a small toggle-handshake crossing (one
  transfer at a time; control accesses are rare). It is always in the path, also
  on RV32 where both clocks are the same. `tests/fpga/tb_wbcdc.sv` checks it with
  two clocks (12.5/40 MHz) and with one, and fails on two injected bugs (after
  its master was rewritten to behave like `ahbwishbonebridge`, which keeps `cyc`
  and the old fields during the ack cycle; the first version missed one bug).
- **Stage 0 in its own IROM and DTIM, not in the boot ROM.** The ZSBL fills the
  4 KiB boot ROM and most of the 8 KiB uncore RAM, which cannot grow in place
  (a decoder needs the base aligned to the size). `fpganexysvideoopen` adds a
  16 KiB IROM and a 16 KiB DTIM at `0x4000` with `RESET_VECTOR = 0x4000`: an
  RV64 build of `fpga/ddrinit` (`make stage0`, 4.1 KiB) initializes the DDR3,
  tests 64 KiB once, waits for the UART to drain and jumps to the ZSBL at
  `0x1000`. `fpga/zsbl` is not touched. Because the IROM and the boot ROM both
  preload `boot.mem` (and the DTIM and uncore RAM `data.mem`),
  `PreProcessOpenSource` gives the stage-0 IROM and DTIM their own image,
  `fpga/src/ddrinit.mem`, in the staged copy for this configuration only.
  `build-opensource.sh` builds stage 0 right after generating LiteDRAM (it needs
  the generated headers). No earlier Wally configuration combined TIMs with
  caches; the RTL supports it (the LSU has the three-way DTIM/cache/bus read
  mux) and it works on the board.
- **Top decode.** The CSR side is selected with `EXT_IO_BASE`/`EXT_IO_RANGE`
  on both RV32 and RV64 (RV32 sets `EXT_IO` too; it has no PMA, so only the top
  uses it). A 64-bit bus picks one 32-bit register per access by its byte
  strobes.
- **Init default.** `build-opensource.sh` picks `INIT_CPU=none` when the
  configuration has `EXT_IO`, else `vexriscv`.

### Step 5 results (2026-11-01)

- `regression-wally` with the PMA change (`EXT_IO` off everywhere): passes, 285
  logs. `lint-wally`: all configurations pass. `actconfig-sync --check`: the ACT
  configurations agree with `config.vh`.
- `fpganexysvideoopen` on the Nexys Video: stage 0 printed its banner, ran
  `sdram_init()` through `0xA0000000` (uncached, 64-to-32-bit adapter, clock
  crossing), found the same read leveling as the service CPU (bit-slip 1, delay
  20+-10, both modules), passed its 64 KiB test, and jumped to the ZSBL; OpenSBI
  v1.7 and Linux 6.19.14 booted to the BusyBox login. In that run the jump
  message was garbled because the ZSBL reset the UART FIFO; stage 0 now waits for
  the transmitter to drain.
- nextpnr after place and route, RV64, one seed each:

  | Build | SLICE_LUTX | SLICE_FFX | RAMB36 | RAMB18 | HCLK |
  |---|---|---|---|---|---|
  | `fpganexysvideo`, service CPU | 86015 | 30781 | 9 | 16 | 14.89 MHz |
  | `fpganexysvideoopen`, Wally | 83681 | 29630 | 13 | 1 | 14.10 MHz |

  2334 LUT (2.7 %) and 1151 FF saved, and about 3.5 RAMB36 equivalents even
  after the 32 KiB of stage-0 memory. The frequency difference is within
  seed-to-seed variation.

- Final check on the committed state, both on the board: RV32
  (`fpgaopensource`, now also through `EXT_IO` decode and `wbcdc`) leveled the
  same way and passed 1167 passes of 64 KiB with 0 errors (43.20 MHz); RV64
  (`fpganexysvideoopen`, 14.10 MHz) printed a clean jump message and booted
  Linux to the login again.

### What step 5 changes outside `fpga/`

| File | Lines |
|---|---|
| `src/cvw.sv` | +3 (fields next to `EXT_MEM_*`) |
| `config/shared/parameter-defs.vh` | +3 |
| `config/<base>/config.vh` x 6 | +3 each, `EXT_IO_SUPPORTED = 0` |
| `src/mmu/pmachecker.sv` | +7, 3 changed (`SelExtMem` in the cacheable, idempotent and atomic terms) |
| `config/derivlist.txt` | the FPGA derivatives |

`adrdecs.sv`, the uncore, the SoC ports and the testbenches are unchanged. The
PMA change is generic and a candidate to propose upstream. The unmerged PMU
branch (`adding-mpu-support`) adds lines to the same files, but next to the
counter parameters, not next to `EXT_MEM_*`.
