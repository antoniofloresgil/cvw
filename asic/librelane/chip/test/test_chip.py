# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""cocotb test of the asic_soc_rv32imac chip (RTL, with the IHP pad and SRAM models).

boot_from_flash has the bootloader (../boot.S) copy hello.S from an SPI flash, which spi_flash
plays, and checks what the program prints and drives.  boot_over_uart loads it over the UART, with
GPIO[5] strapped to skip the flash, which holds a valid image.  debug_over_jtag, with an erased
flash, which the bootloader rejects, loads it through the JTAG port instead, as a debugger does: it
halts the hart, loads the program with System Bus Access, turns the instruction trace on, resumes
the hart at the program, then halts it again and reads the trace back, which etracedecode.py
($WALLY/testbench/debug/etrace) decodes into the program's path.
atomics runs atomics.S from the flash: the atomic memory operations and LR/SC on the RAM, and misa.A.
pmp runs pmp.S: the PMP CSRs, User mode against three regions, and a locked entry in Machine mode.
ram runs ram.S: the eight banks of the 64 KiB RAM, aliasing and byte and halfword stores.
freertos runs the FreeRTOS demo (../freertos): tasks, a queue, a mutex and a software timer on the CLINT tick.
zephyr_halt_idle halts Zephyr's sleeping idle thread through JTAG three times: the locked PMP entries of an RTOS must not
stop the Debug Module's ROM, and the demo must still answer after each resume.
mcu_peripherals boots mcu.S the same way and checks the timer, I2C, RTC and watchdog through the
pads: PWM duty cycles on GPIO0 and GPIO1, a capture of an edge the test puts on GPIO2, an I2C slave
(i2c_slave) on GPIO6 and GPIO7, the RTC alarm, and the reset the unserviced watchdog causes.
Run with the Python of oss-cad-suite, after `make CONFIG=asic_soc_rv32imac inputs` (whose
work/asic_soc_rv32imac/config.json lists the sources):  tabbypy3 test_chip.py
`make chipsim` sets IHP_PDK (the process: .../ihp-sg13g2 or .../ihp-sg13cmos5l) and WORK.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, First, RisingEdge, Timer

DIVISOR = 1                       # baud divisor strapped on GPIO[4:0]: one bit every 16 clocks
UART_BOOT = 0x20                  # GPIO[5]: skip the flash
BIT = 16 * DIVISOR
HERE = Path(__file__).resolve().parent
WALLY = Path(os.environ.get("WALLY", HERE.parents[3]))
sys.path.insert(0, str(WALLY / "testbench/debug/etrace"))


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


async def spi_flash(dut, data):
    """An SPI flash (mode 0, MSB first) that answers the Read command (0x03) with data, and 0xFF past it."""
    dut.spi_miso.value = 1
    sck_rise, cs_rise = RisingEdge(dut.spi_sck), RisingEdge(dut.spi_cs)
    while True:
        await FallingEdge(dut.spi_cs)
        command, nbits = 0, 0
        while True:
            if await First(sck_rise, cs_rise) is cs_rise:
                break
            if nbits < 32:                          # command and 3 address bytes, sampled on the rising edge
                command = (command << 1) | int(dut.spi_mosi.value)
            nbits += 1
            if nbits == 32:
                assert command >> 24 == 0x03, f"flash command 0x{command >> 24:02x}, not Read"
            await FallingEdge(dut.spi_sck)
            if nbits >= 32:                         # the next bit out, before the next rising edge
                k = nbits - 32
                i = (command & 0xFFFFFF) + k // 8
                dut.spi_miso.value = ((data[i] if i < len(data) else 0xFF) >> (7 - k % 8)) & 1
        dut.spi_miso.value = 1


def flash_image(program):
    """What the bootloader expects in the flash: magic, size and the program."""
    return b"WALY" + len(program).to_bytes(4, "little") + program


