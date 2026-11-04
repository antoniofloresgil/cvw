# ADR 0022: the open-ASIC chip as a microcontroller

Status: **proposed** (2026-11-04); nothing implemented yet. Applies to the chip of the
[open ASIC flow](../experiments/2026-11-02-open-asic-flow.md) (`asic_soc_rv32imc`,
`asic/librelane/chip/`), on branch `open-asic-flow`.

## Context

The chip is already most of a small microcontroller: an RV32IMC core, an AHB bus with
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

## Alternatives and consequences

- Embedded flash is not possible in the open PDK; a UART-only loader is not an MCU.
  External flash costs 4-6 pins (or 0-2 more if it shares the SPI pads).
- Pin budget: 24 pads today, plus 4 JTAG, plus the flash, fills QFN32; pin
  multiplexing is what makes the peripherals fit.
- More SRAM and peripherals grow the core area; the SRAM size and peripheral set
  decide whether the 2.0 x 2.0 mm die is enough, and must be fixed before the floorplan.
- Interrupt latency and nesting are below a Cortex-M3 NVIC (no hardware stacking)
  until a CLIC-like controller exists.
