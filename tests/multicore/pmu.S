# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Per-hart PMU checks; the same image runs on every hart.
# Slot layout (s1): 0 barrier generation, 8 phase, 24 done/0xdead, 40 mcause or
# diagnostic, 48 LCOFI count. Wally counts event N only in counter N, enabled
# by any nonzero mhpmeventN; tests write N there.
#define CSRWRITES 19          // event: CSR writes retired, counted by mhpmcounter19
#define LCOFI_CAUSE 0x800000000000000d
#define BARRIER(gen)          \
    li t0, gen;               \
    sd t0, 0(s1);             \
    fence rw, rw;             \
    li t1, 0x80008000;        \
    li t2, NCORES;            \
88: ld t3, 0(t1);             \
    bltu t3, t0, 88b;         \
    addi t1, t1, 64;          \
    addi t2, t2, -1;          \
    bnez t2, 88b;             \
    fence rw, rw
#define PHASE(n) li t0, n; sd t0, 8(s1)

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
    csrw mie, zero
    sd zero, 8(s1)
    sd zero, 24(s1)
    sd zero, 40(s1)
    sd zero, 48(s1)
    BARRIER(1)

    # Phase 1: counters are per hart. Every hart writes distinct values while
    # inhibited; after all writes, each hart still reads back its own values.
    PHASE(1)
    li t0, -1
    csrw mcountinhibit, t0
    addi s2, s0, 1
    slli s3, s2, 40
    slli s2, s2, 32
    csrw mhpmcounter19, s2
    csrw minstret, s3
    BARRIER(2)
    csrr t0, mhpmcounter19
    bne t0, s2, fail
    csrr t0, minstret
    bne t0, s3, fail
    BARRIER(3)

    # Phase 2: each hart counts only its own events while all harts run
    # different amounts of work concurrently.
    PHASE(2)
    addi s2, s0, 1
    slli s2, s2, 3            # N = 8 * (hartid + 1)
    mv t1, s2
    li t0, CSRWRITES
    csrw mhpmevent19, t0      # a zero selector disables the counter
    csrw mhpmcounter19, zero
    csrw mcountinhibit, zero
    csrr a0, minstret
    csrr a2, mhpmcounter19
1:  csrw mscratch, zero
    addi t1, t1, -1
    bnez t1, 1b
    csrr a3, mhpmcounter19
    csrr a1, minstret
    sub t0, a3, a2
    sub t1, a1, a0
    slli t2, t0, 32
    or t2, t2, t1
    sd t2, 40(s1)             # diagnostic: CSR-write delta << 32 | instret delta
    bne t0, s2, fail          # exactly N CSR writes
    mv t0, t1                 # 3N loop instructions, two counter19 reads, and
    slli t2, s2, 1            # possibly one minstret read itself
    add t2, t2, s2
    addi t2, t2, 2
    blt t0, t2, fail
    addi t2, t2, 1
    bgt t0, t2, fail
    BARRIER(4)

    # Phase 3: Sscofpmf overflow interrupts reach only the overflowing hart.
    # Even harts overflow counter 19 with LCOFI enabled; odd harts count the
    # same events without overflowing and must see no LCOFI.
    PHASE(3)
    li t0, CSRWRITES
    csrw mhpmevent19, t0      # clear OF
    andi t0, s0, 1
    bnez t0, 2f
    addi t0, s0, 3
    neg t0, t0
    csrw mhpmcounter19, t0    # overflow after hartid + 3 writes
    li t0, 0x2000
    csrw mie, t0              # LCOFIE
    csrsi mstatus, 8
    j 3f
2:  csrw mhpmcounter19, zero
3:  li t1, 16
4:  csrw mscratch, zero
    addi t1, t1, -1
    bnez t1, 4b
    csrci mstatus, 8
    csrw mie, zero
    ld t1, 48(s1)
    andi t0, s0, 1
    xori t0, t0, 1            # expected interrupts: 1 on even harts, 0 on odd
    bne t1, t0, fail
    csrr t0, mip
    li t1, 0x2000
    and t0, t0, t1
    bnez t0, fail             # no pending LCOFI left on any hart
    BARRIER(5)

#ifdef CACHE_EVENTS
    # Phase 4: cache events count on harts whose caches live in the multicore
    # memory system. 16 loads from a hart-private region: at least one miss;
    # a call to code never fetched before: at least one I$ miss.
    PHASE(4)
    li t0, 13
    csrw mhpmevent13, t0
    li t0, 14
    csrw mhpmevent14, t0
    li t0, 16
    csrw mhpmevent16, t0
    li t0, 17
    csrw mhpmevent17, t0
    csrw mcountinhibit, zero
    csrr a0, mhpmcounter13
    csrr a1, mhpmcounter14
    csrr a2, mhpmcounter16
    csrr s4, mhpmcounter17
    li t1, 0x8000a000
    slli t0, s0, 10
    add t1, t1, t0
    li t2, 16
5:  ld t0, 0(t1)
    addi t1, t1, 8
    addi t2, t2, -1
    bnez t2, 5b
    jal ra, cold
    csrr a3, mhpmcounter13
    csrr a4, mhpmcounter14
    csrr a5, mhpmcounter16
    csrr s5, mhpmcounter17
    sub t0, a3, a0
    li t1, 16
    bltu t0, t1, fail         # D$ accesses
    beq a4, a1, fail          # D$ misses
    beq a5, a2, fail          # I$ accesses
    beq s5, s4, fail          # I$ misses
    BARRIER(6)
#endif

    PHASE(0)
    li t0, 1
    sd t0, 24(s1)
5:  j 5b

.balign 4
trap:
    addi sp, sp, -32
    sd t0, 0(sp)
    sd t1, 8(sp)
    csrr t0, mcause
    sd t0, 40(s1)
    li t1, LCOFI_CAUSE
    bne t0, t1, fail
    csrr t0, mhpmevent19
    bgez t0, fail             # OF must be set on the interrupted hart
    li t0, CSRWRITES
    csrw mhpmevent19, t0      # clear OF
    li t0, 0x2000
    csrc mip, t0
    ld t0, 48(s1)
    addi t0, t0, 1
    sd t0, 48(s1)
    ld t0, 0(sp)
    ld t1, 8(sp)
    addi sp, sp, 32
    mret
fail:
    li t0, 0xdead
    sd t0, 24(s1)
    j fail

#ifdef CACHE_EVENTS
.balign 256                   # alone in its I$ line, first fetched in phase 4
cold:
    ret
#endif