async def reset_chip(dut, straps=DIVISOR, flash=b"", ready="W"):
    """Clock, reset with the straps on the GPIOs and an SPI flash holding flash (erased if empty), and
    wait for the bootloader's first character."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.uart_rx.value = 1
    dut.gpio_in.value = straps
    dut.gpio_drive.value = 0xFF
    dut.tck.value, dut.tms.value, dut.tdi.value = 0, 1, 0
    dut.spi_miso.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    cocotb.start_soon(spi_flash(dut, flash))
    dut.rst_n.value = 1
    char = await uart_recv(dut, timeout=1000000 + 200 * len(flash))     # the copy from the flash takes time
    assert char == ord(ready), f"the bootloader sent {chr(char)!r}, not {ready!r}"
    dut.gpio_drive.value = 0                       # the straps have been read; the program drives the pads


async def check_program_output(dut):
    """hello.S prints OK and drives 42 on the GPIOs."""
    text = bytes([await uart_recv(dut) for _ in range(3)])
    assert text == b"OK\n", f"program printed {text!r}"
    for _ in range(1000):
        await FallingEdge(dut.clk)
        if dut.gpio_out.value.is_resolvable and int(dut.gpio_out.value) == 42:
            break
    else:
        raise AssertionError(f"GPIO reads {dut.gpio_out.value}, not 42")


@cocotb.test()
async def boot_from_flash(dut):
    program = (HERE / "build/hello.bin").read_bytes()
    await reset_chip(dut, flash=flash_image(program), ready="F")
    await check_program_output(dut)


@cocotb.test()
async def boot_over_uart(dut):
    program = (HERE / "build/hello.bin").read_bytes()
    await reset_chip(dut, straps=UART_BOOT | DIVISOR, flash=flash_image(b"\x6f\x00\x00\x00"))   # j .
    for byte in len(program).to_bytes(4, "little") + program:
        await uart_send(dut, byte)
    assert await uart_recv(dut) == sum(program) & 0xFF, "wrong checksum"
    await check_program_output(dut)


@cocotb.test()
async def atomics(dut):
    """The A extension (Zaamo and Zalrsc): atomics.S sends 'P' if every operation gave the right result."""
    program = (HERE / "build/atomics.bin").read_bytes()
    await reset_chip(dut, flash=flash_image(program), ready="F")
    result = await uart_recv(dut)
    assert result == ord("P"), f"atomics.S failed check {chr(result)!r}"


@cocotb.test()
async def pmp(dut):
    """PMP (16 entries): pmp.S checks the CSRs, User mode against regions with R+X, R+W, R and no entry,
    and a locked entry in Machine mode; it sends 'P' if every access was allowed or refused as it should."""
    program = (HERE / "build/pmp.bin").read_bytes()
    await reset_chip(dut, flash=flash_image(program), ready="F")
    result = await uart_recv(dut)
    assert result == ord("P"), f"pmp.S failed check {chr(result)!r}"


@cocotb.test()
async def ram(dut):
    """The 64 KiB RAM (eight 2048 x 32 macros): ram.S writes a different word to the first and last word of
    every 8 KiB bank, reads them back, and checks byte and halfword stores; it sends 'P' if all held."""
    program = (HERE / "build/ram.bin").read_bytes()
    await reset_chip(dut, flash=flash_image(program), ready="F")
    result = await uart_recv(dut)
    assert result == ord("P"), f"ram.S failed check {chr(result)!r}"


@cocotb.test()
async def freertos(dut):
    """FreeRTOS (../freertos): a producer, a consumer, a mutex on the UART, a software timer and a task that
    never blocks, all driven by the CLINT's tick; the demo prints its messages and "FREERTOS OK" if the tick,
    the queue, the timer and the stacks behaved, and the PMP refused a write to the code and a jump into the heap
    or a stack."""
    program = (HERE.parent / "freertos/build/freertos.bin").read_bytes()
    await reset_chip(dut, flash=flash_image(program), ready="F")
    lines, line = [], b""
    while not lines or not lines[-1].startswith(b"FREERTOS"):
        try:
            byte = await uart_recv(dut, timeout=400000)
        except AssertionError as e:
            state = ""
            try:                                       # halt the hart through JTAG and say where it is
                jtag = Jtag(dut)
                await jtag.reset()
                await jtag.write(DMCONTROL, 1)
                await jtag.halt()
                for name, regno in (("dpc", 0x7B1), ("mcause", 0x342), ("mepc", 0x341), ("mtval", 0x343),
                                    ("mstatus", 0x300), ("mie", 0x304), ("mip", 0x344), ("mtvec", 0x305)):
                    state += f" {name}=0x{await jtag.read_csr(regno):x}"
            except AssertionError as e2:
                state = f" (JTAG: {e2})"
            raise AssertionError(f"{e} after {lines!r} and {line!r};{state}") from None
        if byte == ord("\n"):
            lines.append(line)
            line = b""
        else:
            line += bytes([byte])
    assert lines[0].startswith(b"FreeRTOS V"), f"first line {lines[0]!r}"
    assert lines[1:] == [b"rx %d" % n for n in range(1, 6)] + [
        b"prot store data 0", b"prot store code 7", b"prot exec heap 1", b"prot exec stack 1", b"FREERTOS OK"], f"the demo printed {lines!r}"


async def read_lines(dut, last, timeout=400000):
    """The lines the program prints on the UART, up to the first one that starts with last."""
    lines, line = [], b""
    while not lines or not lines[-1].startswith(last):
        try:
            byte = await uart_recv(dut, timeout=timeout)
        except AssertionError as e:
            raise AssertionError(f"{e} after {lines!r} and {line!r}, waiting for {last!r}") from None
        if byte == ord("\n"):
            lines.append(line)
            line = b""
        elif byte != ord("\r"):                      # Zephyr's console sends \r\n
            line += bytes([byte])
    return lines


@cocotb.test()
async def zephyr(dut):
    """Zephyr in User mode (../zephyr): the kernel in Machine mode, threads in User mode isolated by the PMP.
    Threads A and B, each in a memory domain of its own, keep their data while the kernel switches between
    them; then one user thread per case does what it must not (a store or load outside its domain, a store to
    kernel code or the UART, a jump into data, a load from the RAM's trace area, a system call on a kernel
    object it has no permission for), and each ends with the exception cause the PMP must raise, which
    Zephyr's fatal error handler records before aborting only that thread (see app/main.c)."""
    image = HERE.parent / "zephyr/build-sim/zephyr/zephyr.bin"    # `make chipsim` builds it (Python venv of Zephyr)
    assert image.exists(), f"{image} is missing: make -C {image.parents[3]} BUILD=build-sim OVERLAY=sim.overlay"
    await reset_chip(dut, flash=flash_image(image.read_bytes()), ready="F")
    lines = await read_lines(dut, b"ZEPHYR ", timeout=2000000)
    dump = re.compile(rb"( *[a-z0-9]+: [0-9a-f]+.*| *mcause: .*|call trace:|>>> .*|Current thread: .*)?")
    lines = [l for l in lines if not dump.fullmatch(l)]        # the register dump Zephyr prints at each fault
    assert lines[0] == b"Zephyr PMP demo", f"first line {lines[0]!r}"
    threads = lines[1:7]
    assert [l for l in threads if l.startswith(b"A ")] == [b"A %d" % (100 + i) for i in (1, 2, 3)], f"{lines!r}"
    assert [l for l in threads if l.startswith(b"B ")] == [b"B %d" % (200 + i) for i in (1, 2, 3)], f"{lines!r}"
    # the K_ERR reason (0: CPU exception, 3: kernel oops) and mcause (7 store, 5 load, 1 instruction access fault, 8 ecall)
    assert lines[7:] == [b"isolation ok", b"own data 0 0", b"store domain B 0 7", b"load domain B 0 5",
                         b"store kernel data 0 7", b"store kernel code 0 7", b"store UART 0 7", b"exec own data 0 1",
                         b"load trace area 0 5", b"syscall no permission 3 8", b"ZEPHYR OK"], f"Zephyr printed {lines!r}"


