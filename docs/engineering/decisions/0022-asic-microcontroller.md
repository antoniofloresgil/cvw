# ADR 0022: the open-ASIC chip as a microcontroller

Status: **accepted**; steps 1-3 (SPI-flash boot, 64 KiB RAM, debug and trace) are implemented,
step 4 (the MCU peripherals) is implemented and passes its tests, its silicon numbers are in the
[experiment record](../experiments/2026-11-02-open-asic-flow.md). Applies to the chip of the
[open ASIC flow](../experiments/2026-11-02-open-asic-flow.md) (`asic_soc_rv32imac`,
`asic/librelane/chip/`), merged into `main`.

## Context

The chip is already most of a small microcontroller: an RV32IMAC core (the A extension, Zaamo and
Zalrsc, was added for toolchains and RTOSes: +1.0 % area in Yosys; PMP with 16 entries, for the
memory protection of an RTOS such as Zephyr's User mode: +8.2 % more), an AHB bus with
APB peripherals (the AMBA structure of Cortex-M3 parts), UART, SPI, 8 GPIOs and a
4 KiB SRAM macro, in a pad ring of 24 pads (16 signal, 8 power) aimed at a QFN32
package. The Debug Module of branch `riscv-debug` will provide the JTAG debug access
that SWD gives on ARM parts (4 pins instead of 2). The goal is a chip used like a
Cortex-M3 class MCU: it keeps its program across power cycles, runs a C/RTOS
firmware, and offers the usual MCU peripherals.

LibreLane and the IHP open PDK cover all the digital parts. They do not offer embedded
flash, and analog blocks (PLL, POR, brown-out detection, regulator) are not available as
ready IP. Today the BOOTROM (`chip/boot.S`) loads the program over the UART into SRAM,
so the program is lost at power-off.

## Proposed choice

Keep Wally's core unmodified (upstream merges stay easy). Add the MCU parts as
parameterized peripherals that are off by default, or in an MCU top under `asic/`,
in this order:

1. **Nonvolatile program store**: an external SPI/QSPI flash (as RP2040 and ESP32
   do). First step: the BOOTROM copies the image from flash into SRAM and jumps to
   it (the SPI controller already exists; keep the UART loader as a fallback, chosen
   by a strap pin). Also grow the SRAM (several `RM_IHPSG13_1P_1024x32` macros) toward
   the 16-64 KiB of small M3 parts, within the die area.
2. **Debug**: merge `riscv-debug` (DEBUG_SUPPORTED, 4 JTAG pads, TCK in the SDC, cocotb
   JTAG test), as already planned.
3. **MCU peripherals on APB**: general-purpose timers with PWM and input capture,
   watchdog, I2C, an RTC/wake-up timer, and a pin multiplexer (one alternate function
   per GPIO), which the QFN32 pin budget requires.
4. **Optional, by area**: execute in place (XIP) from QSPI behind a small cache, a
   CLIC-like interrupt controller with nested priorities (meanwhile PLIC plus vectored
   `mtvec`), and DMA.

Keep the analog functions off chip for the first silicon: external oscillator on the
clock pad, external reset (RC or supervisor), and two supplies (IOVDD 3.3 V and
VDD 1.2 V). Low power is WFI plus clock gating.

## Step 4: the MCU peripherals (decided 2026-11-05)

Steps 1-3 are done (SPI-flash boot with UART fallback, JTAG debug and trace, in
a 2.6 mm die at 45 ns with 32 KiB of RAM; 64 KiB since 2026-11-08, see below). Step 4 adds timers with PWM and input capture, a watchdog, an I2C
master and an RTC/wake-up timer, and a pin multiplexer, keeping the QFN32 package.

Structure, following how the PWM peripheral is wired into Wally:

- One new APB region, `MCU_SUPPORTED/BASE/RANGE` (default 0 in every configuration), at
  `0x10080000`, 64 KiB. `src/uncore/mcu/mcu_apb.sv` decodes `PADDR[15:12]` into the four
  peripherals: 0 timer, 1 watchdog, 2 I2C, 3 RTC. All registers are 32 bits, word accesses;
  the register maps are in the header comment of each `*_apb.sv`.
- Four consecutive PLIC sources from `PLIC_MCU_ID` (timer, watchdog, I2C, RTC), as the PWM
  comparators occupy a block from `PLIC_PWM_ID`. The chip uses 15-18 (`PLIC_NUM_SRC` 18).
- No new `wallypipelinedsoc` port: Verilator lint makes a missing port fatal, so a port would
  have meant editing every instance (testbenches, FPGA tops, chip top). The peripherals
  reach the pads through the GPIO's existing IOF1 (`iof_en`/`iof_sel`), and the GPIO gained
  an `iof1oen` input so an alternate function can be an input or open drain: GPIO0-3 are the
  timer channels (PWM output, or capture input), GPIO6 is I2C SCL and GPIO7 SDA (open drain,
  external pull-ups); `IOF_EN` resets to 0, so the boot straps on GPIO keep working. The bootloader
  reads its straps from GPIO0-5 only, since the I2C pull-ups hold GPIO6-7 high (moved from GPIO4-5
  on 2026-11-06 for the test board, ADR 0023).
- The watchdog is two-stage: the first timeout sets a flag and interrupts, a second one with
  the flag still set requests a reset. The request stays inside `wallypipelinedsoc`: it is
  stretched to 16 clocks and ORed with the power-on and debug resets, and only a power-on
  reset clears it. The RTC counts a divided `HCLK` (no 32 kHz crystal in the first silicon).
- There is no pin multiplexer register in the chip: the GPIO's IOF registers are the
  multiplexer, which keeps `asic/` free of peripheral logic and the QFN32 pin budget.
- Each peripheral has a unit testbench (`testbench/mcu`, Verilator, an I2C slave at 0x50),
  and the chip's cocotb test `mcu_peripherals` runs `chip/test/mcu.S` from flash, measures
  the PWM duty on the pads, feeds a capture edge, talks to a pad-level I2C slave, and
  checks the watchdog reset by seeing the bootloader start again.

## Alternatives and consequences

- Embedded flash is not possible in the open PDK; a UART-only loader is not an MCU.
  External flash costs 4-6 pins (or 0-2 more if it shares the SPI pads).
- Pin budget: 24 pads today, plus 4 JTAG, plus the flash, fills QFN32; pin
  multiplexing is what makes the peripherals fit.
- More SRAM and peripherals grow the core area; the SRAM size and peripheral set
  decide whether the 2.0 x 2.0 mm die is enough, and must be fixed before the floorplan.
  Whether and when the chip is fabricated is open, so the cost per mm² is not the limit: the
  QFN 32's largest die, 3 x 3 mm, is (the die is 2.6 mm with 32 KiB of RAM, 2.752 mm with 64 KiB, see "The 64 KiB RAM").
- Interrupt latency and nesting are below a Cortex-M3 NVIC (no hardware stacking)
  until a CLIC-like controller exists.

## The 64 KiB RAM (2026-11-08)

The RAM doubled to 64 KiB (eight 2048 x 32 macros) so that an RTOS with memory protection fits (Zephyr with
User mode is about 42 KB of code and data in RAM, measured on `qemu_riscv32`, and the chip runs from RAM).
Three decisions, in the order they were forced:

- **The die limit is not the cost but the QFN 32** (3 x 3 mm), and nine macros (the eight of the RAM and one
  for the instruction trace's buffer) need a 2.92 mm die: five macros in a row do not fit in less.
- **The antenna rule Ant.e of IHP's KLayout deck** (cumulative metal of M1 to TopMetal1 over the gate area, 20000
  at most) fails at the 15 input pads of a 2.92 mm die: 21,307. The cluster of each input pad (its receiver's
  gate, 31 um²) includes the supply rails of the pad ring, which grow with the die, whatever the placement.
  Measured on the pad ring alone, from the floorplan to the stream-out: 18,351 at 2.600 mm (the 32 KiB chip),
  19,278 at 2.704, 19,706 at 2.752, 19,778 at 2.760, 20,238 at 2.800, 20,666 at 2.848, 21,307 at 2.920. The die
  must be under about 2.78 mm.
- **The trace buffer shares the RAM** (`TRACE_IN_RAM`, `docs/trace.md`): the sink writes the last 8 KiB of the RAM
  (0x8000E000-0x8000FFFF) through a second port of `ram_ahb` that a hart's access to that area takes over, so the
  chip has eight macros, in two rows of four, and a die of 2.752 mm (Ant.e 19,706, 1.5 % under the limit; the
  die cannot grow more than about 20 um). Traces are rarely used, so the RAM is whole when they are off; the
  alternative, a dedicated 8 KiB macro and a 56 KiB RAM, costs the same silicon. The software rule: while the
  trace is on, do not load or store in that area.

Flow notes (all in `gen_config.py`): the top row of macros sits 0 um from the edge, because at 1.89 um from it
pdngen leaves a Metal1 rail with no strap above the macros' halos, which fails the power grid check (22 segments;
with nine macros the same happened at 0, in another form, see `TOP_SHIFT`); detailed placement may move a cell 900 x
700 um, because a buffer over a 627 um macro finds no row within the default 500 x 100; and the target density of
global placement is 70 % (the default 0.85 leaves OpenROAD's antenna repair no room for 60 of its diodes).

## Software on the chip (2026-11-08)

The firmware side is in `asic/librelane/chip/`, and each part is tested in `make chipsim` (12 tests) on the chip's RTL:

- **FreeRTOS** (`chip/freertos/`) with static memory protection from locked PMP entries.
- **Zephyr** (`chip/zephyr/`, v4.5.0 as a submodule, without `west`): an out-of-tree SoC and board, threads in User mode
  isolated by the PMP through memory domains, and drivers for the chip's peripherals: UART with interrupts, GPIO, SPI and PWM
  with Zephyr's SiFive drivers, and I2C and the watchdog with drivers of our own. Not done: the timer's capture and
  the RTC as drivers, GPIO and I2C interrupts (the chip has one PLIC line for the eight GPIOs), and XIP.
- **The bootloader's default divisor** is 10, for the test board's 18.432 MHz oscillator (it was 18, from a 33.3 MHz clock:
  64,000 baud on the board); `boardsim` checks 115,200 baud with the straps open and with divisor 10 strapped.

The chip's physical flow with this bootloader and the Debug Mode PMP exemption (`mmu.sv`, `docs/debug.md`) is clean (KLayout DRC 0,
only the waived Magic findings, LVS 0, no antenna violations; setup +3.41 ns, hold +0.04 ns at 50 ns). The slack was
+8.74 ns before the exemption; the critical path is in the integer unit, not the MMU, so it looks like synthesis and
placement variance, but it was not shown.
