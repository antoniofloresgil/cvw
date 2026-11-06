#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The test board of asic_soc_rv32imc (ADR 0023), as parts and nets.  `python3 mcu_board.py` writes
mcu_board.kicad_sch and one schematic per sheet; the nets are named after the pads of
asic/librelane/chip/chip_top.sv.

Supplies: USB-C 5 V -> 3.3 V (+3V3) -> 1.2 V (+1V2).  The chip's pads take VDD_IO and its core
VDD_CORE, each through a jumper (JP1, JP2) across which an ammeter measures the chip alone; the
rest of the board runs from +3V3.

The chip's site is a QFN32 (its pin numbers are provisional until the bonding plan) and three
Pmod-style headers carry the same nets, so that an FPGA running asic_soc_rv32imc takes the chip's
place before the silicon exists (with the chip removed).  The FT2232HL gives JTAG (channel A, with
nSRST on ADBUS4) and the UART (channel B) on the USB-C.

GPIO: straps GPIO0-5 at reset (boot.S: baud divisor GPIO[4:0], UART-only boot GPIO[5]), set by
DIP switches against 47k pull-downs; timer channels 0-3 on GPIO0-3; I2C on GPIO6-7 with 4.7k
pull-ups.  The LEDs hang off a buffer and the buttons pull through 1k, so neither disturbs a strap
or a peripheral.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import kicadgen as k  # noqa: E402

PROJECT = "mcu_board"
ROOT = k.uid(PROJECT, "root")

R0603 = "Resistor_SMD:R_0603_1608Metric"
C0603 = "Capacitor_SMD:C_0603_1608Metric"
C0805 = "Capacitor_SMD:C_0805_2012Metric"
LED0603 = "LED_SMD:LED_0603_1608Metric"
TP = "TestPoint:TestPoint_Pad_D1.5mm"
HDR2 = "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical"
BUTTON = "Button_Switch_SMD:SW_SPST_TL3342"

# The chip's QFN32 pinout (provisional until the bonding plan): each pad of the ring goes to the nearest
# package pin, from the pads' places in the final DEF; the eighth pin of each side is not bonded.
# Pins counter-clockwise from pin 1 at the top of the left side (chip_qfn32_socket.png).
RING = [["iovss", "gpio7", "gpio6", "gpio5", "gpio4", "tdo", "tdi"],          # 1-7: west pads, top to bottom
        ["clk", "rst_n", "vdd", "vss", "uart_rx", "uart_tx", "iovdd2"],        # 9-15: south pads, west to east
        ["spi_sck", "spi_mosi", "iovss2", "spi_miso", "spi_cs", "tck", "tms"],  # 17-23: east pads, south to north
        ["iovdd", "gpio3", "gpio2", "vdd2", "vss2", "gpio1", "gpio0"]]          # 25-31: north pads, east to west
PAD_NET = {"clk": "CLK", "rst_n": "RST_N", "uart_rx": "UART_RX", "uart_tx": "UART_TX", "spi_sck": "SPI_SCK",
           "spi_mosi": "SPI_MOSI", "spi_miso": "SPI_MISO", "spi_cs": "SPI_CS", "tck": "TCK", "tms": "TMS",
           "tdi": "TDI", "tdo": "TDO", "vdd": "VDD_CORE", "vdd2": "VDD_CORE", "vss": "GND", "vss2": "GND",
           "iovdd": "VDD_IO", "iovdd2": "VDD_IO", "iovss": "GND", "iovss2": "GND",
           **{f"gpio{i}": f"GPIO{i}" for i in range(8)}}
PAD_TYPE = {"vdd": "power_in", "vdd2": "power_in", "iovdd": "power_in", "iovdd2": "power_in", "vss": "power_in",
            "vss2": "power_in", "iovss": "power_in", "iovss2": "power_in", "uart_tx": "output", "spi_sck": "output",
            "spi_mosi": "output", "spi_cs": "output", "tdo": "output", "clk": "input", "rst_n": "input",
            "uart_rx": "input", "spi_miso": "input", "tck": "input", "tms": "input", "tdi": "input"}


