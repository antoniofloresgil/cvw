# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Uncached reads with side effects while snooped dirty lines are written to memory (coherent L1, ADR 0026).
# (SPI version in spisnoop.S.) Hart 0 sends bytes through the SPI and reads back as many from the receive FIFO, which a read
# dequeues: a read performed twice, or an early one, finds the FIFO empty or leaves a byte over.
# Hart 0 does nothing else, while the other harts take a line from each other: every acquire snoops a
# dirty copy, and the controller writes it to memory between hart 0's SPI transfers. Slots and stacks match smoke.S.
.section .text.init
.globl _start
.equ SPI, 0x10040000
.equ ROUNDS, 20
.equ BYTES, 4
_start:
    csrr s0, mhartid
    li sp, 0x8000f000
    slli t0, s0, 10
    sub sp, sp, t0
    li s1, 0x80008000
    slli t0, s0, 6
    add s1, s1, t0
    la t0, fail
    csrw mtvec, t0
    sd zero, 24(s1)
    li s4, 0x80009000          # 0(s4): line every hart writes; 64(s4): hart 0's done flag
    li t0, 2
    bgeu s0, t0, hammer

    # Hart 0: back-to-back uncached reads of mtime, which must never go backwards
    li a0, 0x0200bff8
    li s5, 4000
    ld t2, 0(a0)
round:
    ld t1, 0(a0)
    bltu t1, t2, fail
    mv t2, t1
    addi s5, s5, -1
    bnez s5, round
    li t0, 1
    fence rw, rw
    bnez s0, 2f
    sd t0, 64(s4)
2:
    sd t0, 24(s1)
park:
    j park

    # Other harts: write the shared line until hart 0 is done
hammer:
    li t0, 1
    sd t0, 8(s1)
1:
    ld t1, 0(s4)
    addi t1, t1, 1
    sd t1, 0(s4)
    ld t1, 64(s4)
    beqz t1, 1b
    li t0, 1
    sd t0, 24(s1)
    j park

.balign 4
fail:
    csrr t1, mcause
    sd t1, 16(s1)
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
