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

## Memory protection (static)

`crt0.S` locks three PMP entries before `main`: the code and constants (RAM start to `__text_end`) are
read and execute only, the rest of the RAM (data, `.bss`, the heap, every stack) read and write only. A
locked entry binds Machine mode too and stays until the next reset, so a task that writes to the code
or jumps into the heap or a stack takes a store (7) or instruction (1) access fault. The demo proves it
at the end: its last lines are `prot store data 0`, `prot store code 7`, `prot exec heap 1` and
`prot exec stack 1`, recovered by the exception handler (which finds the saved context through
`pxCurrentTCB`: `[0]` mepc, `[1]` mstatus, `[2]` ra). It costs 3 of the 16 entries, no RAM and about 100
bytes of code.

This does not isolate the tasks from each other: they run in Machine mode and share the data region.
Real isolation needs User-mode tasks and a port of our own, because the standard RISC-V port pushes the
context on the interrupted task's own stack in Machine mode: a User task that points `sp` at kernel
memory and takes the tick makes the kernel write there. The design would be: `mscratch` holds the task's
kernel stack while it runs in User mode and the trap entry swaps it with `sp` before saving anything;
the context (with the user `sp`) goes to the kernel stack, the user stack is a separate NAPOT region;
`traceTASK_SWITCHED_IN` reloads the task's PMP entries (its stack, its data, the code, the peripherals it
may use) at every switch; and the kernel calls a task makes (delay, queues, UART) are `ecall`s to a table
of handlers that validate the pointers and handles. The static entries above would then give the User
tasks the whole data region, so the NX-for-data entry would be dropped and the User entries put first.

Not done: that isolation, interrupt-driven peripherals, and the other tick rates.

The image loads through the UART bootloader (`chip/uart_load.py`) on the chip and on the FPGA build of the chip
([docs/fpga-chip.md](../../../../docs/fpga-chip.md)); its demo ran there to `FREERTOS OK` on 2026-11-10, with the PMP causes of the simulation (the switches all down).
