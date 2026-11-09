#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Loads a program into the chip through its UART bootloader (boot.S), then shows the program's console.

    uart_load.py /dev/ttyUSB1 zephyr/build/zephyr/zephyr.bin

The bootloader sends 'W' after a reset when GPIO[5] reads 1 (the chip's strap; on the FPGA, SW5 up), or when the SPI flash has no
valid image; the host sends the size (4 bytes, little endian) and the program, and the bootloader answers with the 8-bit sum of
the bytes and runs the program.  Reset the chip (the CPU RESET button of the FPGA board) after this script has started.
The bootloader's baud rate is f_clk / (16 * divisor), the divisor being what GPIO[4:0] read at reset (10 if 0): on the
FPGA build, with its 18.4375 MHz, SW[4:0] = 01000 is divisor 8, 144043 baud, which --boot-baud 144043 matches; the program
then runs at its own rate (--baud, 115200).  Standard library only (termios; any baud rate needs Linux).  Ctrl-C ends the console.
"""

import argparse
import fcntl
import os
import select
import struct
import sys
import termios
import time

MAX_SIZE = 64 * 1024


TCGETS2, TCSETS2, BOTHER, CBAUD = 0x802C542A, 0x402C542B, 0o010000, 0o010017    # Linux, struct termios2


def set_baud(fd, baud):
    """Any speed, as the UART bootloader's divisor needs (f_clk / (16 * divisor)): Linux only, through termios2."""
    name = f"B{baud}"
    if hasattr(termios, name):
        attrs = termios.tcgetattr(fd)
        attrs[4] = attrs[5] = getattr(termios, name)
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        return
    buf = bytearray(fcntl.ioctl(fd, TCGETS2, bytes(44)))
    cflag = struct.unpack_from("I", buf, 8)[0]
    struct.pack_into("I", buf, 8, (cflag & ~CBAUD) | BOTHER)
    struct.pack_into("2I", buf, 36, baud, baud)
    fcntl.ioctl(fd, TCSETS2, buf)


def open_port(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = termios.IGNBRK                        # iflag: raw
    attrs[1] = 0                                     # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL    # cflag: 8N1, no flow control
    attrs[3] = 0                                     # lflag
    attrs[4] = attrs[5] = termios.B115200
    attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 0, 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    set_baud(fd, baud)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_byte(fd, timeout):
    """One byte, or None after timeout seconds."""
    if select.select([fd], [], [], timeout)[0]:
        data = os.read(fd, 1)
        return data[0] if data else None
    return None


def load(fd, image, wait):
    print(f"waiting for the bootloader's 'W' (reset the chip), {wait:.0f} s", file=sys.stderr)
    end = time.monotonic() + wait
    while True:
        left = end - time.monotonic()
        if left <= 0:
            sys.exit("no 'W' from the bootloader: is GPIO[5] up (SW5 on the FPGA), the port right, and was the chip reset?")
        if read_byte(fd, min(left, 0.5)) == ord("W"):
            break
    os.write(fd, len(image).to_bytes(4, "little"))
    for i in range(0, len(image), 256):              # in blocks: the bootloader has no flow control
        os.write(fd, image[i:i + 256])
        termios.tcdrain(fd)
    got = read_byte(fd, 5)
    want = sum(image) & 0xFF
    if got is None:
        sys.exit("no checksum from the bootloader")
    if got == ord("!"):
        sys.exit("the bootloader refused the size")
    if got != want:
        sys.exit(f"checksum {got:#04x}, expected {want:#04x}")
    print(f"loaded {len(image)} bytes, checksum {got:#04x}", file=sys.stderr)


def console(fd):
    try:
        while True:
            if select.select([fd], [], [], 0.5)[0]:
                data = os.read(fd, 256)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
    except KeyboardInterrupt:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("port", help="serial device, e.g. /dev/ttyUSB1")
    parser.add_argument("image", help="flat binary loaded at 0x80000000 (at most 64 KiB)")
    parser.add_argument("--baud", type=int, default=115200, help="the program's console (default 115200)")
    parser.add_argument("--boot-baud", type=int, default=115200,
                        help="the bootloader's: 115200 with all of GPIO[4:0] low at reset, else f_clk / (16 * divisor)")
    parser.add_argument("--wait", type=float, default=60, help="seconds to wait for the bootloader (default 60)")
    parser.add_argument("--no-console", action="store_true", help="exit after loading")
    args = parser.parse_args()
    image = open(args.image, "rb").read()
    if not 0 < len(image) <= MAX_SIZE:
        sys.exit(f"{args.image}: {len(image)} bytes, the bootloader takes 1 to {MAX_SIZE}")
    fd = open_port(args.port, args.boot_baud)
    load(fd, image, args.wait)
    set_baud(fd, args.baud)
    if not args.no_console:
        console(fd)


if __name__ == "__main__":
    main()