def chip_symbol():
    pins = []
    for side, pads in enumerate(RING):
        for i, pad in enumerate(pads):
            pins.append((side * 8 + i + 1, pad, PAD_TYPE.get(pad, "bidirectional")))
    pins.append((33, "EP", "passive"))
    left = [p for p in pins if p[2] == "power_in" or p[1] == "EP"]
    right = [p for p in pins if p not in left]
    return k.custom_symbol("mcu_board:asic_soc_rv32imc", left, right,
                           footprint="Package_DFN_QFN:QFN-32-1EP_5x5mm_P0.5mm_EP3.3x3.3mm", width=25.4)


def caps(sheet, prefix, net, values):
    for i, v in enumerate(values):
        sheet.add("Device", "C", f"{prefix}{i + 1}", v, {"1": net, "2": "GND"},
                  footprint=C0805 if "u" in v and v != "1u" else C0603)


def power(s):
    s.add("Connector", "USB_C_Receptacle_USB2.0_16P", "J1", "USB-C",
          {"A4": "VBUS", "A9": "VBUS", "B4": "VBUS", "B9": "VBUS", "A1": "GND", "B1": "GND", "A12": "GND",
           "B12": "GND", "SH": "GND", "A5": "CC1", "B5": "CC2", "A6": "USB_DP", "B6": "USB_DP", "A7": "USB_DN",
           "B7": "USB_DN", "A8": "NC", "B8": "NC"},
          footprint="Connector_USB:USB_C_Receptacle_HRO_TYPE-C-31-M-12")
    s.add("Device", "R", "R1", "5.1k", {"1": "CC1", "2": "GND"}, footprint=R0603)
    s.add("Device", "R", "R2", "5.1k", {"1": "CC2", "2": "GND"}, footprint=R0603)
    s.add("Device", "Polyfuse", "F1", "500mA", {"1": "VBUS", "2": "+5V"}, footprint="Fuse:Fuse_1206_3216Metric")
    s.add("Power_Protection", "USBLC6-2SC6", "U1", "USBLC6-2SC6",
          {"1": "USB_DP", "6": "USB_DP", "3": "USB_DN", "4": "USB_DN", "2": "GND", "5": "+5V"})
    s.add("Regulator_Linear", "AP2112K-3.3", "U2", "AP2112K-3.3", {"VIN": "+5V", "EN": "+5V", "GND": "GND",
                                                                   "VOUT": "+3V3", "NC": "NC"})
    s.add("Regulator_Linear", "AP2112K-1.2", "U3", "AP2112K-1.2", {"VIN": "+3V3", "EN": "+3V3", "GND": "GND",
                                                                   "VOUT": "+1V2", "NC": "NC"})
    caps(s, "C", "+5V", ["10u", "100n"])
    for i, (net, vals) in enumerate((("+3V3", ["10u", "100n"]), ("+1V2", ["10u", "100n"]))):
        for j, v in enumerate(vals):
            s.add("Device", "C", f"C{3 + 2 * i + j}", v, {"1": net, "2": "GND"}, footprint=C0805 if "u" in v else C0603)
    s.add("Connector_Generic", "Conn_01x02", "JP1", "VDD_IO (ammeter)", {"1": "+3V3", "2": "VDD_IO"}, footprint=HDR2)
    s.add("Connector_Generic", "Conn_01x02", "JP2", "VDD_CORE (ammeter)", {"1": "+1V2", "2": "VDD_CORE"}, footprint=HDR2)
    for i, (net, r) in enumerate((("+5V", "2.2k"), ("+3V3", "1k"))):
        s.add("Device", "R", f"R{3 + i}", r, {"1": net, "2": f"LED_{net[1:]}"}, footprint=R0603)
        s.add("Device", "LED", f"D{1 + i}", "green", {"A": f"LED_{net[1:]}", "K": "GND"}, footprint=LED0603)
    for i, net in enumerate(("+5V", "+3V3", "+1V2", "VDD_IO", "VDD_CORE", "GND", "GND")):
        s.add("Connector", "TestPoint", f"TP{1 + i}", net, {"1": net}, footprint=TP, bom=False)
    for i in range(4):
        s.add("Mechanical", "MountingHole", f"H{i + 1}", "M3", {}, footprint="MountingHole:MountingHole_3.2mm_M3", bom=False)
    for i, net in enumerate(("VBUS", "+5V", "GND", "VDD_IO", "VDD_CORE", "FT_VPHY")):
        s.add("power", "PWR_FLAG", f"#FLG0{1 + i}", "PWR_FLAG", {"1": net})


