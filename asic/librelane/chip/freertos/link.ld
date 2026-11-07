/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * The 32 KiB RAM of asic_soc_rv32imac at 0x80000000: the image is loaded as a flat binary, so
 * everything is in one segment, with .bss last (the bootloader does not clear it). */
MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32K
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
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > RAM
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
