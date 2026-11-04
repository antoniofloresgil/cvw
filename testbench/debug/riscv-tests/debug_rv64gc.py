# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""riscv-tests/debug target: Wally's debug_rv64gc in Verilator (testbench/debug/openocd_tb).
Build the simulation first: make -C $WALLY/testbench/debug openocd OPENOCD_CONFIG=debug_rv64gc
Then, in riscv-tests/debug: ./gdbserver.py $WALLY/testbench/debug/riscv-tests/debug_rv64gc.py"""

import os
import sys
from typing import ClassVar

import targets

sys.path.insert(0, os.path.dirname(__file__))
from wallysim import WallySim  # pylint: disable=wrong-import-position


class debug_rv64gc_hart(targets.Hart):
    xlen = 64
    ram = 0x80000000
    ram_size = 0x8000000                 # UNCORE_RAM_RANGE
    bad_address = ram - 8
    reset_vectors: ClassVar[list[int]] = [0x80000000]
    link_script_path = "wally64.lds"
    instruction_hardware_breakpoint_count = 0


class debug_rv64gc(targets.Target):
    harts: ClassVar[list[targets.Hart]] = [debug_rv64gc_hart(misa=0x800000000014112f)]
    openocd_config_path = "wally.cfg"
    timeout_sec = 600                    # the simulation is slow
    server_timeout_sec = 300
    support_mcontrol = False
    support_mcontrol6 = False
    support_memory_sampling = False     # OpenOCD 0.12 has no memory_sample
    support_manual_hwbp = False
    support_hasel = False

    def create(self):
        return WallySim(self, "debug_rv64gc")
