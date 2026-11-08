# Open ASIC flow (LibreLane, IHP SG13G2 and SG13CMOS5L)

Takes a Wally configuration from RTL to a checked GDS with open tools only: Yosys
(with the slang frontend), OpenROAD, Magic, KLayout and Netgen, driven by
[LibreLane](https://github.com/librelane/librelane) on the IHP open PDK. No Wally RTL is modified.

```bash
nix develop github:librelane/librelane/3.1.0.dev4 --accept-flake-config   # once, to check Nix works
make CONFIG=syn_rv32imc                  # synthesis to GDS, DRC, LVS (40 ns clock)
make CONFIG=syn_rv32imc CLOCK_PERIOD=30  # another clock period
make synth CONFIG=syn_rv64gc             # synthesis only
make CONFIG=sramtest                     # one IHP SRAM macro (sramtest/), then check_drc.py
make CONFIG=asic_rv32imc                 # syn_rv32imc with a 4 KiB DTIM in an IHP SRAM macro
make CONFIG=asic_soc_rv32imac             # a chip: the SoC in a pad ring (chip/), Chip flow
make chipsim                             # cocotb test of that chip (RTL): boots a program over the UART
make boardsim                            # the same chip on the KiCad test board's netlist (hardware/board/sim/)
make PDK=ihp-sg13cmos5l CONFIG=asic_rv32imc   # the same in SG13CMOS5L, in work/asic_rv32imc-sg13cmos5l
```

Requirements: [Nix](https://nixos.org/download) (tested with Determinate Nix 3.24.1, which is Nix 2.35.3) with flakes and the FOSSi cache
(`extra-substituters = https://nix-cache.fossi-foundation.org` and its key, in
`/etc/nix/nix.custom.conf`; LibreLane's documentation gives both). LibreLane is not
vendored: `LIBRELANE` in the Makefile pins a release. `PDK_VERSION` is the IHP PDK that this
release pins; `make pdk` downloads it with ciel into `~/.ciel` (both processes, without enabling
it), and the flow reads it from there. `make chipsim` needs cocotb and Verilator from
[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (`OSS_CAD`, default `~/riscv/oss-cad-suite`).

`gen_config.py` writes `work/<CONFIG>/config.json` and a wrapper module that binds
`wallypipelinedcore`'s parameter `P` to the configuration's `config.vh`. Results are
in `work/<CONFIG>/runs/RUN_*/`: `final/` holds the GDS, netlists, SPEF and
`metrics.json`; each numbered step directory has its log and reports.

Configurations:

- `syn_*`: the core alone, memories in flops.
- `asic_*` (`config/derivlist.txt`): RAMs of a shape that an IHP SRAM macro implements go in the
  macro (`sram/ram1p1rwbe.sv`); `gen_config.py` copies Wally's `ram1p1rwbe` as `ram1p1rwbe_generic`
  for the other shapes: 1024 x 32 is one macro, and 2048 x 32 times a power of two is banks of the
  2048 x 32 macro (the 8192 x 32 one has no write mask, which byte stores need). `make sramsim`
  checks the adapter for both, with the macros' behavioral models, against Wally's RAM under random
  stimulus.
- `asic_soc_*`: chips. `chip/chip_top.sv` puts `wallypipelinedsoc` inside a ring of IHP pads (clock,
  reset, UART, SPI, 8 GPIOs, JTAG and 8 power pads), after IHP's
  [LibreLane template](https://github.com/IHP-GmbH/ihp-sg13-librelane-template); the bondpad comes
  from the template (`chip/ip/`), since the PDKs have none. The BOOTROM holds `chip/boot.S`
  (built into `chip/boot.mem`), which loads a program into the 64 KiB RAM at 0x80000000 (eight SRAM
  macros; the last 8 KiB, 0x8000E000-0x8000FFFF, are also the instruction trace's buffer: see below) and runs it. It reads straps from the GPIOs at reset: the UART's baud divisor from
  GPIO[4:0], and with GPIO[5] high it skips the flash. Otherwise it reads an SPI flash on the SPI
  pads (Read command 0x03 from address 0: `WALY`, a 4-byte length and the program); without that
  header (no flash, or an erased one) it falls back to the UART: it sends `W`, receives a 4-byte
  length and the program, and sends back its 8-bit sum. `chip/test/test_chip.py` plays the flash
  and loads `hello.S` from it (`boot_from_flash`), over the UART with GPIO[5] strapped
  (`boot_over_uart`), and through the JTAG port as a debugger does (`debug_over_jtag`): it halts
  the hart, loads the program with System Bus Access, turns the instruction trace on, resumes the
  hart at the program, halts it again and decodes the trace it reads back
  (`$WALLY/testbench/debug/etrace/etracedecode.py`).
- `asic_soc_rv32imac` is an RV32IMAC core: the A extension (`ZAAMO_SUPPORTED`, `ZALRSC_SUPPORTED`; atomics
  only on the RAM, as the PMA checker allows) adds 1,168 cells (+2.0 %, +1.0 % of the area) in Yosys.
  `chipsim`'s `atomics` test runs `chip/test/atomics.S`.
  It also has PMP with 16 entries (`PMP_ENTRIES`, the smallest Wally has, grain 4 bytes) for an RTOS's
  memory protection: +7,851 cells (+12.9 %, +8.2 % of the area) in Yosys. `chipsim`'s `pmp` test runs
  `chip/test/pmp.S`: the PMP CSRs, User mode against regions with R+X, R+W, R and no entry, and a locked
  entry that stops Machine mode too.
- FreeRTOS runs on the chip: `chip/freertos` has the kernel's RISC-V port (the submodule
  `addins/FreeRTOS-Kernel`, V11.3.3, `git submodule update --init addins/FreeRTOS-Kernel`), the
  configuration (tick from the CLINT, 1 kHz) and a demo with tasks, a queue, a mutex and a software timer;
  see its README. It also locks three PMP entries (code read-only and execute-only, data not executable)
  and proves it. `chipsim`'s `freertos` test boots it from the flash and checks what it prints.
- Zephyr runs on the chip with its User mode: `chip/zephyr` has an out-of-tree board and SoC (the submodule
  `addins/zephyr`, v4.5.0) and a demo whose threads, in User mode, are isolated by the PMP through memory
  domains; see its README. `chipsim`'s `zephyr` test boots it from the flash and checks that two domains keep their
  data and that every access outside a thread's domain (another domain, kernel data and code, the UART, the trace
  area, a jump into data, a system call without permission) faults and aborts only that thread. Zephyr gets the
  RAM's first 56 KiB; the last 8 KiB are the trace buffer's.
  Zephyr also drives the chip's peripherals (UART with interrupts, GPIO, SPI, PWM, I2C and the watchdog), each with a
  `chipsim` test on the pads; the FE310-compatible blocks use Zephyr's SiFive drivers (see `chip/zephyr/README.md`).
- `asic_soc_rv32imac` also has the microcontroller peripherals of
  [ADR 0022](../../docs/engineering/decisions/0022-asic-microcontroller.md) (`MCU_SUPPORTED`,
  `src/uncore/mcu/`, APB region at 0x10080000, PLIC sources 15-18): a timer with four PWM or
  capture channels (0x0000), a two-stage watchdog that resets the chip (0x1000), an I2C master
  (0x2000) and an RTC with an alarm (0x3000). They share the GPIO pads through the alternate
  function 1 (`IOF_EN`, `IOF_SEL` = 1): GPIO0-3 timer channels 0-3, GPIO6 I2C SCL, GPIO7 I2C SDA
  (open drain, needs external pull-ups); GPIO4-5 stay plain. The boot straps (GPIO0-5) are unaffected
  as `IOF_EN` resets to 0, and the I2C pull-ups on GPIO6-7 are outside them. `testbench/mcu` (`make`) is their unit test; the cocotb test
  `mcu_peripherals` runs `chip/test/mcu.S` on the whole chip, PWM duty, capture, an I2C slave on
  the pads, the RTC alarm and the watchdog's reset included.
- `asic_soc_rv32imac` has the JTAG debug port with 4 triggers and the instruction trace
  (`DEBUG_SUPPORTED`, `DEBUG_TRIGGERS`, `TRACE_SUPPORTED`; `docs/debug.md`, `docs/trace.md`): the
  trace buffer (2048 x 32, 8 KiB) was an SRAM macro of its own, of the same kind as the RAM's, and is now the RAM's last 8 KiB (`TRACE_IN_RAM`, below). Measured with Yosys and the SG13G2 library (memories as macros),
  the debug port adds 5,064 cells to the SoC's 34,216, the triggers 3,617 and the trace 4,646;
  the die grew from 2.0 to 2.4 mm for them (70,185 cells, setup +2.17 ns at 40 ns).
- The 32 KiB RAM grew the die to 2.6 mm: its four macros (417 x 627 um) fit in a row along the top
  of the core, their pins facing the standard cells below, and the trace buffer sits in the bottom
  left corner, turned to face them too (`gen_config.py` places the macros from `config.vh`).
  Result at 45 ns in SG13G2: 70,323 cells, 0.97 mm² of cells, 45 % of the core's area (65 % of
  the core with the macros); setup +2.88 ns in the slow corner, hold +0.09 ns; 0 route DRC, KLayout
  DRC, LVS and antenna errors; 20 mW. Magic's only findings are the waived ones (see below).
  Two kinds of IHP SRAM macro in one design make Magic report some 380,000 false M2.d errors (the
  GDS files share 84 of 141 subcell names; KLayout finds 0), which is why the trace buffer is
  2048 words and not 1024.
- With the A extension, PMP and the MCU peripherals, at 50 ns in SG13G2 (2.6 mm die): 88,037 standard
  cells, 1.20 mm² (55 % of the area outside the macros); setup +4.88 ns in the slow corner, hold
  +0.10 ns; 0 KLayout DRC, LVS, antenna and disconnected-pin errors; 21 mW. At 45 ns the PMP comparators
  missed setup by 0.12 ns. Magic's findings are the waived ones (see below).
- The 64 KiB RAM, with the trace buffer in the RAM (`TRACE_IN_RAM`), has eight macros (four in a row
  along the top, four in a row at the bottom right) in a 2.752 mm die, at 50 ns in SG13G2: 89,750
  standard cells, 1.21 mm² (61 % of the area outside the macros); setup +8.74 ns in the slow corner,
  hold +0.11 ns; 0 KLayout DRC, LVS, KLayout antenna and disconnected-pin errors; 18 mW; Magic's
  findings are the waived ones (1,414 inside the macros). The die is the largest that passes the
  KLayout antenna rule `Ant.e` at the input pads (19,706 of 20,000 at 2.752 mm; it grows with the pad
  ring, 20,238 at 2.8 mm), which is why the trace shares the RAM instead of a ninth macro.

Notes:

- The clock is 40 ns for every design but the chips (`asic_soc_*`, 50 ns: at 40 ns a path from the
  trigger comparators through the trap logic to the counters fails by 0.25 ns in the slow corner,
  and with the 16 PMP entries a path from the memory stage's address through the PMP comparators
  fails by 0.12 ns at 45 ns; the board's oscillator is 18.432 MHz, 54 ns). With LibreLane 3.1 (Yosys 0.69) `asic_rv32imc` misses 30 ns
  by 6.8 ns in the slow corner, and the chip has a path from the PLIC through the trap logic to
  the counters as long. Synthesis uses `SYNTH_STRATEGY` `AREA 0` with `SYNTH_ARITH_TREE` and
  `SYNTH_MUL_BOOTH` off: 3.1's defaults (`DELAY 4`, both on) close 30 ns, but with 50 % more area
  and power.
- The timing checkers fail the flow only for the corners their wildcards match: by default
  `TIMING_VIOLATION_CORNERS` is `*typ*` (setup) and the max slew and max cap checkers match
  none. `gen_config.py` sets `TIMING_VIOLATION_CORNERS` to `["*"]`; read
  `design__max_slew_violation__count` per corner in `final/metrics.json`.
- Magic DRC takes 1.5-3 h, with no output until it ends; the KLayout DRC is the reference for IHP.
- DRC of designs with SRAM macros: KLayout DRC is clean and stays fatal. Magic still reports
  `Cnt.c` and `Cnt.c SRAM exception` inside the macros (IHP-Open-PDK #794, #1024), so these designs
  set `ERROR_ON_MAGIC_DRC` to false and `make` runs `check_drc.py`, which waives only those rules
  inside the macros' bounding boxes. In a chip Magic also reports overlaps between the subcells of
  the pad ring (`Can't overlap those layers`, `This layer can't abut or partially overlap between
  subcells`), and in SG13CMOS5L three rules inside the pad cells (`Slt.c`, `CntB.h1`, `Seal.a`);
  KLayout DRC, the PDK's official deck, finds no error there, and `check_drc.py` reports them
  outside the core area as warnings when KLayout DRC is clean. So it does with `TM1Fil.a`, a 5 nm
  sliver that Magic reads next to a fill square its filler cut at a 5 nm coordinate. Any other
  Magic violation fails.
- `sram/pdn_cfg.tcl` is LibreLane's with one more connection, Metal4 (the macro's power pins) to
  the horizontal straps, in SG13G2 only (in SG13CMOS5L the vertical straps are on Metal4).
- IHP's minimum metal density (`MxFil.h`: 25 % of each metal in every 800 x 800 um window, a
  precheck rule): routed Metal2 and Metal3 leave gaps too narrow for fill in the core. The chips use
  IHP's Magic filler (`KLayout.Filler: Magic.Filler`), which fills more than the KLayout one, and
  `chip/pdn_cfg.tcl` adds Metal2 and Metal3 straps to the core power grid. The Metal2 straps lie in
  channels without cells (`FP_OBSTRUCTIONS` in `gen_config.py`, which must agree with the straps'
  offset and pitch): over cells they covered pins, and the antenna repair could not route its
  diodes next to them. The SG13G2 chip meets the rule; the SG13CMOS5L one not yet (its vertical
  straps are on Metal4).
- The chip has two pads of each supply on opposite sides, 28 pads in all; `OpenROAD.PadRing` needs
  whole microns between the pads, so a side of the 2.6 mm die takes 7 pads (of the 2.4 mm die, 7
  or 9; of the 2.0 mm die, 5 or 7).
- `chip/chip_top.sdc` makes the reset, UART receive and GPIO inputs false paths: they are
  asynchronous, and the SoC synchronizes them. TCK is a second clock (100 ns), asynchronous to the
  system clock: the DTM hands DMI requests to the Debug Module with a synchronized toggle.
- `chip/chip_top.sdc` defines the clock on the clock pad's output, as IHP's template does, and sets
  the clock activity of that pin for power: OpenSTA gives a clock on an internal pin none, and the
  chip's power read 1.2 mW instead of 21 mW.
- `PDK=ihp-sg13cmos5l` uses the CMOS-only process with 5 metals (Metal1-4, TopMetal1): the same
  SRAM macros and pads under `sg13cmos5l_` names; `chip_top.sv` picks the pads with `SG13CMOS5L`.
- Flat ABC on `syn_rv64gc` did not finish in over 6 h; the 64-bit core needs a hierarchical flow.
