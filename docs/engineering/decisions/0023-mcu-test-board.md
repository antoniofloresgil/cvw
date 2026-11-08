# 0023. Test board for the microcontroller (KiCad)

Status: accepted (2026-11-06)

## Context

`asic_soc_rv32imac` (ADR 0022) is a microcontroller in a pad ring of 28 pads (20 signal, 8 power) for a
QFN32 package. It is not fabricated yet, and its analog side (supplies, clock, reset supervision, flash,
converters) cannot go in silicon. A board is needed to bring the chip up, debug it easily, and to
validate the board and the firmware before the silicon exists. KiCad 10.0.8 is installed.

## Decision

One board, in KiCad 10, under `hardware/board/`:

- **Chip site.** The final QFN32 footprint (a QFN test socket once the package is known). Until silicon
  arrives, three Pmod headers (J5: clock, reset, UART, SPI; J6: GPIO0-7; J7: JTAG) carry the same nets at
  3.3 V to an FPGA board (Nexys Video, Pmod cables) running `asic_soc_rv32imac` with the chip removed, so the
  board, the straps, the bootloader and the firmware are checked first. Their VCC pins are left open, so
  that the board's and the FPGA's 3.3 V do not meet; the FPGA top for these pins is still to be written.
- **Power.** USB-C 5 V, then an LDO to 3.3 V (IOVDD) and one to 1.2 V (VDD). The chip's two
  supplies (VDD_IO, VDD_CORE) each pass through a jumper an ammeter replaces, all rails have test points,
  and 5 V and 3.3 V an LED (1.2 V cannot light one); the supplies stay separate so that a power-up
  order and the current of the core and of the pads can be measured.
- **Debug and console.** An FT2232H on the same USB-C: channel A as JTAG (TCK, TMS, TDI, TDO, for OpenOCD
  with its `ftdi` driver), channel B as the UART. A standard 10-pin JTAG header for other probes.
- **What silicon cannot hold.** An 18.432 MHz oscillator (115200 baud with the divisor 10 strapped on
  GPIO1 and GPIO3), a MAX811 reset supervisor with a push button (and the FT2232HL's nSRST), a W25Q32
  SPI flash for the bootloader's flash boot, DIP switches for the straps GPIO0-5 (`chip/boot.S`: baud
  divisor GPIO[4:0], UART-only boot GPIO[5]) against pull-downs, six push buttons on GPIO0-5 through
  1k, eight LEDs on all GPIOs through a 74AHC541 buffer, so neither disturbs a strap or a peripheral.
  On the I2C pins (GPIO6-7, 4.7k pull-ups): a 24LC256 EEPROM (0x50), a TMP102 (0x48), an ADS1115 ADC
  (0x49, with a trimmer and the DAC's output on two inputs) and an MCP4725 DAC (0x60). The timer's
  channels (GPIO0-3) and all GPIOs have test points.
- **No expansion header** (user decision 2026-11-06).
- **Base board first** (about 100 x 80 mm; it does not fit a Nano outline even without the Pmod headers,
  the FT2232HL, buttons, DIP switches and peripherals alone are twice the area). A Nano-format module (the chip, both regulators, clock, reset supervisor and flash on
  18 x 45 mm, 20 signals on 2 x 15 pins at 3.3 V) is deferred; the base board gets a female socket for it later.

## Consequences

- The pin assignment of the QFN32 (which pad goes to which package pin) is fixed with the bonding plan
  at tapeout. The board schematic uses the signal names of `chip_top.sv` so that the footprint's pin
  numbers are the only thing that changes.
- The bootloader used to read straps from all eight GPIOs, two of which the I2C pull-ups would hold
  high: the chip moved I2C to GPIO6-7 and the straps to GPIO0-5 for this board (ADR 0022).
- The schematic is generated (`hardware/board/mcu_board.py`), so a change is an edit of the description
  and a regeneration, checked by KiCad's ERC.
- FT2232H and its USB-C add cost and area; the board is a test board, not the final product.
- Generated manufacturing files (gerbers) are build products and stay out of the repository; the KiCad
  sources, the bill of materials and the check results go in.

## Simulation of the board

The board is simulated before it is built: `hardware/board/sim/` generates a SystemVerilog model from the
schematic's netlist (the chip's RTL plus behavioural models of the oscillator, reset supervisor, flash,
I2C devices, LED buffer and the FT2232's pins) and runs seven cocotb tests that play the person at the
board (`make boardsim` in `asic/librelane`). The wiring under test is the schematic's, so a mistake in the
netlist shows up as a failing test; four deliberate netlist errors (a duplicated I2C address, the UART
pins swapped, the flash's /HOLD pull-up removed, the LED buffer disabled) each fail it. It does not cover
the analogue side, timing or contention (see `hardware/board/README.md`). It found that the bootloader's
default divisor (18, from a 33.3 MHz clock) gives 64000 baud with the 18.432 MHz oscillator; the default is
now 10, 115200 baud with every DIP switch open.

## Future: a development module

After the base board has brought the chip up, a small module in the style of ST's Nucleo-32 (Arduino
Nano outline, 18 x 50 mm) or of an ESP32 DevKitC (28 x 55 mm, 2 x 19 pins), for using the chip on a
breadboard (user request 2026-11-06, not started):

- The chip soldered (no socket), the 3.3 V and 1.2 V regulators, oscillator, reset supervisor, a small
  SPI flash (USON or WSON), RESET and BOOT buttons (BOOT straps GPIO5 for the UART boot, fixed
  resistors set the default baud divisor), a power LED and a user LED.
- Debug and console on the USB-C like the Nucleo's ST-LINK: a CH347 (JTAG, UART, also I2C and SPI to
  the host) instead of the FT2232HL. It needs an OpenOCD newer than 0.12, tried against our Debug
  Module first.
- On the module and on its pins: a TMP102 temperature sensor, the I2C bus (GPIO6-7, with pull-ups, in
  the Nano's A4/A5 position), an ADS1115 whose four inputs are the "analog pins" A0-A3 (the chip has
  no ADC), optionally an MCP4725 DAC output.
- Left on the base board: the FT2232HL, strap DIP switches, buttons and LEDs on every GPIO, EEPROM,
  potentiometer, Pmod headers, test points and ammeter jumpers (two solder jumpers instead).
- The pin order is fixed when the module is designed; the Nucleo-32 outline needs parts on both
  sides of a four-layer board, the ESP32 one fits comfortably.
