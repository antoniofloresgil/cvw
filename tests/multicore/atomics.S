# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Uncached multicore A-extension tests. Slots and stacks match smoke.S.
.section .text.init
.globl _start
.macro CHECK reg, value
    li t6, \value
    bne \reg, t6, fail
.endm
.macro AMOCHECK op, width, initial, operand, expected
    li t0, \initial
    li t1, \operand
    .ifc \width,d
        sd t0, 0(a3)
    .else
        sw t0, 0(a3)
    .endif
    \op\().\width\().aqrl t2, t1, (a3)
    CHECK t2, \initial
    .ifc \width,d
        ld t3, 0(a3)
    .else
        lw t3, 0(a3)
    .endif
    CHECK t3, \expected
.endm
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
    li t0, 1
    sd t0, 8(s1)
    li s4, 0x80009000
    li s5, 0
    bnez s0, initialized
    # The simulation loader supplies zero-initialized shared memory.
    li t0, 1
    fence rw, rw
    sd t0, 128(s4)
initialized:
    ld t0, 128(s4)
    beqz t0, initialized
    fence rw, rw
    li t0, 1
    sd t0, 0(s1)
    li t1, 0x80008000
    li t2, NCORES
ready:
    ld t0, 0(t1)
    beqz t0, ready
    addi t1, t1, 64
    addi t2, t2, -1
    bnez t2, ready
    fence rw, rw

    # Single-hart ALU/width checks while the others wait at a barrier.
    bnez s0, alu_done
    addi a3, s4, 64
    AMOCHECK amoadd, d, 7, 5, 12
    AMOCHECK amoswap, d, -2, 9, 9
    AMOCHECK amoxor, d, 10, 12, 6
    AMOCHECK amoand, d, 10, 12, 8
    AMOCHECK amoor, d, 10, 12, 14
    AMOCHECK amomin, d, -2, 1, -2
    AMOCHECK amomax, d, -2, 1, 1
    AMOCHECK amominu, d, -2, 1, 1
    AMOCHECK amomaxu, d, -2, 1, -2
    AMOCHECK amoadd, w, 7, 5, 12
    AMOCHECK amoswap, w, -2, 9, 9
    AMOCHECK amoxor, w, 10, 12, 6
    AMOCHECK amoand, w, 10, 12, 8
    AMOCHECK amoor, w, 10, 12, 14
    AMOCHECK amomin, w, -2, 1, -2
    AMOCHECK amomax, w, -2, 1, 1
    AMOCHECK amominu, w, -2, 1, 1
    AMOCHECK amomaxu, w, -2, 1, -2
    # Word operations in the upper AHB lane, including sign extension.
    li t0, 0x8000000012345678
    sd t0, 64(s4)
    addi a3, s4, 68
    li t1, 1
    amoadd.w.aqrl t2, t1, (a3)
    CHECK t2, -2147483648
    lw t2, -4(a3)
    CHECK t2, 0x12345678
    lr.w.aq t2, (a3)
    CHECK t2, -2147483647
    li t1, 23
    sc.w.rl t2, t1, (a3)
    bnez t2, fail
    lw t2, 0(a3)
    CHECK t2, 23
    sc.w t2, t1, (a3)
    beqz t2, fail
alu_done:
    call barrier

    # Concurrent increments must preserve every write and return unique old values.
    li t0, 2
    sd t0, 8(s1)
    li s6, 16
    addi a3, s4, 0
amo_count:
    li t1, 1
    amoadd.d.aqrl t0, t1, (a3)
    li t2, NCORES*16
    bgeu t0, t2, fail
    li t2, 0x8000a000
    slli t3, t0, 3
    add t2, t2, t3
    addi t3, s0, 1
    sd t3, 0(t2)
    addi s6, s6, -1
    bnez s6, amo_count
    call barrier
    ld t0, 0(s4)
    CHECK t0, NCORES*16
    # N returns in [0,N) must cover all slots: duplicates leave a zero hole.
    li t1, 0x8000a000
    li t2, NCORES*16
unique_old:
    ld t0, 0(t1)
    beqz t0, fail
    addi t1, t1, 8
    addi t2, t2, -1
    bnez t2, unique_old

    li t0, 3
    sd t0, 8(s1)
    li s6, 16
    addi a3, s4, 8
lrsc_count:
    lr.d.aq t0, (a3)
    addi t0, t0, 1
    sc.d.rl t2, t0, (a3)
    bnez t2, lrsc_count
    addi s6, s6, -1
    bnez s6, lrsc_count
    call barrier
    ld t0, 8(s4)
    CHECK t0, NCORES*16

    li t0, 4
    sd t0, 8(s1)
    # AMOSWAP spinlock protects a deliberately split load/add/store.
    li s6, 8
    addi a3, s4, 16
lock:
    li t0, 1
    amoswap.w.aq t1, t0, (a3)
    bnez t1, lock
    ld t0, 24(s4)
    nop
    nop
    addi t0, t0, 1
    sd t0, 24(s4)
    fence rw, w
    sw zero, 0(a3)
    addi s6, s6, -1
    bnez s6, lock
    call barrier
    ld t0, 24(s4)
    CHECK t0, NCORES*8

    li t0, 5
    sd t0, 8(s1)
    # Controlled conflict: hart 1 writes exactly between hart 0's LR and SC.
#if NCORES > 1
    beqz s0, reserve
    li t0, 1
    bne s0, t0, conflict_done
wait_lr:
    ld t0, 96(s4)
    beqz t0, wait_lr
    li t0, 7
    sd t0, 80(s4)
    fence rw, rw
    sd t0, 104(s4)
    j conflict_done
reserve:
    addi a3, s4, 80
    lr.d t2, (a3)
    li t0, 1
    sd t0, 96(s4)
wait_store:
    ld t0, 104(s4)
    beqz t0, wait_store
    li t1, 99
    sc.d t0, t1, (a3)
    beqz t0, fail
    ld t0, 0(a3)
    CHECK t0, 7
conflict_done:
#endif
    call barrier
    li t0, 6
    sd t0, 8(s1)
    # LR/SC without interference succeeds, then consumes the reservation.
    slli t0, s0, 3
    addi a3, s4, 160
    add a3, a3, t0
    lr.d t0, (a3)
    li t1, 123
    sc.d t2, t1, (a3)
    bnez t2, fail
    sc.d t2, t1, (a3)
    beqz t2, fail
    call barrier
    li t0, 1
    sd t0, 24(s1)
park:
    j park

# Reusable sense-reversing barrier: reset count before publishing the next phase.
barrier:
    xori s5, s5, 1
    addi a4, s4, 32
    li t1, 1
    amoadd.w.aqrl t0, t1, (a4)
    li t1, NCORES-1
    bne t0, t1, barrier_wait
    sw zero, 0(a4)
    fence rw, rw
    sw s5, 40(s4)
    ret
barrier_wait:
    lw t0, 40(s4)
    bne t0, s5, barrier_wait
    fence rw, rw
    ret

.balign 4
fail:
    csrr t1, mcause
    sd t1, 40(s1)
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