@cocotb.test()
async def zephyr_peripherals(dut):
    """Zephyr's drivers for the chip's peripherals (../zephyr/periph): the console UART in interrupt mode, the GPIO,
    the SPI and the PWM.  The demo prints a line per step and the test plays the other side on the pads: it sends
    three letters on the UART and gets them back in capitals, drives GPIO4 and sees GPIO5 follow it, serves the
    flash's first bytes ("WALY") to an SPI read, and measures the duty cycles of the PWM on GPIO1 and GPIO2 (high for period - pulse, as the FU540's PWM)."""
    image = HERE.parent / "zephyr/build-periph-sim/zephyr/zephyr.bin"    # `make chipsim` builds it
    assert image.exists(), f"{image} is missing: make -C {image.parents[3]} APP=periph BUILD=build-periph-sim OVERLAY=sim.overlay"
    await reset_chip(dut, flash=flash_image(image.read_bytes()), ready="F")
    await RisingEdge(dut.clk)                         # reset_chip's release of the straps takes effect
    lines = await read_lines(dut, b"uart ready", timeout=2000000)
    assert lines == [b"periph start", b"uart ready"], f"{lines!r}"
    for c in b"abc":
        await uart_send(dut, c)
    lines = await read_lines(dut, b"gpio ready", timeout=12000000)
    assert lines == [b"ABC", b"gpio ready"], f"UART interrupt mode: {lines!r}"
    pad_drive(dut, 4, 1)                              # the demo reads GPIO4 after 50 ms and copies it to GPIO5
    lines = await read_lines(dut, b"gpio in", timeout=2000000)
    assert lines == [b"gpio in 1"], f"{lines!r}"
    for _ in range(10):
        await FallingEdge(dut.clk)
    pads = int(dut.gpio_out.value)
    assert (pads >> 5) & 1 == 1 and pads & 1 == 1, f"GPIO pads 0x{pads:02x}: GPIO5 and GPIO0 should be high"
    lines = await read_lines(dut, b"spi", timeout=2000000)
    assert lines == [b"spi WALY"], f"SPI read of the flash: {lines!r}"
    lines = await read_lines(dut, b"pwm set", timeout=2000000)
    assert len(lines) == 2 and lines[1] == b"pwm set", f"{lines!r}"
    dut._log.info(lines[0].decode())
    highs = [0, 0]
    for _ in range(2000):                             # pulses of 25 % and 75 %: the pads are high for the rest of the period
        await FallingEdge(dut.clk)
        pads = int(dut.gpio_out.value)
        highs[0] += (pads >> 1) & 1
        highs[1] += (pads >> 2) & 1
    assert 1400 <= highs[0] <= 1600, f"GPIO1 was high {highs[0]} of 2000 clocks, not about 1500"
    assert 400 <= highs[1] <= 600, f"GPIO2 was high {highs[1]} of 2000 clocks, not about 500"
    lines = await read_lines(dut, b"PERIPH ", timeout=4000000)
    assert lines == [b"PERIPH OK"], f"{lines!r}"


