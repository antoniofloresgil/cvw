# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Random coherence stress for the coherent L1 D-caches (ADR 0026), for 1 to 4 harts.
# Eight pool lines fall into two cache sets, four lines each (4 KiB apart), so with the test slots and the
# barrier line they keep evicting each other in 4-way caches. Doubleword d of every pool line belongs to hart
# d mod 4: every hart writes its own doublewords in lines the others write too, and keeps what it wrote in
# a private table. Each iteration an xorshift generator picks one operation:
#   store to an own doubleword, load one back and check it, load another hart's doubleword (its owner tag
#   must be right), amoadd to a counter, an LR/SC increment of another counter, fence.i (which writes
#   back and invalidates the whole D-cache), or an uncached read of mtime.
# A store lost on the way (a dirty bit cleared by mistake, a stale line written back, a snoop answered
# from the wrong way) shows up as a wrong value in a hart's own doubleword. At the end each hart checks
# all its doublewords and hart 0 checks both counters against the operations the harts counted.
# With -DIRQ each hart also takes machine timer interrupts every 400 to 4495 cycles during phase 2; the
# handler does an amoadd to a third counter and a load from the pool, so traps cut the cache's accesses,
# acquires and grants at random points.
# With -DVM phase 2 runs in S-mode under Sv39 (the hardware walker reads the page tables through the
# coherent D-cache): the 16 pages of RAM are mapped twice, at 0x80000000 and at the alias 0xc0000000
# (the same leaf table), with A and D clear. Svade: the first access to a page faults and the M-mode
# handler sets A (and D for a store) with an amoor on the leaf; one more operation clears A and D of a
# page the test uses (code, slots, counters, pool, stacks) with an amoand and flushes this hart's TLB,
# so leaf lines move between the harts' caches while their walkers read them. Pool accesses pick one
# of the two aliases at random.
# With both, each hart switches interrupts off before it sets MPP = S for the mret into phase 2: a timer
# trap taken between the two (on the mret itself, say) returns with its own mret, which leaves MPP = U,
# and phase 2 would then run in U-mode, where every access to the (supervisor) pages faults again after
# the handler sets A and D. Seed 2 of 4 harts with random latency 0..60 hit that window; the handler
# now fails a fault taken in U-mode instead of looping.
# Slots and stacks match smoke.S; the shared line at 0x80009000 holds the barrier (32, 40) and the
# counters (256, 320, 384); the page tables are at 0x80005000 (root), 0x80006000 and 0x80007000 (leaves).
.section .text.init
.globl _start
#ifndef ITERATIONS
#define ITERATIONS 3000
#endif
#ifndef SEED
#define SEED 1
#endif
.equ POOL, 0x8000a000
.equ MTIME, 0x0200bff8
.equ MTIMECMP, 0x02004000
.equ PT_ROOT, 0x80005000
.equ PT_L1, 0x80006000
.equ PT_L0, 0x80007000
#if defined(IRQ) || defined(VM)
#define TRAPS
#endif
_start:
    li a5, 0                   # 1: slot_address may use the alias (VM, phase 2)
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
    li s4, 0x80009000
    li s5, 0                   # barrier sense
    li t0, 1
    sd t0, 8(s1)               # phase 1: clear own doublewords and the table
    addi s2, sp, -256          # private table: 16 doublewords, entry 2*line + half
    li s3, 0                   # entry index
clear:
    mv a0, s3
    call slot_address
    sd zero, 0(a0)
    slli t0, s3, 3
    add t0, t0, s2
    sd zero, 0(t0)
    addi s3, s3, 1
    li t0, 16
    bne s3, t0, clear
#ifdef VM
    bnez s0, 1f
    call build_tables
1:
#endif
    call barrier

    li t0, 2
    sd t0, 8(s1)               # phase 2: random operations
    li s6, SEED                # generator state: SEED * (hart + 1) * golden ratio, never 0
    addi t0, s0, 1
    li t1, 0x9e3779b97f4a7c15
1:  add s6, s6, t1
    addi t0, t0, -1
    bnez t0, 1b
