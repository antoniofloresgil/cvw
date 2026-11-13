/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The first 55 KiB of the RAM of asic_soc_rv32imac_ai at 0x80000000 (the last 8 KiB are the trace buffer, and the 1 KiB before it, 0x8000DC00,
 * is the AI unit's input area: src/uncore/ai/ai_unit.sv): a flat image loaded by the
 * bootloader, with .bss last (the bootloader does not clear it; crt0.S does). */
MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 55K
}
ENTRY(_start)
SECTIONS
{
  .text : {
    *(.text.start)
    *(.text .text.*)
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
    . = ALIGN(4);
  } > RAM
  .data : {
    *(.data .data.*)
    *(.sdata .sdata.*)
    . = ALIGN(4);
  } > RAM
  .bss (NOLOAD) : {
    . = ALIGN(16);
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > RAM
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
