# FreeRTOS on asic_soc_rv32imac

The kernel is the submodule `addins/FreeRTOS-Kernel` (V11.3.3, MIT), with its RISC-V port
(`portable/GCC/RISC-V`, the `RISCV_MTIME_CLINT_no_extensions` chip extension: no FPU) and `heap_4`.

    git submodule update --init addins/FreeRTOS-Kernel
    make                         # build/freertos.bin, 11 KiB of code and data; the image must fit in 32 KiB

| File | What it is |
|---|---|
| `FreeRTOSConfig.h` | 1 kHz tick from the CLINT (`mtime` counts the CPU clock, 18.432 MHz), 12 KiB heap, 128-word ISR stack, software timers, stack-overflow and assert hooks that print on the UART |
| `crt0.S` | the bootloader jumps here with `sp` at the top of the RAM: clears `.bss`, points `mtvec` at the port's trap handler (the port does not) and calls `main` |
| `link.ld` | the 32 KiB RAM at 0x80000000 as one flat image; `.bss` last (the bootloader does not clear it) |
| `main.c` | the demo: a producer (priority 2) sends 5 numbers through a queue every 5 ticks, the consumer (3) prints them under a UART mutex, a software timer counts 7-tick expiries, and a task of priority 1 that never blocks proves the tick preempts. After 5 messages it checks the tick count, the timer, the busy task and the stack and prints `FREERTOS OK` (or `FREERTOS FAIL <reason>`) |

The 32 KiB of RAM hold the code, the data, the heap (the tasks' stacks come from it) and the stacks,
so the heap is 12 KiB. The image is loaded like any program: in the SPI flash as `WALY`, its size and
`build/freertos.bin` (what `chipsim` does), or over the UART with GPIO[5] strapped (see `../boot.S`).
It uses the UART as the bootloader left it.

Not done: memory protection for the tasks (the chip has 16 PMP entries; this demo does not use them),
interrupt-driven peripherals, and the other tick rates.
