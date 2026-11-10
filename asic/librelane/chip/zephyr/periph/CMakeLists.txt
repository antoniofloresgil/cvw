# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wally_periph)
target_sources(app PRIVATE main.c)
# the chip on the Nexys Video: edges made by hand on SW4 (make APP=periph FPGA_TIMING=1)
if(FPGA_TIMING)
  target_compile_definitions(app PRIVATE FPGA_TIMING)
endif()
