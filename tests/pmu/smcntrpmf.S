// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// RV64 full-core check: count U-mode work, but exclude machine trap/handler work.
#include "WALLY-init-lib.h"
#include "WALLY-selfcheck.h"

main:
    csrw mie, zero
    csrci mstatus, 8
    li t0, -1
    csrw mcountinhibit, t0
    csrw mcycle, zero
    csrw minstret, zero
    li t0, 0x6000000000000000 // MINH | SINH: count only U-mode
    csrw mcyclecfg, t0
    csrw minstretcfg, t0
    li t0, 5
    csrw mcounteren, t0   // permit cycle/instret reads in U-mode
    csrw mcountinhibit, zero
    csrr s0, mcycle
    csrr s1, minstret
    SC_CHECK_EQ s0, zero, 1
    SC_CHECK_EQ s1, zero, 2

    la t0, u_work
    csrw mepc, t0
    li t0, 0x1800
    csrc mstatus, t0      // MPP=U
    mret                  // retires in M, so minstret must not count it

u_work:
    csrr s0, cycle       // prove the user shadow is accessible
    csrr s1, instret
    addi t2, zero, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    li a0, 3              // WALLY init trap handler returns in M-mode
    ecall                 // synchronous exception does not retire

m_resume:
    csrr s2, mcycle
    csrr s3, minstret
    beqz s2, fail_cycle
    beqz s3, fail_instret
    csrr s4, mcycle
    csrr s5, minstret
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    csrr s6, mcycle
    csrr s7, minstret
    SC_CHECK_EQ s6, s4, 3
    SC_CHECK_EQ s7, s5, 4
    SC_PASS
    j done

fail_cycle:
    SC_FAIL 5
fail_instret:
    SC_FAIL 6