#ifdef TRAPS
    addi t0, sp, -512          # trap save area: t0-t2, generator, interrupts taken, ra, page faults
    csrw mscratch, t0
    sd s6, 24(t0)
    sd zero, 32(t0)
    sd zero, 48(t0)
    la t0, trap
    csrw mtvec, t0
#endif
#ifdef IRQ
    call arm_timer
    li t0, 0x80
    csrs mie, t0
    csrsi mstatus, 8
#endif
    li s7, ITERATIONS
    li s8, 0                   # amoadds done
    li s9, 0                   # LR/SC increments done
    li s10, 0                  # store sequence number
#ifdef VM
    li t0, -1
    csrw pmpaddr0, t0          # S-mode needs a PMP entry: all of memory, RWX
    li t0, 0x1f
    csrw pmpcfg0, t0
    li t0, (8 << 60) | (PT_ROOT >> 12)
    csrw satp, t0
    sfence.vma zero, zero
    li a5, 1
    csrci mstatus, 8           # no interrupt between MPP and mret: a trap's own mret would leave MPP = U;
                               # in S-mode the machine timer interrupt is taken anyway
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x800               # MPP = S
    csrs mstatus, t0
    la t0, loop
    csrw mepc, t0
    mret
#endif
loop:
    # xorshift64
    slli t0, s6, 13
    xor s6, s6, t0
    srli t0, s6, 7
    xor s6, s6, t0
    slli t0, s6, 17
    xor s6, s6, t0
    srli a0, s6, 8
    andi a0, a0, 15            # table entry
    andi t2, s6, 15            # operation
    li t0, 5
    bltu t2, t0, op_store
    li t0, 8
    bltu t2, t0, op_check
    li t0, 10
    bltu t2, t0, op_foreign
    li t0, 10
    beq t2, t0, op_amo
    li t0, 11
    beq t2, t0, op_lrsc
    li t0, 12
    beq t2, t0, op_fencei
    li t0, 13
    beq t2, t0, op_mtime
#ifdef VM
    li t0, 15
    beq t2, t0, op_pte
#endif
    j op_storecheck

op_store:
    call store_own
    j next
op_storecheck:
    mv s11, a0
    call store_own
    mv a0, s11
    call check_own
    j next
op_check:
    call check_own
    j next
op_foreign:
    # a doubleword of the same line but of hart (own + 1..3) mod 4: zero, or tagged with its owner
    mv s11, a0
    call slot_address
    srli t0, s6, 20
    andi t0, t0, 3
    addi t0, t0, 1             # 1..4: another doubleword in the same half of the line
    slli t0, t0, 3
    andi t1, a0, 63            # offset of the own doubleword in the line
    add t1, t1, t0
    andi t1, t1, 31            # stay in the same 32-byte half
    andi t3, a0, 32
    or t1, t1, t3
    andi t3, a0, -64
    add t3, t3, t1             # address of the other doubleword
    ld t4, 0(t3)
    beqz t4, next
    srli t4, t4, 56            # owner tag: hart + 1
    srli t5, t1, 3
    andi t5, t5, 3             # owner of that doubleword
    addi t5, t5, 1
    bne t4, t5, fail
    j next
op_amo:
    addi t0, s4, 256
    li t1, 1
    amoadd.d.aqrl zero, t1, (t0)
    addi s8, s8, 1
    j next
op_lrsc:
    addi t0, s4, 320
2:  lr.d.aqrl t1, (t0)
    addi t1, t1, 1
    sc.d.rl t3, t1, (t0)
    bnez t3, 2b
    addi s9, s9, 1
    j next
op_fencei:
    fence.i
    j next
op_mtime:
    li t0, MTIME
    ld t0, 0(t0)
    j next
#ifdef VM
op_pte:
    # clear A and D in the leaf of a page the test uses, then flush this hart's TLB
    srli t0, s6, 30
    andi t0, t0, 7
    la t1, pte_pages
    add t1, t1, t0
    lbu t0, 0(t1)              # page 0..15 of RAM
    slli t0, t0, 3
    li t1, PT_L0
    add t1, t1, t0
    li t0, -0xc1               # ~(A | D)
    amoand.d zero, t0, (t1)
    sfence.vma zero, zero
    j next
