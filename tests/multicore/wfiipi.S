# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Wake-up latency of a wfi by a software interrupt (CLINT msip) sent by another hart, as Linux's IPIs do.
# Hart 0 waits in wfi; hart 1 lets a random 0..1023 cycles pass, reads mtime into the shared line and sets
# hart 0's msip. Hart 0 then reads mtime, clears its msip and checks that it woke within LIMIT ticks.
# Two modes, ROUNDS rounds each (an M-mode wfi with mstatus.MIE set is not tested: the interrupt can be
# taken just before the wfi, which then waits for good):
#   1  M-mode wfi with mstatus.MIE clear (the interrupt is pending and enabled in mie, not taken)
#   3  S-mode wfi with sstatus.SIE clear, as Linux idles under OpenSBI: msip traps to M, the handler sets
#      mip.SSIP and clears msip, mret returns after the wfi; S then sees sip.SSIP
# Other harts only take part in the handshake through the shared line at 0x80009000:
#   0: round requested by hart 0, 8: round in which hart 1 sent, 16: mtime at the send, 64: done.
# Slots and stacks match smoke.S; phase in 8(s1), round in 16(s1), worst latency in 32(s1).
.section .text.init
.globl _start
#ifndef ROUNDS
#define ROUNDS 50
#endif
#ifndef LIMIT
#define LIMIT 2000
#endif
.equ MTIME, 0x0200bff8
.equ MSIP0, 0x02000000
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
    li s4, 0x80009000
    li s5, MTIME
    li s6, MSIP0
    beqz s0, waiter
    li t0, 1
    bne s0, t0, other

    # Hart 1: answer each request after a random delay
    li s7, 0x9e3779b97f4a7c15
    li s8, 0                   # last round answered
1:  ld t1, 64(s4)
    bnez t1, other
    ld t0, 0(s4)
    beq t0, s8, 1b
    mv s8, t0
    slli t1, s7, 13
    xor s7, s7, t1
    srli t1, s7, 7
    xor s7, s7, t1
    slli t1, s7, 17
    xor s7, s7, t1
    srli t1, s7, 54            # 0..1023 cycles
2:  addi t1, t1, -1
    bgtz t1, 2b
    ld t1, 0(s5)
    sd t1, 16(s4)
    sd s8, 8(s4)
    fence rw, rw
    li t1, 1
    sw t1, 0(s6)               # msip of hart 0
    j 1b
other:
    li t0, 1
    sd t0, 24(s1)
park:
    j park

    # Hart 0
waiter:
    li s9, 0                   # round number, global over the modes
    li s10, 0                  # worst latency
    li a5, 1                   # mode
mode:
    sd a5, 8(s1)
    li t0, 3
    beq a5, t0, smode
    la t0, mtrap
    csrw mtvec, t0
    li t0, 8                   # MSIE
    csrw mie, t0
    li s7, ROUNDS
mround:
    call request
    wfi
    call measure
    addi s7, s7, -1
    bnez s7, mround
    csrw mie, zero
    li a5, 3
    j mode

smode:
    # S-mode wfi under an M-mode handler that turns msip into ssip, like OpenSBI
    la t0, mtrap
    csrw mtvec, t0
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x1f
    csrw pmpcfg0, t0
    li t0, 2                   # delegate the supervisor software interrupt
    csrw mideleg, t0
    li t0, 0xa                 # MSIE, SSIE
    csrw mie, t0
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x800               # MPP = S
    csrs mstatus, t0
    la t0, sstart
    csrw mepc, t0
    mret
sstart:
    csrci sstatus, 2           # SIE clear, as in Linux's idle loop
    li s7, ROUNDS
sround:
    call request
    wfi
    csrr t0, sip
    andi t0, t0, 2
    beqz t0, sround_wait       # woken before the handler ran: wait for ssip
sround_go:
    call measure_s
    csrci sip, 2
    addi s7, s7, -1
    bnez s7, sround
    ecall                      # back to M-mode to finish
sround_wait:
    csrr t0, sip
    andi t0, t0, 2
    beqz t0, sround_wait
    j sround_go

# Ask hart 1 for an msip: next round number into 0(s4)
request:
    addi s9, s9, 1
    sd s9, 16(s1)
    fence rw, rw
    sd s9, 0(s4)
    ret

# M-mode: latency from hart 1's send to now; clear msip (mode 1, where no handler did)
measure:
    ld t1, 0(s5)
    li t0, 0
    sw t0, 0(s6)
measure_check:
    ld t0, 8(s4)
    bne t0, s9, fail           # woke although hart 1 had not sent yet
    ld t0, 16(s4)
    sub t1, t1, t0
    bgeu s10, t1, 1f
    mv s10, t1
    sd s10, 32(s1)
1:  li t0, LIMIT
    bgeu t1, t0, fail
    ret
# S-mode: same check (mtime is readable through the identity of physical addresses: no translation)
measure_s:
    ld t1, 0(s5)
    j measure_check

.balign 4
mtrap:
    csrr t0, mcause
    li t1, 9
    beq t0, t1, finish         # ecall from S: done
    bgez t0, fail
    slli t0, t0, 1
    srli t0, t0, 1
    li t1, 3
    bne t0, t1, fail
    sw zero, 0(s6)             # clear msip
    li t0, 3
    bne a5, t0, 1f
    csrsi mip, 2               # mode 3: forward as a supervisor software interrupt
1:  mret

finish:
    li t0, 1
    sd t0, 64(s4)
    sd t0, 24(s1)
    j park

.balign 4
fail:
    csrr t1, mcause
    sd t1, 40(s1)
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
