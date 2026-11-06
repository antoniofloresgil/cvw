# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""cocotb test of the MCU test board: the asic_soc_rv32imac RTL on the board's own netlist.

gen_board.py turns the KiCad schematic into build/board.sv, which wires chip_top and the models of
models.sv (oscillator, reset supervisor, SPI flash, I2C devices, LED buffer, LEDs, the FT2232's pins)
as the schematic does.  The tests play the person at the board: they set the DIP switch and the push
buttons, program the flash, and use the FT2232's pins as the host does (JTAG on port A, the UART on
port B).  What they check is the board, not the chip: that the chip boots from the board's flash with
the straps on its pins, that the UART runs at the baud rate the straps and the oscillator give, that
the debugger and the reset line reach the chip, that every I2C device answers at its address, and that
buttons, straps and LEDs sit on the GPIO pins they should.

Run with the Python of oss-cad-suite, after `make CONFIG=asic_soc_rv32imac inputs` in asic/librelane
(whose work/asic_soc_rv32imac/config.json lists the chip's sources):  tabbypy3 test_board.py
`make boardsim` there does both.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

HERE = Path(__file__).resolve().parent
WALLY = Path(os.environ.get("WALLY", HERE.parents[2]))
CHIPTEST = WALLY / "asic/librelane/chip/test"
sys.path.insert(0, str(CHIPTEST))
sys.path.insert(0, str(WALLY / "testbench/debug/etrace"))

CLK_MHZ = 18.432
BAUD = 115200
DIVISOR = 10                                  # f_clk / (16 * 10) = 115200 baud: straps GPIO[4:0] = 10
UART_BOOT = 0x20                              # GPIO[5]
TIMEOUT_NS = 20000                            # the reset supervisor's timeout in the model


def bit_ps(baud):
    return round(1e12 / baud)


class Board:
    """The person at the board: switches and buttons, the flash, and the FT2232's pins."""

    def __init__(self, dut):
        self.dut = dut
        self.ad = 0x00                         # shadow of the FT2232's Port A outputs

    # -- switches ------------------------------------------------------------------------
    def dip(self, value):
        self.dut.sw2_closed.value = value

    async def reset_button(self, ns=2000):
        self.dut.sw1_pressed.value = 1
        await Timer(ns, unit="ns")
        self.dut.sw1_pressed.value = 0

    # -- flash ---------------------------------------------------------------------------
    flash_len = 0                              # bytes the last image wrote, to erase them

    def program_flash(self, image):
        mem = self.dut.u8.mem
        for i in range(max(Board.flash_len, len(image))):
            mem[i].value = image[i] if i < len(image) else 0xFF
        Board.flash_len = len(image)

    # -- the FT2232 ----------------------------------------------------------------------
    async def uart_send(self, byte, baud=BAUD):
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            self.dut.u4.bdbus_out.value = 0x00 | bit
            await Timer(bit_ps(baud), unit="ps")

    async def uart_recv(self, baud=BAUD, timeout_ms=5):
        """The next byte on the chip's UART_TX, which the FT2232 samples as RXD."""
        t = bit_ps(baud)
        for _ in range(int(timeout_ms * 1e6 * CLK_MHZ / 1000)):
            await FallingEdge(self.dut.CLK)
            if self.dut.UART_TX.value == 0:
                break
        else:
            raise AssertionError("no UART start bit")
        await Timer(t + t // 2, unit="ps")                 # the middle of bit 0
        byte = 0
        for i in range(8):
            byte |= int(self.dut.UART_TX.value) << i
            await Timer(t, unit="ps")
        assert self.dut.UART_TX.value == 1, "missing stop bit"
        return byte

    async def uart_bit_time(self, timeout_ms=5):
        """The bit time in ns of the next character, which must be 'W' (0x57: start, then 1 1 1 0 1 0 1 0,
        stop): the UART's first start bit can be short, so measure from the second falling edge to the
        fourth, which are 4 bit times apart."""
        falls, prev = [], 1
        for _ in range(int(timeout_ms * 1e6 * CLK_MHZ / 1000)):
            await FallingEdge(self.dut.CLK)
            now = int(self.dut.UART_TX.value)
            if prev == 1 and now == 0:
                falls.append(cocotb.utils.get_sim_time("ps"))
                if len(falls) == 4:
                    return (falls[3] - falls[1]) / 4 / 1000
            prev = now
        raise AssertionError("no UART character")

    # JTAG on Port A: bit 0 TCK, 1 TDI, 2 TDO, 3 TMS, 4 the reset line
    @property
    def tck(self):
        return _Pin(self, 0)

    @property
    def tdi(self):
        return _Pin(self, 1)

    @property
    def tms(self):
        return _Pin(self, 3)

    @property
    def tdo(self):
        return _Pin(self, 2)


class _Pin:
    """A pin of the FT2232's Port A with the .value of a cocotb handle, so test_chip's Jtag drives it."""

    def __init__(self, board, bit):
        self.board, self.bit = board, bit

    @property
    def value(self):
        return (int(self.board.dut.u4.adbus_in.value) >> self.bit) & 1

    @value.setter
    def value(self, v):
        b = self.board
        b.ad = (b.ad & ~(1 << self.bit)) | (v << self.bit)
        b.dut.u4.adbus_out.value = b.ad
        b.dut.u4.adbus_oe.value = 0x0B                        # TCK, TDI and TMS are outputs


def flash_image(program):
    return b"WALY" + len(program).to_bytes(4, "little") + program


def build_file(name):
    return (HERE / "build" / name).read_bytes()


async def boot(dut, board, straps, flash=b"", ready="F", baud=BAUD):
    """Press the reset button with the DIP switch at straps and the flash programmed, and wait for
    the bootloader's first character."""
    board.dip(straps)
    board.program_flash(flash)
    await board.reset_button()
    char = await board.uart_recv(baud)
    assert char == ord(ready), f"the bootloader sent {chr(char)!r}, not {ready!r}"


def leds(dut):
    """D3-D10 as a byte, D3 in bit 0."""
    return sum(int(getattr(dut, f"d{n}_on").value) << (n - 3) for n in range(3, 11))


###########################################################################################


@cocotb.test()
async def power_up_and_boot(dut):
    """From power-up: the supervisor holds the chip in reset for its timeout, then the bootloader reads
    the flash and the program runs; the power LEDs are on and GPIO[7:0] = 42 lights D4, D6 and D8."""
    board = Board(dut)
    board.dip(DIVISOR)
    board.program_flash(flash_image(build_file("hello.bin")))
    assert int(dut.RST_N.value) == 0, "the chip is not in reset at power-up"
    t0 = cocotb.utils.get_sim_time("ns")
    await RisingEdge(dut.RST_N)
    held = cocotb.utils.get_sim_time("ns") - t0
    assert 0.9 * TIMEOUT_NS < held < 1.1 * TIMEOUT_NS, f"reset held {held} ns, not about {TIMEOUT_NS}"
    assert int(dut.d1_on.value) == 1 and int(dut.d2_on.value) == 1, "the power LEDs are off"
    assert await board.uart_recv() == ord("F"), "the bootloader did not boot from the board's flash"
    assert bytes([await board.uart_recv() for _ in range(3)]) == b"OK\n"
    await Timer(20, unit="us")
    # D3.. follow GPIO0..: 42 = 0b00101010
    assert leds(dut) == 42, f"LEDs 0x{leds(dut):02x}, not 0x2a (GPIO[7:0] = 42)"


@cocotb.test()
async def reset_button(dut):
    """SW1 holds the chip in reset while it is pressed, and for the timeout after."""
    board = Board(dut)
    await boot(dut, board, DIVISOR, flash_image(build_file("hello.bin")))
    dut.sw1_pressed.value = 1
    await Timer(500, unit="ns")
    assert int(dut.RST_N.value) == 0, "RST_N did not go low with SW1 pressed"
    await Timer(3 * TIMEOUT_NS, unit="ns")
    assert int(dut.RST_N.value) == 0, "RST_N went high with SW1 still pressed"
    dut.sw1_pressed.value = 0
    t0 = cocotb.utils.get_sim_time("ns")
    await RisingEdge(dut.RST_N)
    held = cocotb.utils.get_sim_time("ns") - t0
    assert 0.9 * TIMEOUT_NS < held < 1.1 * TIMEOUT_NS, f"reset held {held} ns after the release"
    assert await board.uart_recv() == ord("F"), "the chip did not boot again"


@cocotb.test()
async def baud_rate(dut):
    """The UART's bit time with the DIP switch at the divisor the board's 18.432 MHz oscillator calls for
    (10: 115200 baud), and with every switch open (the bootloader's default divisor, 18)."""
    board = Board(dut)
    board.dip(DIVISOR)
    board.program_flash(b"")                             # erased: the bootloader sends 'W' on the UART
    await board.reset_button()
    t = await board.uart_bit_time()
    baud = 1e9 / t
    dut._log.info(f"divisor {DIVISOR}: {baud:.0f} baud")
    assert abs(baud / BAUD - 1) < 0.02, f"{baud:.0f} baud, not {BAUD}"
    board.dip(0)
    await board.reset_button()
    t = await board.uart_bit_time()
    baud = 1e9 / t
    dut._log.info(f"every switch open (divisor 18): {baud:.0f} baud")
    assert abs(baud / (CLK_MHZ * 1e6 / (16 * 18)) - 1) < 0.02, f"{baud:.0f} baud with the default divisor"


@cocotb.test()
async def boot_over_uart(dut):
    """GPIO5 closed skips a valid flash image: the program loads through the FT2232's UART."""
    board = Board(dut)
    program = build_file("hello.bin")
    await boot(dut, board, UART_BOOT | DIVISOR, flash_image(b"\x6f\x00\x00\x00"), ready="W")   # j .
    for byte in len(program).to_bytes(4, "little") + program:
        await board.uart_send(byte)
    assert await board.uart_recv() == sum(program) & 0xFF, "wrong checksum"
    assert bytes([await board.uart_recv() for _ in range(3)]) == b"OK\n"


@cocotb.test()
async def jtag_and_reset_line(dut):
    """The FT2232's JTAG pins reach the chip's Debug Module through the board: IDCODE, halt, a program
    written to the RAM and read back.  Then its reset line (ADBUS4, which J2 pin 10 also is) resets
    the chip, through the supervisor's MR."""
    from test_chip import DMCONTROL, RAM, Jtag

    board = Board(dut)
    await boot(dut, board, DIVISOR, b"", ready="W")
    jtag = Jtag(board)
    await jtag.reset()
    assert await jtag.scan(False, 0, 32) == 0x00000001, "IDCODE"
    await jtag.write(DMCONTROL, 1)
    await jtag.halt()
    words = [0x00000013, 0xDEADBEEF, 0x12345678, 0xA5A5A5A5]
    await jtag.sb_write(RAM, words)
    assert await jtag.sb_read(RAM, len(words)) == words, "RAM read back through JTAG"
    # the reset line: pull it low, release it, and the bootloader runs again
    board.ad = board.ad & ~0x10
    dut.u4.adbus_out.value = board.ad
    dut.u4.adbus_oe.value = 0x1B
    await Timer(2, unit="us")
    assert int(dut.RST_N.value) == 0, "the FT2232's reset line did not reset the chip"
    dut.u4.adbus_oe.value = 0x0B
    assert await board.uart_recv() == ord("W"), "the chip did not restart after the reset line"


@cocotb.test()
async def i2c_devices(dut):
    """i2c.S, from the board's flash, scans six addresses and talks to the TMP102, the 24LC256, the
    ADS1115 and the MCP4725 through GPIO6 and GPIO7: every device is where the schematic puts it."""
    board = Board(dut)
    await boot(dut, board, DIVISOR, flash_image(build_file("i2c.bin")))
    out = bytes([await board.uart_recv(timeout_ms=20) for _ in range(1 + 6 + 3 + 2 + 3 + 4 + 1)])
    dut._log.info(f"I2C program output: {out!r}")
    assert out[0:1] == b"S" and out[1:7] == b"111010", f"scan of 0x48 0x49 0x50 0x51 0x60 0x61: {out[1:7]!r}, not 111010"
    assert out[7:8] == b"T" and out[8:10] == b"\x19\x00", f"TMP102 temperature {out[8:10].hex()}, not 1900 (25 C)"
    assert out[10:11] == b"E" and out[11] == 0xA5, f"24LC256 read back {out[11]:02x}, not a5"
    assert out[12:13] == b"A" and out[13:15] == b"\x85\x83", f"ADS1115 configuration {out[13:15].hex()}, not 8583"
    assert out[15:16] == b"D" and out[16] & 0x80, f"MCP4725 status {out[16]:02x}"
    assert out[17:19] == b"\xab\xc0", f"MCP4725 DAC register {out[17:19].hex()}, not abc0"
    assert out[19:20] == b"Z"
    assert int(dut.u13.dac.value) == 0xABC, f"the DAC holds {int(dut.u13.dac.value):03x}"
    assert int(dut.u10.mem[0x123].value) == 0xA5, "the EEPROM did not store the byte"


@cocotb.test()
async def straps_buttons_leds(dut):
    """gpio.S, from the board's flash: the DIP switch and the six push buttons read back on GPIO0-5 (with
    the I2C pull-ups on GPIO6-7), and what the chip drives on GPIO[7:0] lights D3-D10."""
    board = Board(dut)
    await boot(dut, board, DIVISOR, flash_image(build_file("gpio.bin")), ready="F")
    assert await board.uart_recv() == ord("G")

    async def read():
        await board.uart_send(ord("R"))
        return await board.uart_recv()

    # the DIP switch: closed contacts read 1, open ones 0 (the 47k pull-downs); GPIO6-7 read 1
    for dip in (DIVISOR, 0x00, 0x3F, 0x15, 0x2A):
        board.dip(dip)
        await Timer(1, unit="us")
        got = await read()
        assert got == 0xC0 | dip, f"DIP 0x{dip:02x} reads 0x{got:02x} on GPIO[7:0], not 0x{0xC0 | dip:02x}"
    # each button pulls its own pin low
    board.dip(0x3F)
    for n, sw in enumerate(("sw3", "sw4", "sw5", "sw6", "sw7", "sw8")):
        getattr(dut, f"{sw}_pressed").value = 1
        await Timer(1, unit="us")
        got = await read()
        getattr(dut, f"{sw}_pressed").value = 0
        assert got == 0xFF & ~(1 << n), f"{sw} pressed reads 0x{got:02x}, not 0x{0xFF & ~(1 << n):02x} (GPIO{n} low)"
    # LEDs: what the chip drives on GPIO[7:0] lights D3-D10 through the 74AHC541, with the DIP open
    board.dip(0x00)
    for pattern in (0x55, 0xAA, 0xFF, 0x00, 0x81):
        await board.uart_send(ord("L"))
        await board.uart_send(pattern)
        assert await board.uart_recv() == ord("L")
        await Timer(1, unit="us")
        assert leds(dut) == pattern, f"GPIO[7:0] = 0x{pattern:02x} lights 0x{leds(dut):02x}"


###########################################################################################


def main():
    from cocotb_tools.check_results import get_results
    from cocotb_tools.runner import get_runner

    work = Path(os.environ.get("WORK", WALLY / "asic/librelane/work/asic_soc_rv32imac"))
    config = json.loads((work / "config.json").read_text())
    pdk = Path(os.environ.get("IHP_PDK", Path.home() / ".ciel/ciel/ihp-sg13/versions/"
                              "89d42ee6d2fd9b50b86a1aada6fee6673c3e6008/ihp-sg13g2"))
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    for prog in ("hello", "i2c", "gpio"):
        src = HERE / f"{prog}.S" if (HERE / f"{prog}.S").exists() else CHIPTEST / f"{prog}.S"
        subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imc_zicsr", "-mabi=ilp32", "-nostdlib",
                        "-Wl,-Ttext=0x80000000", "-o", build / f"{prog}.elf", src], check=True)
        subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / f"{prog}.elf", build / f"{prog}.bin"],
                       check=True)
    netlist = os.environ.get("BOARD_NETLIST", HERE.parent / "mcu_board.kicad_sch")   # a mutated netlist, to check the tests
    subprocess.run([sys.executable, HERE / "gen_board.py", netlist, build / "board.sv"],
                   check=True)

    lib = pdk.name.removeprefix("ihp-")
    sram = pdk / f"libs.ref/{lib}_sram/verilog"
    sources = config["VERILOG_FILES"] + [
        pdk / f"libs.ref/{lib}_io/verilog/{lib}_io.v",
        sram / "RM_IHPSG13_1P_core_behavioral_bm_bist.v",
        sram / "RM_IHPSG13_1P_1024x32_c2_bm_bist.v",
        sram / "RM_IHPSG13_1P_2048x32_c2_bm_bist.v",
        HERE / "models.sv",
        build / "board.sv",
    ]
    runner = get_runner("verilator")
    runner.build(sources=sources, includes=config["VERILOG_INCLUDE_DIRS"], hdl_toplevel="board",
                 build_dir=build / "sim", always=not os.environ.get("NOBUILD"), defines={d: 1 for d in config.get("VERILOG_DEFINES", [])},
                 build_args=["-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-SPECIFYIGN", "--timing", "-j", "8",
                             "--timescale", "1ns/1ps", str(WALLY / "asic/librelane/sram/getenvval.c")])
    results = runner.test(hdl_toplevel="board", test_module=os.environ.get("TEST_MODULE", "test_board"), test_dir=HERE, build_dir=build / "sim")
    tests, failed = get_results(results)
    sys.exit(failed > 0 or tests == 0)


if __name__ == "__main__":
    main()
