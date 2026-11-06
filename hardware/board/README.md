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