@cocotb.test()
async def zephyr_uart_irq(dut):
    """Zephyr's console UART with an interrupt-driven receiver (../zephyr/uart_irq): the host sends three letters,
    the PLIC raises the UART's source and the demo echoes them in capitals.  If the hart stops answering, the test
    reads the PLIC and the UART over System Bus Access, which does not need the hart."""
    image = HERE.parent / "zephyr/build-uart-irq-sim/zephyr/zephyr.bin"    # `make chipsim` builds it
    assert image.exists(), f"{image} is missing: make -C {image.parents[3]} APP=uart_irq BUILD=build-uart-irq-sim OVERLAY=sim.overlay"
    await reset_chip(dut, flash=flash_image(image.read_bytes()), ready="F")
    await RisingEdge(dut.clk)
    lines = await read_lines(dut, b"uart ready", timeout=2000000)
    assert lines == [b"uart irq start", b"uart ready"], f"{lines!r}"
    for c in b"abc":
        await uart_send(dut, c)
    try:
        lines = await read_lines(dut, b"UART ", timeout=4000000)
    except AssertionError as e:
        state = ""
        jtag = Jtag(dut)
        await jtag.reset()
        await jtag.write(DMCONTROL, 1)

        async def peek(name, addr):
            try:
                return f" {name}=0x{(await jtag.sb_read(addr))[0]:x}"
            except AssertionError:
                await jtag.write(SBCS, 7 << 12)              # clear the sticky error
                return f" {name}=ERR"
        async def peek8(name, addr):                         # a byte access, for the UART's 8-bit registers
            try:
                await jtag.write(SBCS, (1 << 20) | (0 << 17) | (1 << 15))
                await jtag.write(SBADDRESS0, addr)
                value = await jtag.read(SBDATA0)
                assert (await jtag.read(SBCS) >> 12) & 7 == 0
                return f" {name}=0x{value & 0xFF:02x}"
            except AssertionError:
                await jtag.write(SBCS, 7 << 12)
                return f" {name}=ERR"
        for name, addr in (("uart_ier", 0x10000001), ("uart_iir", 0x10000002), ("uart_lcr", 0x10000003),
                           ("uart_mcr", 0x10000004), ("uart_lsr", 0x10000005)):
            state += await peek8(name, addr)
        symbols = {}                                         # the demo's variables, from the ELF
        for line in subprocess.run(["riscv64-unknown-elf-nm", image.parent / "zephyr.elf"], capture_output=True,
                                   text=True, check=True).stdout.splitlines():
            fields = line.split()
            if len(fields) == 3:                             # not the undefined symbols, which have no address
                symbols[fields[2]] = int(fields[0], 16)
        for name in ("rx_n", "rx_buf"):
            state += await peek(name, symbols[name])
        for name, n in (("rx_sem", 4), ("_kernel", 8)):         # raw words: the semaphore, the scheduler's state
            words = await jtag.sb_read(symbols[name], n)
            state += f" {name}=[" + " ".join(f"{w:x}" for w in words) + "]"
        state += f" main_thread=0x{symbols['z_main_thread']:x} idle_thread=0x{symbols['z_idle_threads']:x}"
        plic = 0x0C000000
        for name, addr in (("mtime", 0x0200BFF8), ("plic_prio10", plic + 40),
                           ("plic_pending", plic + 0x1000), ("plic_enable", plic + 0x2000),
                           ("plic_threshold", plic + 0x200000), ("ram0", 0x80000000)):
            state += await peek(name, addr)
        raise AssertionError(f"{e};{state}") from None
    assert lines == [b"ABC", b"UART IRQ OK"], f"{lines!r}"


@cocotb.test()
async def zephyr_halt_idle(dut):
    """A halt request reaches a hart that sleeps in Zephyr's idle thread (a wfi, with the timer and UART interrupts
    enabled): the debugger halts it, reads where it is, resumes it, and the echo demo of ../zephyr/uart_irq still
    answers, so the wfi was neither skipped nor left stuck."""
    image = HERE.parent / "zephyr/build-uart-irq-sim/zephyr/zephyr.bin"    # `make chipsim` builds it
    assert image.exists(), f"{image} is missing: make -C {image.parents[3]} APP=uart_irq BUILD=build-uart-irq-sim OVERLAY=sim.overlay"
    await reset_chip(dut, flash=flash_image(image.read_bytes()), ready="F")
    await RisingEdge(dut.clk)
    lines = await read_lines(dut, b"uart ready", timeout=2000000)
    assert lines == [b"uart irq start", b"uart ready"], f"{lines!r}"
    await ClockCycles(dut.clk, 50000)                  # the hart sleeps in the idle thread
    jtag = Jtag(dut)
    await jtag.reset()
    await jtag.write(DMCONTROL, 1)                     # dmactive
    for n in range(3):                                 # halt and resume the sleeping hart several times
        await jtag.halt(polls=300)
        dcsr, dpc = await jtag.read_csr(0x7B0), await jtag.read_csr(0x7B1)
        assert (dcsr >> 6) & 7 == 3, f"halt {n}: dcsr 0x{dcsr:x} (cause must be 3, a halt request), dpc 0x{dpc:x}"
        await jtag.resume()
        await ClockCycles(dut.clk, 20000)
    for c in b"abc":
        await uart_send(dut, c)
    lines = await read_lines(dut, b"UART ", timeout=4000000)
    assert lines == [b"ABC", b"UART IRQ OK"], f"{lines!r}"