#endif

next:
    addi s7, s7, -1
    bnez s7, loop
#ifdef VM
    ecall                      # back to M-mode, physical addresses
    li a5, 0
    csrr t0, mscratch
    ld t0, 48(t0)
    beqz t0, fail              # the page faults must have happened
#endif

#ifdef IRQ
    csrci mstatus, 8
    csrw mie, zero
    csrr t0, mscratch
    ld t0, 32(t0)
    sd t0, 56(s1)
#else
    sd zero, 56(s1)
#endif
    li t0, 3
    sd t0, 8(s1)               # phase 3: every own doubleword holds what this hart wrote last
    li s3, 0
final:
    mv a0, s3
    call check_own
    addi s3, s3, 1
    li t0, 16
    bne s3, t0, final
    sd s8, 32(s1)
    sd s9, 48(s1)
    fence rw, rw
    call barrier
    li t0, 4
    sd t0, 8(s1)               # phase 4: hart 0 checks the counters
    bnez s0, done
    li t2, 0
    li t3, 0
    li t4, 0x80008000
    li t5, NCORES
    li a2, 0
3:  ld t0, 32(t4)
    add t2, t2, t0
    ld t0, 56(t4)
    add a2, a2, t0
    ld t0, 48(t4)
    add t3, t3, t0
    addi t4, t4, 64
    addi t5, t5, -1
    bnez t5, 3b
    ld t0, 256(s4)
    bne t0, t2, fail
    ld t0, 320(s4)
    bne t0, t3, fail
    ld t0, 384(s4)
    bne t0, a2, fail
#ifdef IRQ
    beqz a2, fail              # the timer must have interrupted
#endif
done:
    li t0, 1
    sd t0, 24(s1)
park:
    j park

#ifdef IRQ
# Set this hart's mtimecmp 400 to 4495 cycles ahead; uses t0-t2 and the generator in the save area
arm_timer:
    csrr t2, mscratch
    ld t0, 24(t2)
    li t1, 0x9e3779b97f4a7c15
    add t0, t0, t1
    sd t0, 24(t2)
    srli t0, t0, 52            # 0..4095
    addi t0, t0, 400
    li t1, MTIME
    ld t1, 0(t1)
    add t0, t0, t1
    csrr t1, mhartid
    slli t1, t1, 3
    li t2, MTIMECMP
    add t1, t1, t2
    sd t0, 0(t1)
    ret
#endif

#ifdef TRAPS
.balign 4
trap:
    csrrw sp, mscratch, sp
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    csrr t0, mcause
#ifdef VM
    li t1, 9
    beq t0, t1, trap_ecall
    li t1, 12
    beq t0, t1, trap_pf
    li t1, 13
    beq t0, t1, trap_pf
    li t1, 15
    beq t0, t1, trap_pf
#endif
    bgez t0, trap_fail         # another exception
#ifndef IRQ
    j trap_fail
#else
    sd ra, 40(sp)
    csrrw sp, mscratch, sp     # arm_timer reads mscratch
    call arm_timer
    csrrw sp, mscratch, sp
    ld ra, 40(sp)
    ld t0, 32(sp)
    addi t0, t0, 1
    sd t0, 32(sp)
    li t0, 0x80009180
    li t1, 1
    amoadd.d.aqrl zero, t1, (t0)
    li t0, POOL
    ld t0, 0(t0)
    j trap_ret
#endif
#ifdef VM
trap_ecall:
    li t1, 0x1800              # return to M-mode after the ecall
    csrs mstatus, t1
    csrr t1, mepc
    addi t1, t1, 4
    csrw mepc, t1
    j trap_ret
trap_pf:
    # Svade: set A, and D for a store, in the leaf of the faulting page (either alias)
    csrr t1, mstatus
    srli t1, t1, 11
    andi t1, t1, 3
    beqz t1, trap_fail         # from U-mode: the pages are not user pages, so the fault would repeat forever
    csrr t1, mtval
    srli t2, t1, 21
    addi t2, t2, -0x400        # 0x80000000 >> 21
    beqz t2, 1f
    addi t2, t2, -0x200        # the alias 0xc0000000
    bnez t2, trap_fail