def debug(s):
    s.add("Interface_USB", "FT2232HL", "U4", "FT2232HL", {
        "OSCI": "FT_OSCI", "OSCO": "FT_OSCO", "REF": "FT_REF", "DM": "USB_DN", "DP": "USB_DP",
        "VPHY": "FT_VPHY", "VPLL": "FT_VPHY", "VCORE": "FT_VCORE", "VREGOUT": "FT_VCORE", "VREGIN": "+3V3",
        "VCCIO": "+3V3", "GND": "GND", "AGND": "GND", "TEST": "GND", "~{RESET}": "FT_RESET_N",
        "ADBUS0": "FT_TCK", "ADBUS1": "FT_TDI", "ADBUS2": "FT_TDO", "ADBUS3": "FT_TMS", "ADBUS4": "FT_NSRST",
        "BDBUS0": "FT_TXD", "BDBUS1": "FT_RXD", "EECS": "FT_EECS", "EECLK": "FT_EECLK", "EEDATA": "FT_EEDATA",
        "~{SUSPEND}": "NC", "~{PWREN}": "NC",
        **{f"ADBUS{i}": "NC" for i in range(5, 8)}, **{f"ACBUS{i}": "NC" for i in range(8)},
        **{f"BDBUS{i}": "NC" for i in range(2, 8)}, **{f"BCBUS{i}": "NC" for i in range(8)}})
    s.add("Device", "Crystal_GND24", "Y1", "12MHz", {"1": "FT_OSCI", "3": "FT_OSCO", "2": "GND", "4": "GND"},
          footprint="Crystal:Crystal_SMD_3225-4Pin_3.2x2.5mm")
    s.add("Device", "C", "C7", "18p", {"1": "FT_OSCI", "2": "GND"}, footprint=C0603)
    s.add("Device", "C", "C8", "18p", {"1": "FT_OSCO", "2": "GND"}, footprint=C0603)
    s.add("Device", "R", "R5", "12k 1%", {"1": "FT_REF", "2": "GND"}, footprint=R0603)
    s.add("Device", "R", "R6", "10k", {"1": "+3V3", "2": "FT_RESET_N"}, footprint=R0603)
    s.add("Device", "FerriteBead_Small", "FB1", "600R@100MHz", {"1": "+3V3", "2": "FT_VPHY"},
          footprint="Inductor_SMD:L_0603_1608Metric")
    for i, (net, v) in enumerate((("FT_VPHY", "100n"), ("FT_VPHY", "4.7u"), ("FT_VCORE", "100n"), ("FT_VCORE", "100n"),
                                  ("FT_VCORE", "4.7u"), ("+3V3", "100n"), ("+3V3", "100n"), ("+3V3", "100n"),
                                  ("+3V3", "100n"), ("+3V3", "4.7u"))):
        s.add("Device", "C", f"C{9 + i}", v, {"1": net, "2": "GND"}, footprint=C0805 if "u" in v else C0603)
    s.add("Memory_EEPROM", "93LCxxB", "U5", "93LC56B", {"CS": "FT_EECS", "SCLK": "FT_EECLK", "DI": "FT_EEDATA",
                                                       "DO": "FT_EEDO", "GND": "GND", "VCC": "+3V3", "6": "NC", "7": "NC"},
          footprint="Package_SO:SOIC-8_3.9x4.9mm_P1.27mm")
    s.add("Device", "R", "R7", "2.2k", {"1": "FT_EEDO", "2": "FT_EEDATA"}, footprint=R0603)
    s.add("Device", "R", "R8", "10k", {"1": "+3V3", "2": "FT_EEDATA"}, footprint=R0603)
    s.add("Device", "C", "C19", "100n", {"1": "+3V3", "2": "GND"}, footprint=C0603)
    # 33R in series from the FT2232HL to the chip: damping, and a place to cut a line
    for i, (a, b) in enumerate((("FT_TCK", "TCK"), ("FT_TDI", "TDI"), ("TDO", "FT_TDO"), ("FT_TMS", "TMS"),
                                ("FT_TXD", "UART_RX"), ("UART_TX", "FT_RXD"))):
        s.add("Device", "R", f"R{9 + i}", "33", {"1": a, "2": b}, footprint=R0603)
    s.add("Device", "R", "R15", "1k", {"1": "FT_NSRST", "2": "MR_N"}, footprint=R0603)
    s.add("Connector_Generic", "Conn_02x05_Odd_Even", "J2", "JTAG (Cortex 10-pin)",
          {"1": "VDD_IO", "2": "TMS", "3": "GND", "4": "TCK", "5": "GND", "6": "TDO", "7": "NC", "8": "TDI",
           "9": "GND", "10": "MR_N"}, footprint="Connector_PinHeader_1.27mm:PinHeader_2x05_P1.27mm_Vertical_SMD")
    s.add("Connector_Generic", "Conn_01x03", "J3", "UART", {"1": "GND", "2": "UART_TX", "3": "UART_RX"},
          footprint="Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical")


