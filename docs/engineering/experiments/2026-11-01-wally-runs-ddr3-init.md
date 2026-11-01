# Wally runs the DDR3 initialization (VexRiscv optional)

Date: 2026-11-01. Branch `wally-ddr3-init`, from `main` at `c2fa6bd94`.

Status: **step 1 of 5 done** (the generator option). The RTL, firmware and board
work are not started. Nothing here has run on the board yet.

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
2. **RTL.** A second AHB-to-Wishbone path from Wally's external bus to
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
3. **Firmware.** Port `init_sequence()` (generated into `sdram_phy.h`) and
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