@cocotb.test()
async def zephyr_mcu(dut):
    """Zephyr's drivers for the I2C master and the watchdog (../zephyr/mcu): the demo writes 0x5A to an I2C device
    at 0x50 (played on the pads by i2c_slave), reads 0xC3 back, gets a NACK from 0x51, then arms the watchdog, feeds it
    three times and stops: its second timeout resets the chip and the bootloader sends 'F' again."""
    image = HERE.parent / "zephyr/build-mcu-sim/zephyr/zephyr.bin"    # `make chipsim` builds it
    assert image.exists(), f"{image} is missing: make -C {image.parents[3]} APP=mcu BUILD=build-mcu-sim OVERLAY=sim.overlay"
    await reset_chip(dut, flash=flash_image(image.read_bytes()), ready="F")
    await RisingEdge(dut.clk)
    received = []
    cocotb.start_soon(i2c_slave(dut, received))
    lines = await read_lines(dut, b"i2c nack", timeout=4000000)
    assert lines == [b"mcu start", b"i2c write ok", b"i2c read c3", b"i2c nack -5"], f"{lines!r}"
    assert received == [0x5A], f"the I2C slave received {received}"
    lines = await read_lines(dut, b"wdt fed", timeout=4000000)
    assert lines == [b"wdt fed"], f"{lines!r}"
    dut.gpio_in.value = DIVISOR                        # the bootloader reads its straps again after the reset
    dut.gpio_drive.value = 0xFF
    char = await uart_recv(dut, timeout=8000000)
    assert char == ord("F"), f"after the watchdog's reset the bootloader sent {chr(char)!r}, not 'F'"


@cocotb.test()
async def zephyr_timer(dut):
    """Zephyr's drivers for the MCU timer (Counter API with capture, PWM API) and the RTC (../zephyr/timer): the
    demo checks the top value and its callback, relative, absolute, cancelled and late alarms, then captures edges that
    this test drives into GPIO2 (rising edges 6000 clocks apart, then a rising and a falling edge 4000 apart: the capture
    register is read in the interrupt, so edges closer than its latency of several hundred clocks overwrite each other), sets two
    PWM outputs whose duty cycles this test measures on GPIO0 and GPIO1, and sets the RTC and an alarm that wakes the
    idle thread (the RTC runs 1000 times faster in this image, see sim.overlay)."""
    image = HERE.parent / "zephyr/build-timer-sim/zephyr/zephyr.bin"      # `make chipsim` builds it
    assert image.exists(), f"{image} is missing: make -C {image.parents[3]} APP=timer BUILD=build-timer-sim OVERLAY=sim.overlay"
    await reset_chip(dut, flash=flash_image(image.read_bytes()), ready="F")
    await RisingEdge(dut.clk)
    pad_drive(dut, 2, 0)                               # channel 2 captures on GPIO2: hold it low first

    async def edges(steps):
        for wait, value in steps:
            await ClockCycles(dut.clk, wait)
            pad_drive(dut, 2, value)

    lines = await read_lines(dut, b"capture ready", timeout=6000000)
    assert len(lines) == 10 and lines[0] == b"timer start", f"{lines!r}"
    assert lines[1] == b"count ok" and lines[2] == b"freq 18432000", f"{lines!r}"
    assert lines[3] in (b"top ok 3", b"top ok 4"), f"{lines!r}"
    assert lines[4:9] == [b"alarm relative ok", b"alarm absolute ok", b"alarm cancel ok", b"alarm late etime",
                          b"alarm expire ok"], f"{lines!r}"
    await edges([(1, 1), (2000, 0), (4000, 1), (2000, 0), (4000, 1), (2000, 0)])
    lines = await read_lines(dut, b"capture ready", timeout=4000000)
    assert lines == [b"capture rising 6000 6000", b"capture ready"], f"{lines!r}"
    await edges([(1, 1), (4000, 0), (6000, 1), (2000, 0)])
    lines = await read_lines(dut, b"pwm on", timeout=4000000)
    assert lines == [b"capture both 4000 6000", b"pwm on"], f"{lines!r}"
    highs = [0, 0]
    for _ in range(10000):                             # ten periods of 1000 clocks
        await FallingEdge(dut.clk)
        pads = int(dut.gpio_out.value)
        highs[0] += pads & 1
        highs[1] += (pads >> 1) & 1
    assert 2400 <= highs[0] <= 2600, f"GPIO0 was high {highs[0]} of 10000 clocks, not about 2500"
    assert 7400 <= highs[1] <= 7600, f"GPIO1 was high {highs[1]} of 10000 clocks, not about 7500"
    lines = await read_lines(dut, b"TIMER ", timeout=6000000)
    assert lines[:3] == [b"pwm period busy", b"pwm channel invalid", b"pwm alarm busy"], f"{lines!r}"
    assert lines[3] == b"rtc 2026-11-09 12:00:00 wday 1 yday 312", f"{lines!r}"
    assert lines[4] == b"rtc advanced ok", f"{lines!r}"
    assert re.fullmatch(rb"rtc alarm ok at 12:00:\d\d", lines[5]), f"{lines!r}"
    assert lines[6:] == [b"rtc pending 0", b"rtc past refused", b"rtc mask refused", b"TIMER OK"], f"{lines!r}"


###########################################################################################
# MCU peripherals: mcu.S drives them through GPIO alternate function 1
###########################################################################################

I2C_ADDR, I2C_REPLY = 0x50, 0xC3  # the slave's address, and the byte it returns on a read
SCL, SDA = 6, 7                   # GPIO pads of I2C


