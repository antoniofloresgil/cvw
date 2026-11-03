# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""cocotb test of the asic_soc_rv32imc chip (RTL, with the IHP pad and SRAM models).

Loads hello.S through the bootloader over the UART and checks what it prints and drives.
Run with the Python of oss-cad-suite, after `make CONFIG=asic_soc_rv32imc inputs` (whose
work/asic_soc_rv32imc/config.json lists the sources):  tabbypy3 test_chip.py
`make chipsim` sets IHP_PDK (the process: .../ihp-sg13g2 or .../ihp-sg13cmos5l) and WORK.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

DIVISOR = 1                       # baud divisor strapped on GPIO[7:0]: one bit every 16 clocks
BIT = 16 * DIVISOR
HERE = Path(__file__).resolve().parent


async def uart_send(dut, byte):
    for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
        dut.uart_rx.value = bit
        await ClockCycles(dut.clk, BIT)


async def uart_recv(dut, timeout=200000):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.uart_tx.value == 0:
            break
    else:
        raise AssertionError("no UART start bit")
    await ClockCycles(dut.clk, BIT + BIT // 2)    # to the middle of bit 0
    byte = 0
    for i in range(8):
        byte |= int(dut.uart_tx.value) << i
        await ClockCycles(dut.clk, BIT)
    assert dut.uart_tx.value == 1, "missing stop bit"
    return byte


@cocotb.test()
async def boot_over_uart(dut):
    program = (HERE / "build/hello.bin").read_bytes()
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.uart_rx.value = 1
    dut.gpio_in.value = DIVISOR
    dut.gpio_drive.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1

    assert await uart_recv(dut) == ord("W"), "bootloader not ready"
    dut.gpio_drive.value = 0                       # the straps have been read; the program drives the pads
    for byte in len(program).to_bytes(4, "little") + program:
        await uart_send(dut, byte)
    assert await uart_recv(dut) == sum(program) & 0xFF, "wrong checksum"

    text = bytes([await uart_recv(dut) for _ in range(3)])
    assert text == b"OK\n", f"program printed {text!r}"
    for _ in range(1000):
        await FallingEdge(dut.clk)
        if dut.gpio_out.value.is_resolvable and int(dut.gpio_out.value) == 42:
            break
    else:
        raise AssertionError(f"GPIO reads {dut.gpio_out.value}, not 42")


def main():
    from cocotb_tools.check_results import get_results
    from cocotb_tools.runner import get_runner

    work = Path(os.environ.get("WORK", HERE.parents[1] / "work/asic_soc_rv32imc"))
    config = json.loads((work / "config.json").read_text())
    pdk = Path(os.environ.get("IHP_PDK", Path.home() / ".ciel/ciel/ihp-sg13/versions/"
                              "89d42ee6d2fd9b50b86a1aada6fee6673c3e6008/ihp-sg13g2"))
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imc_zicsr", "-mabi=ilp32", "-nostdlib",
                    "-Wl,-Ttext=0x80000000", "-o", build / "hello.elf", HERE / "hello.S"], check=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / "hello.elf", build / "hello.bin"], check=True)

    lib = pdk.name.removeprefix("ihp-")              # sg13g2 or sg13cmos5l
    sram = pdk / f"libs.ref/{lib}_sram/verilog"
    sources = config["VERILOG_FILES"] + [
        pdk / f"libs.ref/{lib}_io/verilog/{lib}_io.v",
        sram / "RM_IHPSG13_1P_core_behavioral_bm_bist.v",
        sram / "RM_IHPSG13_1P_1024x32_c2_bm_bist.v",
        HERE / "chip_tb.sv",
    ]
    runner = get_runner("verilator")
    runner.build(sources=sources, includes=config["VERILOG_INCLUDE_DIRS"], hdl_toplevel="chip_tb",
                 build_dir=build, always=True, defines={d: 1 for d in config.get("VERILOG_DEFINES", [])},
                 build_args=["-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-SPECIFYIGN", "--timing", "-j", "8",
                             str(HERE.parents[1] / "sram/getenvval.c")])
    results = runner.test(hdl_toplevel="chip_tb", test_module="test_chip", test_dir=HERE, build_dir=build)
    tests, failed = get_results(results)
    sys.exit(failed > 0 or tests == 0)


if __name__ == "__main__":
    main()