def chip(s):
    k.custom_symbol_cache["mcu_board:asic_soc_rv32imc"] = chip_symbol()
    nets = {pad: PAD_NET[pad] for pads in RING for pad in pads}
    nets["EP"] = "GND"
    s.add("mcu_board", "asic_soc_rv32imc", "U6", "asic_soc_rv32imc", nets)
    caps(s, "C2", "VDD_IO", ["100n", "100n", "4.7u"])
    caps(s, "C3", "VDD_CORE", ["100n", "100n", "4.7u"])
    s.add("Oscillator", "ASE-xxxMHz", "X1", "18.432MHz", {"EN": "VDD_IO", "Vdd": "VDD_IO", "GND": "GND", "OUT": "OSC_OUT"})
    s.add("Device", "C", "C40", "100n", {"1": "VDD_IO", "2": "GND"}, footprint=C0603)
    s.add("Device", "R", "R16", "33", {"1": "OSC_OUT", "2": "CLK"}, footprint=R0603)
    s.add("Power_Supervisor", "MAX811SEUS-T", "U7", "MAX811S (2.93 V)",
          {"VCC": "VDD_IO", "GND": "GND", "~{RESET}": "RST_N", "~{MR}": "MR_N"})
    s.add("Switch", "SW_Push", "SW1", "RESET", {"1": "MR_N", "2": "GND"}, footprint=BUTTON)
    s.add("Memory_Flash", "W25Q32JVSS", "U8", "W25Q32JVSS",
          {"~{CS}": "SPI_CS", "CLK": "SPI_SCK", "DI/IO_{0}": "SPI_MOSI", "DO/IO_{1}": "SPI_MISO",
           "~{WP}/IO_{2}": "FLASH_WP_N", "~{HOLD}/~{RESET}/IO_{3}": "FLASH_HOLD_N", "VCC": "VDD_IO", "GND": "GND"})
    s.add("Device", "C", "C41", "100n", {"1": "VDD_IO", "2": "GND"}, footprint=C0603)
    for i, net in enumerate(("SPI_CS", "FLASH_WP_N", "FLASH_HOLD_N")):
        s.add("Device", "R", f"R{17 + i}", "10k", {"1": "VDD_IO", "2": net}, footprint=R0603)
    for i, net in enumerate(("CLK", "RST_N", "UART_TX", "UART_RX", "SPI_SCK", "SPI_CS")):
        s.add("Connector", "TestPoint", f"TP{10 + i}", net, {"1": net}, footprint=TP, bom=False)


