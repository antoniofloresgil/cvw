# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# roi-end: mark the end of the region of interest for roibbv (a HINT: no effect on Wally or any RISC-V core), then exit
.globl _start
_start:
  slti x0, x0, 0x7a2
  li a0, 0
  li a7, 93          # exit
  ecall