def pad_drive(dut, pad, value):
    """Drive pad (0 or 1), as an external device does; pad_release lets the pull-up have it."""
    dut.gpio_in.value = (int(dut.gpio_in.value) & ~(1 << pad)) | (value << pad)
    dut.gpio_drive.value = int(dut.gpio_drive.value) | (1 << pad)


def pad_release(dut, pad):
    dut.gpio_drive.value = int(dut.gpio_drive.value) & ~(1 << pad)


async def i2c_slave(dut, received):
    """A slave at I2C_ADDR on the pads of the chip's I2C master: it acknowledges its address and the
    bytes written to it (appended to received) and answers reads with I2C_REPLY.  Everything is seen
    on the pads: SDA is pulled low by the master or by the slave, and pulled up otherwise."""
    pscl = psda = 1
    phase, rise, sh, rw = "idle", 0, 0, 0
    while True:
        await FallingEdge(dut.clk)
        pads = dut.gpio_out.value
        if not pads.is_resolvable:
            continue
        scl, sda = (int(pads) >> SCL) & 1, (int(pads) >> SDA) & 1
        if scl and psda and not sda:                  # START
            phase, rise, sh = "addr", 0, 0
            pad_release(dut, SDA)
        elif scl and not psda and sda:                # STOP
            phase = "idle"
            pad_release(dut, SDA)
        elif scl and not pscl:                        # SCL rises: sample
            rise += 1
            if phase in ("addr", "wdata") and rise <= 8:
                sh = (sh << 1) | sda
        elif not scl and pscl:                        # SCL falls: the slave's next move
            if phase == "addr":
                if rise == 8:
                    if sh >> 1 == I2C_ADDR:
                        rw = sh & 1
                        pad_drive(dut, SDA, 0)        # acknowledge
                    else:
                        phase = "idle"
                elif rise == 9:
                    phase, rise, sh = ("rdata" if rw else "wdata"), 0, 0
                    pad_release(dut, SDA)
                    if rw:
                        pad_drive(dut, SDA, (I2C_REPLY >> 7) & 1)
            elif phase == "wdata":
                if rise == 8:
                    received.append(sh)
                    pad_drive(dut, SDA, 0)            # acknowledge
                elif rise == 9:
                    rise, sh = 0, 0
                    pad_release(dut, SDA)
            elif phase == "rdata":
                if 1 <= rise < 8:
                    pad_drive(dut, SDA, (I2C_REPLY >> (7 - rise)) & 1)
                elif rise == 8:
                    pad_release(dut, SDA)             # the master's acknowledge
        pscl, psda = scl, sda


@cocotb.test()
async def mcu_peripherals(dut):
    program = (HERE / "build/mcu.bin").read_bytes()
    image = flash_image(program)
    await reset_chip(dut, flash=image, ready="F")
    received = []
    await RisingEdge(dut.clk)                         # reset_chip's release of the straps takes effect
    pad_drive(dut, 2, 0)                              # channel 2 captures a rising edge on GPIO2: hold it low first
    cocotb.start_soon(i2c_slave(dut, received))

    assert await uart_recv(dut) == ord("T"), "the timer did not start"
    highs = [0, 0]
    for _ in range(1000):                             # PWM: 25 % and 75 % duty on GPIO0 and GPIO1
        await FallingEdge(dut.clk)
        pads = int(dut.gpio_out.value)
        highs[0] += pads & 1
        highs[1] += (pads >> 1) & 1
    assert 200 <= highs[0] <= 300, f"GPIO0 was high {highs[0]} of 1000 clocks, not about 250"
    assert 700 <= highs[1] <= 800, f"GPIO1 was high {highs[1]} of 1000 clocks, not about 750"
    pad_drive(dut, 2, 1)
    assert await uart_recv(dut) == ord("C"), "the edge on GPIO2 was not captured"
    assert await uart_recv(dut, timeout=400000) == ord("I"), "the I2C slave did not acknowledge"
    assert received == [0x5A], f"the I2C slave received {received}"
    assert await uart_recv(dut, timeout=400000) == ord("R"), "the I2C read returned the wrong byte"
    assert await uart_recv(dut, timeout=400000) == ord("A"), "the RTC alarm did not fire"
    assert await uart_recv(dut) == ord("D")

    # the watchdog is not kicked: its second timeout resets the chip, and the bootloader runs again
    dut.gpio_in.value = DIVISOR
    dut.gpio_drive.value = 0xFF
    char = await uart_recv(dut, timeout=1000000)
    assert char == ord("F"), f"after the watchdog's reset the bootloader sent {chr(char)!r}, not 'F'"


###########################################################################################
# JTAG and the Debug Module (RISC-V Debug Specification 1.0; docs/debug.md)
###########################################################################################

TCK_HALF = 50                     # ns: TCK at 10 MHz, asynchronous to the 100 MHz system clock
DMCONTROL, DMSTATUS, ABSTRACTCS, COMMAND, DATA0 = 0x10, 0x11, 0x16, 0x17, 0x04
SBCS, SBADDRESS0, SBDATA0 = 0x38, 0x39, 0x3C
RAM = 0x80000000
TRACE_TE, TRACE_RAM = 0x04000000, 0x04001000    # hart 0's trace encoder and RAM sink (docs/trace.md)


