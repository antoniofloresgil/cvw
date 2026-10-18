# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
.section .text
.globl _start
_start:
    csrr s0, mhartid
    li s1, 0x80008000
    slli t0, s0, 6
    add s1, s1, t0
    # Exercise RAM byte/halfword lanes as well as device byte writes.
    li t0, 0x1122334455667788
    sd t0, 48(s1)
    lbu t1, 53(s1)
    li t2, 0x33
    bne t1, t2, fail
    lhu t1, 54(s1)
    li t2, 0x1122
    bne t1, t2, fail
    lb t1, 48(s1)
    li t2, -120
    bne t1, t2, fail
    li t0, 0xaa
    sb t0, 53(s1)
    ld t1, 48(s1)
    li t2, 0x1122aa4455667788
    bne t1, t2, fail
    li t0, 0xbbbb
    sh t0, 50(s1)
    ld t1, 48(s1)
    li t2, 0x1122aa44bbbb7788
    bne t1, t2, fail
    li t0, 0xccddeeff
    sw t0, 52(s1)
    ld t1, 48(s1)
    li t2, 0xccddeeffbbbb7788
    bne t1, t2, fail
    lbu t1, 54(s1)
    li t2, 0xdd
    bne t1, t2, fail
    bnez s0, done
    li s2, 0x10000000
    # Match the OpenSBI 8250 setup and polling sequence.
    li t0, 0x80
    sb t0, 3(s2)
    li t0, 10
    sb t0, 0(s2)
    sb zero, 1(s2)
    li t0, 3
    sb t0, 3(s2)
    li s3, 0x41
    li s4, 0x45
next:
    lb t0, 5(s2)
    andi t0, t0, 0x20
    beqz t0, next
    sb s3, 0(s2)
    addi s3, s3, 1
    blt s3, s4, next
    fence rw, rw
done:
    li t0, 1
    sd t0, 24(s1)
park:
    j park

fail:
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
