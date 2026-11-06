# 0023. Test board for the microcontroller (KiCad)

Status: accepted (2026-11-06)

## Context

`asic_soc_rv32imc` (ADR 0022) is a microcontroller in a pad ring of 28 pads (20 signal, 8 power) for a
QFN32 package. It is not fabricated yet, and its analog side (supplies, clock, reset supervision, flash,
converters) cannot go in silicon. A board is needed to bring the chip up, debug it easily, and to
validate the board and the firmware before the silicon exists. KiCad 10.0.8 is installed.

## Decision

One board, in KiCad 10, under `hardware/board/`:

- **Chip site.** The final QFN32 footprint. Until silicon arrives, a header carrying the same signals
  with the same names and 3.3 V levels takes an FPGA board (Nexys Video through its Pmod/FMC) running the
  `asic_soc_rv32imc` configuration, so the board, the straps and the firmware are checked first.
- **Power.** USB-C 5 V, then an LDO to 3.3 V (IOVDD) and one to 1.2 V (VDD). Each rail has a
  measurement jumper in series, test points and an LED; the supplies stay separate so that a power-up
  order and the current of the core and of the pads can be measured.
- **Debug and console.** An FT2232H on the same USB-C: channel A as JTAG (TCK, TMS, TDI, TDO, for OpenOCD
  with its `ftdi` driver), channel B as the UART. A standard 10-pin JTAG header for other probes.
- **What silicon cannot hold.** Crystal oscillator for the clock, reset supervisor with a push button,
  SPI flash for the bootloader's flash boot, 8 LEDs and 8 push buttons on the GPIOs, and a bank of
  DIP switches for the straps GPIO[7:0] read at reset (`chip/boot.S`: baud divisor, UART-only boot).
  For the peripherals: an I2C EEPROM and a temperature sensor as slaves for the I2C master, an external
  ADC and DAC on the SPI/I2C pins, and the timer's PWM and capture pins on test points.
- **No expansion header** (user decision 2026-11-06).
- **Base board first.** A Nano-format module (the chip, both regulators, clock, reset supervisor and flash on
  18 x 45 mm, 20 signals on 2 x 15 pins at 3.3 V) is deferred; the base board gets a female socket for it later.

## Consequences

- The pin assignment of the QFN32 (which pad goes to which package pin) is fixed with the bonding plan
  at tapeout. The board schematic uses the signal names of `chip_top.sv` so that the footprint's pin
  numbers are the only thing that changes.
- The GPIO pins are shared between the straps, the buttons, the LEDs and the alternate functions
  (timer, I2C): buttons and LEDs go through jumpers or series resistors so they do not disturb a strap
  or a peripheral.
- FT2232H and its USB-C add cost and area; the board is a test board, not the final product.
- Generated manufacturing files (gerbers) are build products and stay out of the repository; the KiCad
  sources, the bill of materials and the check results go in.