class Jtag:
    """A JTAG debugger on the chip's pads: TAP moves, IR and DR scans, DMI and System Bus Access."""

    def __init__(self, dut):
        self.dut = dut

    async def clock(self, tms, tdi=0):
        """One TCK cycle; returns TDO, which the TAP changes on the falling edge, before the rising edge."""
        self.dut.tms.value, self.dut.tdi.value = tms, tdi
        await Timer(TCK_HALF, unit="ns")
        tdo = int(self.dut.tdo.value)
        self.dut.tck.value = 1
        await Timer(TCK_HALF, unit="ns")
        self.dut.tck.value = 0
        return tdo

    async def reset(self):
        for _ in range(6):                          # Test-Logic-Reset, then Run-Test/Idle
            await self.clock(1)
        await self.clock(0)

    async def scan(self, ir, value, n):
        """From Run-Test/Idle: an IR scan (ir True) or DR scan of n bits, back to Run-Test/Idle."""
        for tms in ((1, 1, 0, 0) if ir else (1, 0, 0)):
            await self.clock(tms)
        out = 0
        for i in range(n):
            out |= await self.clock(1 if i == n - 1 else 0, (value >> i) & 1) << i
        await self.clock(1)                         # Update
        await self.clock(0)                         # Run-Test/Idle
        return out

    async def idle(self, n=8):
        for _ in range(n):
            await self.clock(0)

    async def dmi(self, addr, data=0, write=False):
        """A DMI access (abits 7): the request, then a nop scan that returns its result."""
        await self.scan(True, 0x11, 5)
        await self.scan(False, (addr << 34) | (data << 2) | (2 if write else 1), 41)
        await self.idle()
        result = await self.scan(False, 0, 41)
        assert result & 3 == 0, f"DMI {'write' if write else 'read'} of 0x{addr:x} returned op {result & 3}"
        return (result >> 2) & 0xFFFFFFFF

    async def read(self, addr):
        return await self.dmi(addr)

    async def write(self, addr, data):
        await self.dmi(addr, data, True)

    async def sb_write(self, addr, words):
        await self.write(SBCS, (2 << 17) | (1 << 16))                    # 32 bits, autoincrement
        await self.write(SBADDRESS0, addr)
        for w in words:
            await self.write(SBDATA0, w)
        assert (await self.read(SBCS) >> 12) & 7 == 0, "System Bus Access error"

    async def sb_read(self, addr, n=1):
        await self.write(SBCS, (1 << 20) | (2 << 17) | (1 << 16) | (1 << 15))   # read on address and data
        await self.write(SBADDRESS0, addr)
        words = [await self.read(SBDATA0) for _ in range(n)]
        assert (await self.read(SBCS) >> 12) & 7 == 0, "System Bus Access error"
        return words

    async def halt(self, polls=20):
        await self.write(DMCONTROL, (1 << 31) | 1)
        for _ in range(polls):
            if await self.read(DMSTATUS) & (1 << 9):                      # allhalted
                await self.write(DMCONTROL, 1)
                return
        raise AssertionError("the hart did not halt")

    async def write_csr(self, regno, value):
        await self.write(DATA0, value)
        await self.write(COMMAND, (2 << 20) | (1 << 17) | (1 << 16) | regno)   # 32 bits, transfer, write
        cs = await self.read(ABSTRACTCS)
        assert (cs >> 8) & 7 == 0 and not cs & (1 << 12), f"abstract command failed: abstractcs 0x{cs:x}"

    async def read_csr(self, regno):
        await self.write(COMMAND, (2 << 20) | (1 << 17) | regno)         # 32 bits, transfer, read
        cs = await self.read(ABSTRACTCS)
        assert (cs >> 8) & 7 == 0 and not cs & (1 << 12), f"abstract command failed: abstractcs 0x{cs:x}"
        return await self.read(DATA0)

    async def resume(self):
        await self.write(DMCONTROL, (1 << 30) | 1)
        for _ in range(20):
            if await self.read(DMSTATUS) & (1 << 17):                     # allresumeack
                await self.write(DMCONTROL, 1)
                return
        raise AssertionError("the hart did not resume")


