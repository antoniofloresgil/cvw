# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
.section .text
.globl _start
_start:
    csrr a0, mhartid
    li a1, 0x87000000
    li t0, 0x80000000
    jr t0
