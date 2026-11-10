# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wally_trace)
target_sources(app PRIVATE main.c)
# the chip on the Nexys Video has no JTAG: the demo prints the trace buffer (make APP=trace FPGA_DUMP=1)
if(FPGA_DUMP)
  target_compile_definitions(app PRIVATE FPGA_DUMP)
endif()
