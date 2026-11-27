# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# SPI transfers completed by the SPI interrupt through the PLIC, as Linux's spi-sifive driver does, with
# every hart enabled for the SPI source and claiming it in its machine context (coherent L1, ADR 0026).
# Hart 0 queues BYTES bytes (loopback), enables the receive-watermark interrupt and waits for the shared
# completion counter to move; whichever hart claims the interrupt reads ip, clears ie, counts the
# completion and completes the claim. A claim read that reaches the PLIC twice (the first marks the
# source in progress, the hart sees the second, 0) leaves the source in progress forever: the next
# transfer never completes and hart 0 times out in phase 2. An early completion finds the receive FIFO
# short in phase 3. Meanwhile all harts write a shared line and walk the pool, so their D-caches are
# snooped during the PLIC and SPI accesses; with -DIRQ machine timer interrupts cut in as well.
# Slots and stacks match smoke.S; 0x80009000: shared line (0), done flag (64), completions (128),
# claims of 0 (192, per hart 8 bytes).
.section .text.init
.globl _start
#ifndef ROUNDS
#define ROUNDS 1000
#endif
.equ SPI, 0x10040000
.equ PLIC, 0x0c000000
.equ SPI_ID, 6
.equ BYTES, 4
.equ POOL, 0x8000a000
.equ MTIME, 0x0200bff8
.equ MTIMECMP, 0x02004000
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
    addi t0, sp, -512          # trap save area: t0-t3, generator
    csrw mscratch, t0
    sd s0, 32(t0)
    # PLIC: priority 1 for the SPI (hart 0), this hart's machine context enabled with threshold 0
    li a1, PLIC
    bnez s0, 1f
    li t0, 1
    sw t0, 4*SPI_ID(a1)
1:  slli t0, s0, 8             # context 2*hart: enables at 0x2000 + 0x80*ctx
    li t1, 0x2000
    add t0, t0, t1
    add t0, t0, a1
    li t1, 1 << SPI_ID
    sw t1, 0(t0)
    slli t0, s0, 13            # threshold/claim at 0x200000 + 0x1000*ctx
    li t1, 0x200000
    add t0, t0, t1
    add s2, t0, a1             # s2: this hart's threshold register, claim at 4(s2)
    sw zero, 0(s2)
    la t0, trap
    csrw mtvec, t0
#ifdef IRQ
    call arm_timer
    li t0, 0x880               # MEIE, MTIE
#else
    li t0, 0x800               # MEIE
#endif
    csrs mie, t0
    csrsi mstatus, 8
    li s6, 0x9e3779b97f4a7c15  # pool walk
    bnez s0, hammer

    li a0, SPI
    sw zero, 0x00(a0)          # sckdiv: fastest clock
    li t0, BYTES-1
    sw t0, 0x54(a0)            # rxmark
    li s5, ROUNDS
round:
    li t0, 1
    sd t0, 8(s1)               # phase 1: queue the bytes
    li s7, BYTES
send:
    call touch
    sw s7, 0x48(a0)            # txdata
    addi s7, s7, -1
    bnez s7, send
    ld s8, 128(s4)             # completions so far
    li t0, 2
    sd t0, 8(s1)               # phase 2: interrupt enabled, wait for the completion
    li t0, 2
    sw t0, 0x70(a0)            # ie = rxwm
    li s9, 200000
wait:
    call touch
    ld t1, 128(s4)
    bne t1, s8, received
    addi s9, s9, -1
    bnez s9, wait
    j fail
received:
    li t0, 3
    sd t0, 8(s1)               # phase 3: exactly BYTES entries in the receive FIFO
    li s7, BYTES
drain:
    call touch
    lw t2, 0x4c(a0)            # rxdata: bit 31 is empty
    bltz t2, fail
    addi s7, s7, -1
    bnez s7, drain
    lw t2, 0x4c(a0)
    bgez t2, fail
    sd s5, 16(s1)              # rounds left
    addi s5, s5, -1
    bnez s5, round
    li t0, 1
    fence rw, rw
    sd t0, 64(s4)
    j done

hammer:
    li t0, 1
    sd t0, 8(s1)
1:  call touch
    ld t1, 64(s4)
    beqz t1, 1b
done:
    csrci mstatus, 8
    li t0, 1
    sd t0, 24(s1)
park:
    j park

# Write the shared line and read a pool line chosen by the generator; uses t0, t1
touch:
    ld t0, 0(s4)
    addi t0, t0, 1
    sd t0, 0(s4)
    slli t0, s6, 13
    xor s6, s6, t0
    srli t0, s6, 7
    xor s6, s6, t0
    slli t0, s6, 17
    xor s6, s6, t0
    srli t0, s6, 56
    slli t0, t0, 6             # one of 256 lines of 16 KiB
    li t1, POOL
    add t0, t0, t1
    ld t0, 0(t0)
    ret

#ifdef IRQ
# Set this hart's mtimecmp 200 to 1223 cycles ahead; uses t0-t2 and the generator in the save area
arm_timer:
    csrr t2, mscratch
    ld t0, 40(t2)
    li t1, 0x9e3779b97f4a7c15
    add t0, t0, t1
    sd t0, 40(t2)
    srli t0, t0, 54            # 0..1023
    addi t0, t0, 200
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

.balign 4
trap:
    csrrw sp, mscratch, sp
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    sd t3, 24(sp)
    csrr t0, mcause
    bgez t0, trap_fail
    slli t0, t0, 1
    srli t0, t0, 1
    li t1, 11
    beq t0, t1, trap_ext
#ifdef IRQ
    li t1, 7
    bne t0, t1, trap_fail
    sd ra, 48(sp)
    csrrw sp, mscratch, sp     # arm_timer reads mscratch
    call arm_timer
    csrrw sp, mscratch, sp
    ld ra, 48(sp)
    j trap_ret
#else
    j trap_fail
#endif
trap_ext:
    ld t0, 32(sp)              # hart
    slli t0, t0, 13
    li t1, PLIC + 0x200004
    add t1, t1, t0             # this hart's claim register
    lw t2, 0(t1)               # claim
    bnez t2, 1f
    ld t0, 32(sp)              # another hart claimed it first: count and return
    slli t0, t0, 3
    li t3, 0x80009000 + 192
    add t0, t0, t3
    li t3, 1
    amoadd.d zero, t3, (t0)
    j trap_ret
1:  li t3, SPI_ID
    bne t2, t3, trap_fail
    li t0, SPI
    lw t3, 0x74(t0)            # ip
    andi t3, t3, 2
    beqz t3, 2f                # spurious: complete only
    sw zero, 0x70(t0)          # ie = 0 until the next transfer
    li t0, 0x80009000 + 128
    li t3, 1
    amoadd.d.aqrl zero, t3, (t0)
2:  sw t2, 0(t1)               # complete
trap_ret:
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    csrrw sp, mscratch, sp
    mret
trap_fail:
    csrrw sp, mscratch, sp
    j fail

.balign 4
fail:
    csrr t1, mcause
    sd t1, 40(s1)
    li t0, 0xdead
    sd t0, 24(s1)
    j fail
