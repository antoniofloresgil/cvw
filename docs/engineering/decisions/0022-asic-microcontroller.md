# ADR 0022: the open-ASIC chip as a microcontroller

Status: **accepted**; steps 1-3 (SPI-flash boot, 32 KiB RAM, debug and trace) are implemented,
step 4 (the MCU peripherals) is implemented and passes its tests, its silicon numbers are in the
[experiment record](../experiments/2026-11-02-open-asic-flow.md). Applies to the chip of the
[open ASIC flow](../experiments/2026-11-02-open-asic-flow.md) (`asic_soc_rv32imac`,
`asic/librelane/chip/`), on branch `open-asic-flow`.

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

Steps 1-3 are done (SPI-flash boot with UART fallback, 32 KiB RAM, JTAG debug and trace, in
a 2.6 mm die at 45 ns). Step 4 adds timers with PWM and input capture, a watchdog, an I2C
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
- Interrupt latency and nesting are below a Cortex-M3 NVIC (no hardware stacking)
  until a CLIC-like controller exists.
