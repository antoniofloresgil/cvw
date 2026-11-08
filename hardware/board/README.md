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

## The chip's socket: footprint `mcu_board:Yamaichi_IC550-0324-007_QFN32`

The chip (QFN32, 5 x 5 mm, 0.5 mm pitch) will sit in a Yamaichi IC550-0324-007-G test socket, hinged lid, about 92 USD.
`socket_fp.py` writes its footprint, `mcu_board.pretty/Yamaichi_IC550-0324-007_QFN32.kicad_mod`, from Yamaichi's
drawing A111332-001 (`socket_footprint.png` is its picture: `python3 socket_preview.py`). The socket is through-hole:

- 32 holes of 0.5 mm (+0.1/0, drilled 0.55 mm, pads of 0.9 mm) in four groups. A side has 8 contacts at the
  package's 0.5 mm pitch whose tails go to three rows 1 mm apart (squares of 7.5, 9.5 and 11.5 mm): contact k of a side
  is in row k mod 3, so the holes of a row are 1.5 mm apart and the pads are 0.22 mm from each other at the least.
- A ground pin at the centre, hole of 0.8 mm (+0.05/0, drilled 0.85 mm), pad 33, which presses on the package's exposed
  pad. The drawing's note 1 says to mask the centre hole so that solder does not flow into it: the pad has no mask opening.
- Two locating holes of 1.6 mm (+0.1/0, drilled 1.65 mm, not plated) at (+8, +7) and (-8, -7), and five stand-off areas
  (four squares of 5 mm at (+-8.5, +-8.5) and a circle of 2.5 mm at the centre) where the footprint has rule areas
  that keep tracks, vias and pours out of the top copper ("keep the board trace out of area").
- The body is 24.5 x 22 mm, with the hinge on the right: courtyard 11 mm to the left of the package centre, 13.5 mm to the
  right and 11 mm above and below.

The package goes in with its pin 1 at the bottom left corner of the nest (the drawing's pin 1 indicator), which is the
standard drawing turned 90 degrees counter-clockwise: pins 1-8 are on the bottom side from left to right, 9-16 up the
right side, 17-24 along the top from right to left and 25-32 down the left side.

What the drawing does not say, and the footprint assumes: that the tail of the contact under a package pad is at the
same position along its side as the pad (the 0.5 mm steps of the pattern say so, but there is no pin table). Check it
with a multimeter on the first socket (a package pin against the hole of the same number) before ordering several boards.

The footprint is not in the board yet. The body, 24.5 x 22 mm, covers where the chip's decoupling capacitors, the supply
jumpers, the clock and the flash are now: using it means placing and routing the board again (see `mcu_pcb.py` and
`route.py`, which also need to read footprints from `mcu_board.pretty`).

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

Findings: the bootloader's default divisor was 18, which gives 64000 baud at 18.432 MHz, not 115200; it is
now 10, so every DIP switch open gives 115200 (strapping 10 on GPIO1 and GPIO3 still does).
