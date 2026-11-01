/* ddrinit: one image for the IROM and the DTIM of fpgaopensource.
 *
 * Both memories sit at 0x80000000 (64 KiB each): instruction fetches go to
 * the IROM and loads/stores to the DTIM.  The image is laid out contiguously
 * (code, then read-only and initialized data) and loaded into both memories,
 * so code runs from the IROM and data is read from the DTIM at the same
 * addresses.  The stack grows down from the top of the DTIM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  TIM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > TIM
  .rodata : ALIGN(8) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > TIM
  .data : ALIGN(8) {
    __global_pointer$ = . + 0x800;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(8);
  } > TIM
  _image_end = .;
  .bss (NOLOAD) : ALIGN(8) {
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(8);
    _bss_end = .;
  } > TIM
  _stack_top = ORIGIN(TIM) + LENGTH(TIM);
  ASSERT(_bss_end + 0x1000 <= _stack_top, "ddrinit: less than 4 KiB left for the stack")
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
