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
which reads the schematic's netlist, loads the footprints, gives the pads their nets, packs the parts of
each sheet into a region and writes the design rules into `mcu_board.kicad_pro`. It is not routed yet.

    python3 mcu_pcb.py                                         # the system Python, which has pcbnew
    kicad-cli pcb drc --refill-zones --schematic-parity mcu_board.kicad_pcb

`chip_qfn32_socket.png` shows the chip's real layout (final GDS) in the QFN32 with the bonding the
schematic assumes: each pad of the ring to the nearest package pin, one pin free per side.
