# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""riscv-tests/debug target: Wally's debug_rv64gc_nocache with two harts (NHARTS=2), in Verilator.
Build the simulation first:
  make -C $WALLY/testbench/debug openocd OPENOCD_CONFIG=debug_rv64gc_nocache NHARTS=2
Then, in riscv-tests/debug: ./gdbserver.py $WALLY/testbench/debug/riscv-tests/debug_rv64gc_nocache_2harts.py"""

import os
import sys
from typing import ClassVar

import targets

sys.path.insert(0, os.path.dirname(__file__))
from debug_rv64gc import debug_rv64gc_hart  # pylint: disable=wrong-import-position
from wallysim import WallySim  # pylint: disable=wrong-import-position


class debug_rv64gc_nocache_2harts(targets.Target):
    harts: ClassVar[list[targets.Hart]] = [debug_rv64gc_hart(misa=0x800000000014112f),
                                           debug_rv64gc_hart(misa=0x800000000014112f)]
    openocd_config_path = "wally-2.cfg"
    timeout_sec = 600                    # the simulation is slow
    server_timeout_sec = 300
    support_memory_sampling = False     # OpenOCD 0.12 has no memory_sample
    support_hasel = False

    def create(self):
        return WallySim(self, "debug_rv64gc_nocache-2harts")
