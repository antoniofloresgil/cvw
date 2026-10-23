# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Same image on every hart. No AMO/LRSC, no shared stack, single-writer slots.
.section .text.init
.globl _start
_start:
    csrr s0, mhartid
    li sp, 0x8000f000
    slli t0, s0, 10
    sub sp, sp, t0
    li s1, 0x80008000
    slli t0, s0, 6
    add s1, s1, t0
    la t0, trap
    csrw mtvec, t0
    li s2, 0x02000000
    slli t0, s0, 2
    add s2, s2, t0
    sw zero, 0(s2)
    li s3, 0x02004000
    slli t0, s0, 3
    add s3, s3, t0
    li t0, -1
    sd t0, 0(s3)
    # Exercise both PLIC context banks through the actual SoC address decoder.
    li t1, 0x0c200000
    slli t0, s0, 13
    add t1, t1, t0
    li t0, 3
    sw t0, 0(t1)
    lw t2, 0(t1)
    bne t0, t2, fail
    sw zero, 0(t1)
    li t0, 0x1000
    add t1, t1, t0
    li t0, 5
    sw t0, 0(t1)
    lw t2, 0(t1)
    bne t0, t2, fail
    sw zero, 0(t1)
    sd zero, 8(s1)
    sd zero, 16(s1)
    sd zero, 24(s1)
    addi t0, s0, 0x100
    sd t0, 32(s1)
    li t0, 0x88
    csrw mie, t0
    csrsi mstatus, 8
    fence rw, rw
    li t0, 1
    sd t0, 0(s1)
    # Barrier: every hart has initialized its own state before messages are sent.
    li t1, 0x80008000
    li t2, NCORES
1:
    ld t0, 0(t1)
    beqz t0, 1b
    addi t1, t1, 64
    addi t2, t2, -1
    bnez t2, 1b
    fence rw, rw
    # Check shared-memory payloads written by every hart.
    li t1, 0x80008000
    li t2, 0
2:
    ld t0, 32(t1)
    addi t3, t2, 0x100
    bne t0, t3, fail
    addi t1, t1, 64
    addi t2, t2, 1
    li t3, NCORES
    bltu t2, t3, 2b
    # Ring IPI, including self-IPI for the NCORES=1 regression.
    addi t0, s0, 1
    li t1, NCORES
    bltu t0, t1, 3f
    li t0, 0
3:
    slli t0, t0, 2
    li t1, 0x02000000
    add t1, t1, t0
    li t0, 1
    sw t0, 0(t1)
    li t1, 0x0200bff8
    ld t0, 0(t1)
    addi t0, t0, 200
    sd t0, 0(s3)
4:
    ld t0, 8(s1)
    beqz t0, 4b
    ld t0, 16(s1)
    beqz t0, 4b
    li t0, 1
    sd t0, 24(s1)
5:
    j 5b

.balign 4
trap:
    addi sp, sp, -32
    sd t0, 0(sp)
    sd t1, 8(sp)
    csrr t0, mcause
    li t1, 0x8000000000000003
    beq t0, t1, software
    li t1, 0x8000000000000007
    bne t0, t1, fail
    li t0, -1
    sd t0, 0(s3)
    li t0, 1
    sd t0, 16(s1)
    j return
software:
    sw zero, 0(s2)
    li t0, 1
    sd t0, 8(s1)
return:
    ld t0, 0(sp)
    ld t1, 8(sp)
    addi sp, sp, 32
    mret
fail:
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