1:  srli t1, t1, 12
    andi t1, t1, 511
    li t2, 16
    bgeu t1, t2, trap_fail     # outside the 64 KiB of RAM
    slli t1, t1, 3
    li t2, PT_L0
    add t1, t1, t2
    li t2, 0x40
    addi t0, t0, -15
    bnez t0, 2f
    li t2, 0xc0
2:  amoor.d zero, t2, (t1)
    sfence.vma zero, zero
    ld t0, 48(sp)
    addi t0, t0, 1
    sd t0, 48(sp)
#endif
trap_ret:
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    csrrw sp, mscratch, sp
    mret
trap_fail:
    csrrw sp, mscratch, sp
    j fail
#endif

#ifdef VM
# Hart 0, phase 1: Sv39 tables. Root: a 1 GiB identity leaf at 0 (CLINT), and the same L1 table for
# 0x80000000 and its alias 0xc0000000; L1: the leaf table for the first 2 MiB; leaves: the 16 pages
# of RAM, RWX, A and D clear
build_tables:
    li t0, PT_ROOT
    li t1, PT_L0 + 4096
1:  sd zero, 0(t0)
    addi t0, t0, 8
    bne t0, t1, 1b
    li t0, PT_ROOT
    li t1, 0xc7                # V R W A D
    sd t1, 0(t0)
    li t1, ((PT_L1 >> 12) << 10) | 1
    sd t1, 16(t0)
    sd t1, 24(t0)
    li t0, PT_L1
    li t1, ((PT_L0 >> 12) << 10) | 1
    sd t1, 0(t0)
    li t0, PT_L0
    li t1, ((0x80000000 >> 12) << 10) | 0xf
    li t2, 16
2:  sd t1, 0(t0)
    addi t0, t0, 8
    li t3, 1 << 10
    add t1, t1, t3
    addi t2, t2, -1
    bnez t2, 2b
    ret

.section .rodata
# pages op_pte picks from: code, slots, shared line, pool (four), stacks
pte_pages: .byte 0, 8, 9, 10, 11, 12, 13, 14
.section .text.init
#endif

# a0 = table entry (2*line + half) -> a0 = address of this hart's doubleword
slot_address:
    srli t0, a0, 1             # line 0..7
    andi t1, t0, 3
    slli t1, t1, 12            # four lines 4 KiB apart: one cache set
    srli t0, t0, 2
    slli t0, t0, 6             # two sets
    add t1, t1, t0
    andi t0, a0, 1
    slli t0, t0, 5             # half of the line
    add t1, t1, t0
    slli t0, s0, 3             # doubleword of this hart
    add t1, t1, t0
    li t0, POOL
    add a0, t0, t1
#ifdef VM
    beqz a5, 1f
    srli t0, s6, 40
    andi t0, t0, 1
    slli t0, t0, 30            # half the time through the alias 0xc0000000
    add a0, a0, t0
1:
#endif
    ret

# a0 = table entry: store a new tagged value to the own doubleword and record it
store_own:
    mv t6, ra
    mv a1, a0
    call slot_address
    addi s10, s10, 1
    addi t0, s0, 1
    slli t0, t0, 56
    or t0, t0, s10
    sd t0, 0(a0)
    slli t1, a1, 3
    add t1, t1, s2
    sd t0, 0(t1)
    mv ra, t6
    ret

# a0 = table entry: the own doubleword must hold the recorded value
check_own:
    mv t6, ra
    mv a1, a0
    call slot_address
    ld t0, 0(a0)
    slli t1, a1, 3
    add t1, t1, s2
    ld t1, 0(t1)
    bne t0, t1, fail
    mv ra, t6
    ret

# Sense-reversing barrier on 32(s4) (count) and 40(s4) (sense), as in atomics.S
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
    sd s7, 16(s1)              # iterations left
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
