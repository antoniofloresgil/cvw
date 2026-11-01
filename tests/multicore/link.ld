/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
    . = 0x80000000;
    .text : { *(.text.init) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    ASSERT(. < 0x80008000, "Program overlaps per-hart test slots")
}
