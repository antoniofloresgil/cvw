# MCU test board

KiCad 10 project for the test board of `asic_soc_rv32imc`; the decisions are in
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
assembled. The BOM leaves the LCSC column empty: JLCPCB's tool matches by value and footprint and
prefers its basic parts.

    python3 mcu_pcb.py                                         # the system Python, which has pcbnew
    kicad-cli pcb drc --refill-zones --schematic-parity mcu_board.kicad_pcb

`chip_qfn32_socket.png` shows the chip's real layout (final GDS) in the QFN32 with the bonding the
schematic assumes: each pad of the ring to the nearest package pin, one pin free per side.
