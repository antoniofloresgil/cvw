# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Token ring over an array larger than the D-cache (coherent L1, ADR 0026): the token holder checks
# that every line holds the previous holder's value, writes its own and passes the token on. Each
# pass evicts dirty lines, snoops lines another hart modified and refills them, so a lost write-back,
# a stale copy or a misplaced snoop answer shows up as a wrong word. Slots and stacks match smoke.S.
.section .text.init
.globl _start
.equ ARRAY, 0x80002000          # 24 KiB: 0x80002000-0x80007fff, below the slots
.equ LINES, 384                 # 64-byte lines
.equ PASSES, 3                  # passes of the token around the ring
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
    li s4, 0x80009000           # 0(s4): token = number of the current turn (turn t belongs to hart t % NCORES)
    li s5, 0                    # this hart's turn number
    mv s5, s0
turn:
    li t0, PASSES*NCORES
    bgeu s5, t0, done
    li t0, 1
    sd t0, 8(s1)                # phase 1: waiting for the token
wait:
    ld t1, 0(s4)
    bne t1, s5, wait
    fence rw, rw
    li t0, 2
    sd t0, 8(s1)                # phase 2: checking the previous holder's words
    li a0, ARRAY
    li a1, LINES
    addi a2, s5, -1             # expected value: previous turn number, or 0 before the first turn
    bgez a2, check
    li a2, -1
check:
    beqz s5, write              # the first turn finds memory as loaded: skip the check
    ld t1, 0(a0)
    bne t1, a2, fail
    ld t1, 8(a0)
    bne t1, a2, fail
    ld t1, 56(a0)
    bne t1, a2, fail
    addi a0, a0, 64
    addi a1, a1, -1
    bnez a1, check
write:
    li t0, 3
    sd t0, 8(s1)                # phase 3: writing this turn's value in every line
    li a0, ARRAY
    li a1, LINES
1:
    sd s5, 0(a0)
    sd s5, 8(a0)
    sd s5, 56(a0)
    addi a0, a0, 64
    addi a1, a1, -1
    bnez a1, 1b
    fence rw, rw
    addi t1, s5, 1
    sd t1, 0(s4)                # pass the token
    addi s5, s5, NCORES
    j turn
done:
    li t0, 1
    sd t0, 24(s1)
park:
    j park

.balign 4
fail:
    csrr t1, mcause
    sd t1, 16(s1)
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
