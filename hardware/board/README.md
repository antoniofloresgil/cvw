# MCU test board

KiCad 10 project for the test board of `asic_soc_rv32imac`; the decisions are in
`docs/engineering/decisions/0023-mcu-test-board.md`.

The schematic is generated: `mcu_board.py` describes the parts and the net of each pin, and
`kicadgen.py` (standard library only) writes `mcu_board.kicad_sch`, one schematic per sheet (power,
debug, chip, peripherals, fpga), the chip's symbol in `mcu_board.kicad_sym` and `sym-lib-table`.
Edit `mcu_board.py` and regenerate rather than editing the schematics by hand:

    python3 mcu_board.py
    kicad-cli sch erc mcu_board.kicad_sch          # 0 violations expected

Every connected pin gets a short wire and a global label (a power symbol for GND, +5V, +3V3, +1V2,
VBUS), so a net is the set of pins with the same name. The chip's QFN32 pin numbers follow the pad
ring and are provisional until the bonding plan.

The PCB (`mcu_board.kicad_pcb`, 110 x 85 mm, four layers: In1 GND, In2 +3V3) is placed by `mcu_pcb.py`,
which reads the schematic's netlist, loads the footprints, gives the pads their nets, places the parts
by function (`FIXED` positions and `GROUPS` packed beside the part they serve) and writes the design
rules into `mcu_board.kicad_pro`. `route.py` then routes it with Freerouting (2.5.0, run without its GUI):
it first gives every SMD pad of GND and +3V3 a locked via to its plane, exports the board as Specctra DSN,
routes F.Cu and B.Cu, and imports the result. `mcu_board_top.png` and `mcu_board_bottom.png` are KiCad's
3D renders.

    python3 mcu_pcb.py && python3 route.py      # about 5 minutes; regenerating discards the routing

`route.py` routes the USB pair itself first (straight and coupled, both lines 9.28 mm, 0.30 mm tracks
0.20 mm apart: about 90-95 ohm on JLCPCB's JLC04161H-7628 stack-up, an estimate to confirm with their
impedance calculator), joins the connector's second VBUS pair under it, and cleans up what the router
leaves. The router is not deterministic: when a run leaves a connection, run both scripts again.
`mcu_pcb.py --update-values` copies changed values from the schematic onto the routed board.

Routing result: DRC with 0 unconnected items and no electrical violation; the only warnings are the
Pmod footprints' silkscreen outline past the board edge, which the maker clips. The board matches the
schematic.

Manufacturing files (`fab/`, git-ignored):

    python3 fab.py      # Gerbers + drill (zip), BOM and CPL in JLCPCB's columns, schematic and PCB PDFs

U6 (the chip, in a hand-soldered QFN socket), the test points and the mounting holes are not
assembled. The BOM carries LCSC part numbers (the `LCSC` table in `fab.py`, checked against JLCPCB's
catalogue on 2026-11-06): basic parts for the passives and the ferrite, extended parts for the rest;
the through-hole headers and jumpers have none and are soldered by hand.

    python3 mcu_pcb.py                                         # the system Python, which has pcbnew
    kicad-cli pcb drc --refill-zones --schematic-parity mcu_board.kicad_pcb

`chip_qfn32_socket.png` shows the chip's real layout (final GDS) in the QFN32 with the bonding the
schematic assumes: each pad of the ring to the nearest package pin, one pin free per side.

## Simulation

`sim/` simulates the chip on the board's own netlist (`make boardsim` in `asic/librelane`, or
`tabbypy3 test_board.py` there with `WORK` and `IHP_PDK` set as `make chipsim` sets them):

- `gen_board.py` turns the schematic's netlist (`kicad-cli`) into `board.sv`: chip_top (the RTL) and
  the models of `models.sv`, wired as the schematic wires them. Series parts and resistors between
  signals join nets, a resistor to a rail is a pull-up or pull-down, and each contact of a switch drives
  the level of its source side (a rail, else the stronger pull) when the test closes it; where a button
  and a strap meet on one pin, the lower source impedance wins (1 k against 4.7 k). A part with no
  model stops the script. It also checks every supply against its data sheet's range, J2 against the
  Cortex Debug 10-pin pinout, and the potentiometer against the ADC.
- `models.sv`: oscillator, MAX811, W25Q32 (Read, Fast Read, JEDEC ID), 24LC256, TMP102, ADS1115,
  MCP4725, 74AHC541, LEDs and the FT2232's JTAG and UART pins.
- `test_board.py` plays the person at the board (DIP switch, buttons, flash, the FT2232's pins) in seven
  tests: power-up reset and boot from the board's flash with the power LEDs and GPIO LEDs, the reset
  button, the UART's baud rate with the straps and the 18.432 MHz oscillator, UART boot, JTAG through
  the FT2232 and its reset line, the four I2C devices at their addresses (`i2c.S`), and straps, buttons
  and LEDs on their GPIO pins (`gpio.S`).

What it does not cover: the analogue side (supplies, USB, the ADC inputs, the DAC output, LED
currents), timing (the supervisor's 140 ms is scaled to 20 us and the EEPROM writes at once), and
contention. Verilator resolves nets without strengths, so a test must not make the chip drive a pin
that a closed strap or a pressed button also drives. The chip's pinout in the QFN32 comes from the
schematic's symbol, not from the simulation.

Findings: with every DIP switch open the bootloader's default divisor 18 gives 64000 baud at 18.432 MHz,
not 115200; set GPIO1 and GPIO3 (divisor 10) for 115200.