@cocotb.test()
async def debug_over_jtag(dut):
    from etracedecode import decode, read_program

    program = (HERE / "build/hello.bin").read_bytes()
    await reset_chip(dut)
    jtag = Jtag(dut)
    await jtag.reset()
    assert await jtag.scan(False, 0, 32) == 0x00000001, "IDCODE"
    await jtag.scan(True, 0x10, 5)
    dtmcs = await jtag.scan(False, 0, 32)
    assert dtmcs & 0xF == 1 and (dtmcs >> 4) & 0x3F == 7, f"dtmcs 0x{dtmcs:x}: version 1, abits 7"

    # Halt the bootloader, load the program with System Bus Access and read it back
    await jtag.write(DMCONTROL, 1)                                        # dmactive
    await jtag.halt()
    words = [int.from_bytes(program[i:i + 4].ljust(4, b"\0"), "little") for i in range(0, len(program), 4)]
    await jtag.sb_write(RAM, words)
    assert await jtag.sb_read(RAM, len(words)) == words, "program read back"

    # Trace on, as the Trace Control Interface orders it: the RAM sink, then the encoder
    await jtag.sb_write(TRACE_RAM, [1])                                   # trRamActive
    await jtag.sb_write(TRACE_RAM + 0x20, [0])                            # trRamWPLow
    await jtag.sb_write(TRACE_RAM, [3])                                   # trRamEnable
    await jtag.sb_write(TRACE_TE, [1])                                    # trTeActive
    await jtag.sb_write(TRACE_TE, [0x00010037])                          # trace on: baseline, sync by packets

    # Run the program from its start
    await jtag.write_csr(0x7B1, RAM)                                      # dpc
    output = cocotb.start_soon(check_program_output(dut))                 # it prints while resume polls
    await jtag.resume()
    await output

    # Halt it in its last loop, turn the trace off and read it back
    await jtag.halt()
    await jtag.sb_write(TRACE_TE, [0x00010031])                          # trTeEnable 0: flush
    for _ in range(20):
        if (await jtag.sb_read(TRACE_TE))[0] & 8:                         # trTeEmpty
            break
    else:
        raise AssertionError("the trace encoder did not empty")
    await jtag.sb_write(TRACE_RAM, [1])                                   # trRamEnable 0
    for _ in range(20):
        if (await jtag.sb_read(TRACE_RAM))[0] & 8:                        # trRamEmpty
            break
    else:
        raise AssertionError("the RAM sink did not empty")
    te = (await jtag.sb_read(TRACE_TE))[0]
    assert not te & (1 << 12), "trTeInstStallOrOverflow: a packet was dropped"
    wp = (await jtag.sb_read(TRACE_RAM + 0x20))[0]
    assert not wp & 1 and 0 < wp <= 0x2000, f"trRamWPLow 0x{wp:x}"
    await jtag.sb_write(TRACE_RAM + 0x28, [0])                            # trRamRPLow
    await jtag.write(SBCS, (1 << 20) | (2 << 17) | (1 << 15))             # read on address and data, no increment
    await jtag.write(SBADDRESS0, TRACE_RAM + 0x40)                        # trRamData
    trace = b"".join([(await jtag.read(SBDATA0)).to_bytes(4, "little") for _ in range(wp // 4)])
    assert trace[:2] == b"\x41\x1f", f"the trace starts with {trace[:2].hex()}, not a support packet"
    elf = read_program(HERE / "build/hello.elf", 32)
    pcs = decode(trace, elf, 32)
    dut._log.info(f"trace: {wp} bytes, {len(pcs)} instructions from 0x{pcs[0]:x} to 0x{pcs[-1]:x}")
    assert pcs[0] == RAM, f"the trace starts at 0x{pcs[0]:x}, not at the program"
    loop = [a for a, i in elf.items() if i.kind == "jal" and i.imm == 0]     # 1: j 1b
    assert pcs[-1] in loop, f"the trace ends at 0x{pcs[-1]:x}, not in the last loop {[hex(a) for a in loop]}"


def main():
    from cocotb_tools.check_results import get_results
    from cocotb_tools.runner import get_runner

    work = Path(os.environ.get("WORK", HERE.parents[1] / "work/asic_soc_rv32imac"))
    config = json.loads((work / "config.json").read_text())
    pdk = Path(os.environ.get("IHP_PDK", Path.home() / ".ciel/ciel/ihp-sg13/versions/"
                              "89d42ee6d2fd9b50b86a1aada6fee6673c3e6008/ihp-sg13g2"))
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imc_zicsr", "-mabi=ilp32", "-nostdlib",
                    "-Wl,-Ttext=0x80000000", "-o", build / "hello.elf", HERE / "hello.S"], check=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / "hello.elf", build / "hello.bin"], check=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imc_zicsr", "-mabi=ilp32", "-nostdlib",
                    "-Wl,-Ttext=0x80000000", "-o", build / "mcu.elf", HERE / "mcu.S"], check=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imac_zicsr", "-mabi=ilp32", "-nostdlib",
                    "-Wl,-Ttext=0x80000000", "-o", build / "atomics.elf", HERE / "atomics.S"], check=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / "atomics.elf", build / "atomics.bin"], check=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imc_zicsr", "-mabi=ilp32", "-nostdlib",
                    "-Wl,-Ttext=0x80000000", "-o", build / "ram.elf", HERE / "ram.S"], check=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / "ram.elf", build / "ram.bin"], check=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imc_zicsr", "-mabi=ilp32", "-nostdlib",
                    "-Wl,-Ttext=0x80000000", "-o", build / "pmp.elf", HERE / "pmp.S"], check=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / "pmp.elf", build / "pmp.bin"], check=True)
    subprocess.run(["make", "-C", HERE.parent / "freertos"], check=True)     # needs addins/FreeRTOS-Kernel
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", build / "mcu.elf", build / "mcu.bin"], check=True)

    lib = pdk.name.removeprefix("ihp-")              # sg13g2 or sg13cmos5l
    sram = pdk / f"libs.ref/{lib}_sram/verilog"
    sources = config["VERILOG_FILES"] + [
        pdk / f"libs.ref/{lib}_io/verilog/{lib}_io.v",
        sram / "RM_IHPSG13_1P_core_behavioral_bm_bist.v",
        sram / "RM_IHPSG13_1P_1024x32_c2_bm_bist.v",
        sram / "RM_IHPSG13_1P_2048x32_c2_bm_bist.v",
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
