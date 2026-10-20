# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Cold read followed by a first write to 32 private lines per hart.
# Separate pages prevent true or false data sharing during the measured loop.
.section .text.init
.globl _start
_start:
    csrr s0, mhartid
    li s1, 0x80008000
    slli t0, s0, 6
    add s1, s1, t0
    la t0, fail
    csrw mtvec, t0
    la s2, private_pages
    slli t0, s0, 12
    add s2, s2, t0
    li s3, 32
    li s4, 0
1:
    ld t0, 0(s2)
    bnez t0, fail
    add t1, s0, s4
    addi t1, t1, 0x100
    sd t1, 0(s2)
    ld t0, 0(s2)
    bne t0, t1, fail
    addi s2, s2, 32
    addi s4, s4, 1
    bltu s4, s3, 1b
    fence rw, rw
    li t0, 1
    sd t0, 24(s1)
2:
    j 2b
.balign 4
fail:
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
.section .data
.balign 4096
private_pages:
    .zero NCORES * 4096
