#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Put a file on the board's Linux through the console UART, with no SD card: for a small binary or input while the root file system is the initramfs.

Wally's UART has no FIFO: a burst of more than a few characters at 115200 baud overruns it and a character is now and then lost or doubled (about one per 20 KB
at 2 bytes per millisecond).  So the file is gzipped, sent as base64 in chunks of 8 KB, each chunk is checked on the board with md5sum and sent again if it differs.
About 800 KB take 16 minutes; use it only for small files.  Standard library only (the board needs BusyBox base64, md5sum, gzip, which the image has).

Two commands share a log file and a FIFO, so a person or another script can type on the console too:
  uart-upload.py bridge <serial device> <log> <fifo>      # keeps running: logs what the board prints, writes what you put in the FIFO (2 bytes per ms)
  uart-upload.py put <file> <remote path on the board> <log> <fifo>
`put` leaves <remote path> (the file, decompressed) on the board and checks its sha256 (printed on the console) against the PC's; the board must be at a shell prompt.
"""

import base64
import gzip
import hashlib
import os
import re
import select
import sys
import termios
import time

CHUNK_LINES = 105  # 105 base64 lines of 76 characters, about 8 KB
BURST, GAP = 2, 0.001  # characters per write and seconds between writes


def bridge(port, log, fifo):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attr = termios.tcgetattr(fd)
    attr[0] = attr[1] = attr[3] = 0
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attr[4] = attr[5] = termios.B115200
    attr[6][termios.VMIN] = attr[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    fin = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    pending = b""
    with open(log, "ab", buffering=0) as out:
        while True:
            ready, _, _ = select.select([fd, fin], [], [], GAP if pending else 1)
            if fd in ready:
                out.write(os.read(fd, 65536))
            if fin in ready:
                pending += os.read(fin, 65536)
            if pending:
                os.write(fd, pending[:BURST])
                pending = pending[BURST:]


def put(path, remote, log, fifo):
    def send(data):
        with open(fifo, "wb") as f:
            f.write(data)

    def wait(regex, start, seconds):
        end = time.time() + seconds
        while time.time() < end:
            m = re.search(regex, open(log, "rb").read()[start:].replace(b"\r", b""))
            if m:
                return m
            time.sleep(0.3)
        return None

    raw = open(path, "rb").read()
    lines = base64.encodebytes(gzip.compress(raw, 9, mtime=0)).splitlines(keepends=True)  # 76 characters per line
    chunks = [b"".join(lines[i : i + CHUNK_LINES]) for i in range(0, len(lines), CHUNK_LINES)]
    send(b"\nrm -f /tmp/up.b64\n")
    time.sleep(1)
    start, retries = time.time(), 0
    for i, chunk in enumerate(chunks):
        for _ in range(6):
            mark = os.path.getsize(log)
            send(b"rm -f /tmp/up.c; cat > /tmp/up.c\n")
            time.sleep(0.6)
            send(chunk)
            time.sleep(len(chunk) / 1500.0)
            send(b"\004")  # end of input, at the start of a line
            time.sleep(0.4)
            send(b"echo CKR%d $(md5sum < /tmp/up.c)\n" % i)
            m = wait(rb"CKR%d ([0-9a-f]{32})" % i, mark, 40)
            if m and m.group(1).decode() == hashlib.md5(chunk).hexdigest():
                send(b"cat /tmp/up.c >> /tmp/up.b64\n")
                time.sleep(0.5)
                break
            retries += 1
            time.sleep(1)
        else:
            sys.exit(f"chunk {i} failed 6 times")
        print(f"chunk {i + 1}/{len(chunks)}, {time.time() - start:.0f} s, {retries} retries", flush=True)
    mark = os.path.getsize(log)
    send(f"base64 -d /tmp/up.b64 | gzip -dc > {remote}; sha256sum < {remote}\n".encode())
    m = wait(rb"([0-9a-f]{64})  -", mark, 120 + len(raw) / 20000)
    if not m or m.group(1).decode() != hashlib.sha256(raw).hexdigest():
        sys.exit("sha256 of the file on the board differs")
    print("OK", remote, hashlib.sha256(raw).hexdigest())


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "bridge":
        bridge(*sys.argv[2:])
    elif len(sys.argv) == 6 and sys.argv[1] == "put":
        put(*sys.argv[2:])
    else:
        sys.exit(__doc__)
