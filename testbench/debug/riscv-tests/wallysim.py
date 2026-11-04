# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Launch openocd_tb (testbench/debug) for riscv-tests/debug: the simulation serves OpenOCD's
remote_bitbang on a free port, which it prints as "Listening on port N"."""

import os
import re
import subprocess
import tempfile
import time

import testlib


class WallySim:
    """One simulation of a configuration built by `make openocd OPENOCD_CONFIG=<config>`."""

    def __init__(self, target, config, timeout=120):
        sim = os.path.join(os.environ["WALLY"], "sim/verilator/wkdir/debug",
                           f"openocd-{config}", "Vopenocd_tb")
        # pylint: disable-next=consider-using-with
        self.logfile = tempfile.NamedTemporaryFile(prefix="wallysim-", suffix=".log")
        self.lognames = [self.logfile.name]
        # pylint: disable-next=consider-using-with
        self.process = subprocess.Popen([sim, "+RBB_PORT=0"], stdin=subprocess.DEVNULL,
                                        stdout=self.logfile, stderr=self.logfile)
        start = time.time()
        while True:
            with open(self.logfile.name, encoding="utf-8") as fd:
                m = re.search(r"Listening on port (\d+)", fd.read())
            if m:
                break
            if self.process.poll() is not None:
                raise testlib.TestLibError(f"{sim} exited with status {self.process.returncode}")
            if time.time() - start > timeout:
                raise testlib.TestLibError(f"{sim} did not listen for remote_bitbang")
            time.sleep(0.1)
        self.port = int(m.group(1))
        os.environ["REMOTE_BITBANG_HOST"] = "localhost"
        os.environ["REMOTE_BITBANG_PORT"] = str(self.port)
        # OpenOCD's work area: the start of RAM; the programs are linked 64 KiB above it
        os.environ["WORK_AREA"] = f"0x{target.harts[0].ram:x}"

    def __del__(self):
        try:
            self.process.kill()
            self.process.wait()
        except (OSError, AttributeError):
            pass
