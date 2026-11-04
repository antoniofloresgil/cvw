// etracetest.S: a program for the instruction trace (docs/trace.md), for RV32 and RV64.
//
// It exercises every case of the instruction trace interface: branches taken and not taken
// (32 and 16 bits), inferable and uninferable jumps, calls and returns, ecall, ebreak, an illegal
// instruction, a load access fault, a trip to U-mode and back, and a timer interrupt.  The trap
// handler skips the instruction that traps and returns with mret.  Then it exercises the packets
// of the encoder that depend on counts: branch maps of 16 to 31 branches, full maps of 31 branches
// sent without an address, and the periodic resynchronization.
//
// The code section holds instructions only: the reference decoder of the E-Trace specification
// reads the program with objdump and cannot parse data in it.  It ends by writing 1 to tohost.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#if __riscv_xlen == 64
#define LREG ld
#define SREG sd
#else
#define LREG lw
#define SREG sw
#endif

#define MTIME    0x0200BFF8
#define MTIMECMP 0x02004000
#define UNMAPPED 0x70000000             // no region decodes it: a load access fault

    .section .text.init
    .global rvtest_entry_point
rvtest_entry_point:
    la      t0, trap_handler
    csrw    mtvec, t0
    csrw    mie, zero
    // Let U-mode access everything (an illegal instruction, which the handler skips, without PMP)
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x0F                    // TOR, RWX
    csrw    pmpcfg0, t0

    // Branches: a loop (taken, then not taken), and both outcomes of beq and bne
    li      t1, 5
1:  addi    t1, t1, -1
    bnez    t1, 1b
    beq     zero, zero, 2f
    nop
2:  bne     zero, zero, 3f
    nop
3:
    // 16-bit branches and jumps
    .option push
    .option rvc
    c.li    a0, 3
4:  c.addi  a0, -1
    c.bnez  a0, 4b
    c.beqz  a0, 5f
    c.nop
5:  c.j     6f
    c.nop
6:
    .option pop

    // Calls and returns: inferable (jal), uninferable (jalr, c.jalr, c.jr)
    jal     ra, leaf
    la      t0, leaf
    jalr    ra, 0(t0)
    .option push
    .option rvc
    c.jalr  t0
    la      t2, 7f
    c.jr    t2
    .option pop
    nop
7:
    // Exceptions: ecall, ebreak, an illegal instruction (a write to a read-only CSR), a load
    // access fault
    .option push
    .option norvc
    ecall
    ebreak
    .option pop
    csrw    mhartid, t0
    li      t0, UNMAPPED
    LREG    t1, 0(t0)

    // U-mode and back: mret to user code, which comes back with an ecall
    la      t0, user
    csrw    mepc, t0
    li      t0, 0x1800                  // mstatus.MPP = U
    csrc    mstatus, t0
    mret
after_user:

    // A timer interrupt while the hart waits for it
    li      t0, MTIME
    LREG    t1, 0(t0)
    addi    t1, t1, 100
    li      t0, MTIMECMP
#if __riscv_xlen == 64
    sd      t1, 0(t0)
#else
    sw      zero, 4(t0)
    sw      t1, 0(t0)
#endif
    li      t0, 0x80                    // mie.MTIE
    csrw    mie, t0
    csrsi   mstatus, 0x8                // mstatus.MIE
    la      t0, irq_seen
8:  LREG    t1, 0(t0)
    beqz    t1, 8b
    csrci   mstatus, 0x8

    // Branch maps of 16 to 31 branches: 20 branches, then the address packet that a jalr causes
    li      t1, 10
10: andi    t2, t1, 1
    beqz    t2, 11f                     // taken every other iteration
    nop
11: addi    t1, t1, -1
    bnez    t1, 10b
    la      t0, leaf
    jalr    ra, 0(t0)

    // Full branch maps: 200 branches without a discontinuity, sent 31 at a time without address
    li      t1, 100
12: andi    t2, t1, 1
    beqz    t2, 13f
    nop
13: addi    t1, t1, -1
    bnez    t1, 12b

    // Resynchronization: 40 calls through jalr, two address packets each, more than
    // 2^(resync-max+4) packets between sync packets
    li      t1, 40
    la      t0, leaf
14: jalr    ra, 0(t0)
    addi    t1, t1, -1
    bnez    t1, 14b

    // Done
    li      t0, 1
    la      t1, tohost
    SREG    t0, 0(t1)
9:  j       9b

leaf:
    addi    a1, a1, 1
    ret

user:
    addi    a2, a2, 1
    ecall                               // back to M-mode, at after_user

// Skip the instruction that trapped (16 or 32 bits), or end the interrupt; mret
    .align 2
trap_handler:
    csrrw   sp, mscratch, sp            // sp is free: this program uses no stack
    csrr    sp, mcause
    bltz    sp, interrupt
    li      sp, 8                       // ecall from U-mode: back to M-mode, at after_user
    csrr    tp, mcause
    bne     tp, sp, skip
    la      sp, after_user
    csrw    mepc, sp
    li      sp, 0x1800                  // mstatus.MPP = M
    csrs    mstatus, sp
    j       return
skip:
    csrr    sp, mepc
    lhu     tp, 0(sp)
    andi    tp, tp, 3
    addi    sp, sp, 2
    addi    tp, tp, -3
    bnez    tp, 1f                      // a 16-bit instruction
    addi    sp, sp, 2
1:  csrw    mepc, sp
    j       return
interrupt:
    li      sp, MTIMECMP                // no more timer interrupts
    li      tp, -1
    SREG    tp, 0(sp)
#if __riscv_xlen == 32
    sw      tp, 4(sp)
#endif
    la      sp, irq_seen
    li      tp, 1
    SREG    tp, 0(sp)
return:
    csrrw   sp, mscratch, sp
    mret

    .section .tohost, "aw", @progbits
    .align 6
    .global tohost
tohost: .dword 0
    .align 6
    .global fromhost
fromhost: .dword 0

    .data
    .align 3
irq_seen: .dword 0
