// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// A translated AMO must not turn the walker's PTE reads/writes into AMOs.
#include "WALLY-init-lib.h"
#include "WALLY-selfcheck.h"
main:
    SC_STRICT_TRAPS
    li t0, 1
    slli t0, t0, 61
    csrs menvcfg, t0          // Svadu hardware A/D updates
    la t0, pt_root
    srli t0, t0, 12
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma
    la s0, scratch
    li s1, 0x40000000
    add s2, s0, s1
    li a0, 1
    ecall                    // S mode, alias has A=D=0
    li t2, 5
    amoadd.d s4, t2, (s2)
    li s5, 7
    SC_CHECK_EQ s4, s5, 1
    ld s4, 0(s2)
    li s5, 12
    SC_CHECK_EQ s4, s5, 2
    lr.d s4, (s2)
    li s5, 33
    sc.d s6, s5, (s2)
    li s5, 0
    SC_CHECK_EQ s6, s5, 3
    ld s4, 0(s2)
    li s5, 33
    SC_CHECK_EQ s4, s5, 4
    li a0, 3
    ecall                    // M mode, inspect the updated PTE
    la t0, pt_root
    ld s4, 24(t0)
    li s5, 0x200000CF
    SC_CHECK_EQ s4, s5, 5
    SC_PASS
    j done
.data
.balign 4096
pt_root:
    .dword 0, 0
    .dword 0x200000CF         // identity mapped code/data, A=D=1
    .dword 0x2000000F         // alias, A=D=0
    .fill 508, 8, 0
.balign 64
scratch:
    .dword 7