def peripherals(s):
    # Straps: a DIP switch pulls GPIO0-5 up through 4.7k against a 47k pull-down (open: 0)
    s.add("Switch", "SW_DIP_x06", "SW2", "BOOT STRAPS",
          {**{str(i + 1): f"GPIO{i}" for i in range(6)}, **{str(12 - i): f"STRAP{i}" for i in range(6)}},
          footprint="Button_Switch_SMD:SW_DIP_SPSTx06_Slide_6.7x16.8mm_W8.61mm_P2.54mm_LowProfile")
    for i in range(6):
        s.add("Device", "R", f"R{20 + i}", "4.7k", {"1": f"STRAP{i}", "2": "VDD_IO"}, footprint=R0603)
        s.add("Device", "R", f"R{26 + i}", "47k", {"1": f"GPIO{i}", "2": "GND"}, footprint=R0603)
    for i in range(6):
        s.add("Device", "R", f"R{32 + i}", "1k", {"1": f"GPIO{i}", "2": f"BTN{i}"}, footprint=R0603)
        s.add("Switch", "SW_Push", f"SW{3 + i}", f"GPIO{i}", {"1": f"BTN{i}", "2": "GND"}, footprint=BUTTON)
    # LEDs through a buffer powered from +3V3
    s.add("74xx", "74AHC541", "U9", "74AHC541",
          {"G1": "GND", "G2": "GND", "GND": "GND", "VCC": "+3V3", **{f"A{i}": f"GPIO{i}" for i in range(8)},
           **{f"Y{i}": f"LEDDRV{i}" for i in range(8)}}, footprint="Package_SO:TSSOP-20_4.4x6.5mm_P0.65mm")
    s.add("Device", "C", "C42", "100n", {"1": "+3V3", "2": "GND"}, footprint=C0603)
    for i in range(8):
        s.add("Device", "R", f"R{38 + i}", "1k", {"1": f"LEDDRV{i}", "2": f"LEDA{i}"}, footprint=R0603)
        s.add("Device", "LED", f"D{3 + i}", f"GPIO{i}", {"A": f"LEDA{i}", "K": "GND"}, footprint=LED0603)
    for i in range(8):
        s.add("Connector", "TestPoint", f"TP{20 + i}", f"GPIO{i}", {"1": f"GPIO{i}"}, footprint=TP, bom=False)
    # I2C on GPIO6 (SCL) and GPIO7 (SDA): EEPROM 0x50, TMP102 0x48, ADS1115 0x49, MCP4725 0x60
    s.add("Device", "R", "R46", "4.7k", {"1": "VDD_IO", "2": "GPIO6"}, footprint=R0603)
    s.add("Device", "R", "R47", "4.7k", {"1": "VDD_IO", "2": "GPIO7"}, footprint=R0603)
    s.add("Memory_EEPROM", "24LC256", "U10", "24LC256", {"A0": "GND", "A1": "GND", "A2": "GND", "GND": "GND",
                                                        "SDA": "GPIO7", "SCL": "GPIO6", "WP": "GND", "VCC": "+3V3"},
          footprint="Package_SO:SOIC-8_3.9x4.9mm_P1.27mm")
    s.add("Sensor_Temperature", "TMP102xxDRL", "U11", "TMP102", {"SCL": "GPIO6", "SDA": "GPIO7", "GND": "GND",
                                                                 "ALERT": "NC", "ADD0": "GND", "V+": "+3V3"})
    s.add("Analog_ADC", "ADS1115IDGS", "U12", "ADS1115", {"ADDR": "+3V3", "ALERT/RDY": "NC", "GND": "GND",
                                                         "AIN0": "POT", "AIN1": "DAC_OUT", "AIN2": "AIN2",
                                                         "AIN3": "AIN3", "VDD": "+3V3", "SDA": "GPIO7", "SCL": "GPIO6"})
    s.add("Analog_DAC", "MCP4725xxx-xCH", "U13", "MCP4725", {"VOUT": "DAC_OUT", "VSS": "GND", "VDD": "+3V3",
                                                             "SDA": "GPIO7", "SCL": "GPIO6", "A0": "GND"})
    for i in range(4):
        s.add("Device", "C", f"C{43 + i}", "100n", {"1": "+3V3", "2": "GND"}, footprint=C0603)
    s.add("Device", "R_Potentiometer", "RV1", "10k", {"1": "+3V3", "2": "POT", "3": "GND"},
          footprint="Potentiometer_SMD:Potentiometer_Bourns_3314J_Vertical")
    s.add("Connector_Generic", "Conn_01x04", "J4", "ANALOG", {"1": "AIN2", "2": "AIN3", "3": "DAC_OUT", "4": "GND"},
          footprint="Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical")


