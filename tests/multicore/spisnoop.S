# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Uncached reads with side effects while the D-cache is snooped (coherent L1, ADR 0026).
# Hart 0 sends bytes through the SPI and reads back as many from the receive FIFO, which a read
# dequeues: a read performed twice, or an early one, finds the FIFO empty or leaves a byte over.
# Between its SPI accesses hart 0 writes a line that every other hart keeps writing, so its D-cache
# is snooped at any time, during the SPI loads and stores too. Slots and stacks match smoke.S.
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
    bnez s0, hammer

    # Hart 0: SPI at the fastest clock, receive watermark at BYTES-1 (ip.rxwm when count > rxmark)
    li a0, SPI
    sw zero, 0x00(a0)          # sckdiv
    li t0, BYTES-1
    sw t0, 0x54(a0)            # rxmark
    li s5, ROUNDS
round:
    li t0, 1
    sd t0, 8(s1)               # phase 1: sending
    li s6, BYTES
send:
    ld t1, 0(s4)
    addi t1, t1, 1
    sd t1, 0(s4)
    sw s6, 0x48(a0)            # txdata
    addi s6, s6, -1
    bnez s6, send
    li t0, 2
    sd t0, 8(s1)               # phase 2: waiting for the receive watermark
    li t3, 100000
wait_rx:
    ld t1, 0(s4)
    addi t1, t1, 1
    sd t1, 0(s4)
    lw t2, 0x74(a0)            # ip
    andi t2, t2, 2
    bnez t2, receive
    addi t3, t3, -1
    bnez t3, wait_rx
    j fail
receive:
    li t0, 3
    sd t0, 8(s1)               # phase 3: draining exactly BYTES entries
    li s6, BYTES
drain:
    ld t1, 0(s4)
    addi t1, t1, 1
    sd t1, 0(s4)
    lw t2, 0x4c(a0)            # rxdata: bit 31 is empty
    bltz t2, fail
    addi s6, s6, -1
    bnez s6, drain
    li t0, 4
    sd t0, 8(s1)               # phase 4: nothing left over
    lw t2, 0x4c(a0)
    bgez t2, fail
    addi s5, s5, -1
    bnez s5, round
    li t0, 1
    fence rw, rw
    sd t0, 64(s4)
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
