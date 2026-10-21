// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// RV64 full-core delegation check: S-mode configures counter 3 without an SBI trap.
#include "WALLY-init-lib.h"
#include "WALLY-selfcheck.h"

main:
    csrw mie, zero
    csrci mstatus, 8
    li t0, -1
    csrw mcountinhibit, t0
    li t0, 9                       // delegate cycle and HPM counter 3
    csrw mcounteren, t0
    li t0, 1
    slli t0, t0, 60
    csrw menvcfg, t0               // CDE
    li a0, 1
    ecall                          // enter S-mode

    li t0, 0x43
    csrw 0x150, t0                 // siselect = counter 3
    li t0, 1
    csrw 0x152, t0                 // sireg2 = event selector
    li t0, 100
    csrw 0x151, t0                 // sireg = counter value
    csrr s0, 0x151
    csrr s1, 0x152
    csrr s2, 0x120                 // delegated inhibit bits only
    li t0, 0
    csrw 0x120, t0                 // clear inhibit for delegated counters
    li t0, 9
    csrw 0x120, t0                 // restore inhibit
    li t0, 100
    csrw 0x151, t0                 // exact final counter value
    li a0, 3
    ecall                          // return to M-mode

    li t0, 100
    SC_CHECK_EQ s0, t0, 1
    li t0, 1
    SC_CHECK_EQ s1, t0, 2
    li t0, 9
    SC_CHECK_EQ s2, t0, 3
    csrr s3, mhpmcounter3
    li t0, 100
    SC_CHECK_EQ s3, t0, 4
    csrr s4, mhpmevent3
    li t0, 1
    SC_CHECK_EQ s4, t0, 5
    csrr s5, mcountinhibit
    li t0, 13                      // counter 2 stayed inhibited
    and s5, s5, t0
    SC_CHECK_EQ s5, t0, 6
    SC_PASS
    j done