def fpga(s):
    # Pmod pinout: 1-4 and 7-10 signals, 5 and 11 GND, 6 and 12 VCC (left open: the FPGA board has its own 3.3 V)
    groups = [("J5", "PMOD A", ["CLK", "RST_N", "UART_RX", "UART_TX", "SPI_SCK", "SPI_MOSI", "SPI_MISO", "SPI_CS"]),
              ("J6", "PMOD B", [f"GPIO{i}" for i in range(8)]),
              ("J7", "PMOD C", ["TCK", "TMS", "TDI", "TDO", "NC", "NC", "NC", "NC"])]
    # The header's pads alternate between the rows (1 and 2 face each other): Pmod pin n of the top row
    # (1-6) is pad 2n-1, pin n+6 of the bottom row pad 2n.
    for ref, value, sig in groups:
        pmod = dict(zip((1, 2, 3, 4, 7, 8, 9, 10), sig)) | {5: "GND", 11: "GND", 6: "NC", 12: "NC"}
        nets = {str(2 * n - 1 if n <= 6 else 2 * (n - 6)): net for n, net in pmod.items()}
        s.add("Connector_Generic", "Conn_02x06_Odd_Even", ref, value, nets,
              footprint="Connector_PinHeader_2.54mm:PinHeader_2x06_P2.54mm_Horizontal")
    s.text(15, 15, "FPGA headers: an FPGA running asic_soc_rv32imc on these nets replaces the chip (remove U6).")


SHEETS = [("power", power, "Power: USB-C, 3.3 V and 1.2 V", "A3"), ("debug", debug, "USB: FT2232HL JTAG and UART", "A3"),
          ("chip", chip, "asic_soc_rv32imc, clock, reset, SPI flash", "A3"),
          ("peripherals", peripherals, "Straps, buttons, LEDs, I2C and analog", "A3"),
          ("fpga", fpga, "FPGA headers", "A4")]
PAPER_HEIGHT = {"A4": 210, "A3": 297, "A2": 420, "A1": 594}


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE
    entries = []
    for name, build, title, paper in SHEETS:
        sheet_uuid = k.uid(PROJECT, "sheet", name)
        s = k.Sheet(PROJECT, name, ROOT, sheet_uuid, paper=paper, title=title)
        build(s)
        if s.bottom > PAPER_HEIGHT[paper] - 45:      # clear of the title block
            raise SystemExit(f"sheet {name}: the parts reach {s.bottom:.0f} mm, more than {paper} holds")
        s.write(out / f"{name}.kicad_sch")
        entries.append((name, f"{name}.kicad_sch", sheet_uuid))
    k.write_root(out / f"{PROJECT}.kicad_sch", PROJECT, ROOT, "MCU test board (asic_soc_rv32imc)", entries)
    k.write_symbol_lib(out / f"{PROJECT}.kicad_sym", [chip_symbol()])
    (out / "sym-lib-table").write_text('(sym_lib_table\n  (version 7)\n  (lib (name "mcu_board")(type "KiCad")'
                                       '(uri "${KIPRJMOD}/mcu_board.kicad_sym")(options "")(descr "Symbols of this board"))\n)\n')
    pro = out / f"{PROJECT}.kicad_pro"
    if not pro.exists():
        pro.write_text('{\n  "meta": {\n    "filename": "mcu_board.kicad_pro",\n    "version": 3\n  }\n}\n')


if __name__ == "__main__":
    main()
