# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""riscv-tests/debug target: Wally's debug_rv32imc in Verilator (testbench/debug/openocd_tb).
Build the simulation first: make -C $WALLY/testbench/debug openocd OPENOCD_CONFIG=debug_rv32imc
Then, in riscv-tests/debug: ./gdbserver.py $WALLY/testbench/debug/riscv-tests/debug_rv32imc.py"""

import os
import sys
from typing import ClassVar

import targets

sys.path.insert(0, os.path.dirname(__file__))
from wallysim import WallySim  # pylint: disable=wrong-import-position


class debug_rv32imc_hart(targets.Hart):
    xlen = 32
    ram = 0x80000000
    ram_size = 0x100000                  # UNCORE_RAM_RANGE
    bad_address = ram - 8
    reset_vectors: ClassVar[list[int]] = [0x80000000]
    link_script_path = "wally32.lds"
    instruction_hardware_breakpoint_count = 4   # DEBUG_TRIGGERS


class debug_rv32imc(targets.Target):
    harts: ClassVar[list[targets.Hart]] = [debug_rv32imc_hart(misa=0x40101104)]
    openocd_config_path = "wally.cfg"
    timeout_sec = 600                    # the simulation is slow
    server_timeout_sec = 300
    implements_page_virtual_memory = False
    support_memory_sampling = False     # OpenOCD 0.12 has no memory_sample
    support_hasel = False

    def create(self):
        return WallySim(self, "debug_rv32imc")
