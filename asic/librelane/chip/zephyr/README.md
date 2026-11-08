# Zephyr on asic_soc_rv32imac

The kernel is the submodule `addins/zephyr` (v4.5.0, Apache-2.0), shallow. The chip is not a board of Zephyr's
tree: `module/` is an out-of-tree board and SoC (`wally_chip`, `wally_rv32imac`) that the Makefile passes with
`BOARD_ROOT`, `SOC_ROOT` and `DTS_ROOT`.

    git submodule update --init addins/zephyr
    python3 -m venv .zephyr-venv && .zephyr-venv/bin/pip install -r addins/zephyr/scripts/requirements-base.txt
    make                         # build/zephyr/zephyr.bin; west is not needed, CMake and Ninja are

`make` uses the RISC-V GCC of `$RISCV` (Zephyr's `cross-compile` toolchain variant, declared to support
thread-local storage, which the PMP userspace needs) and the virtual environment `ZEPHYR_VENV` (default
`$WALLY/.zephyr-venv`). `make chipsim` builds `build-sim`, the same image with `sim.overlay` (the testbench's UART
runs a bit every 16 clocks, divisor 1; the real board's is 115200 baud at 18.432 MHz, divisor 10).

| Path | What it is |
|---|---|
| `module/dts/riscv/wally/wally-rv32imac.dtsi` | the SoC from its `config.vh`: one hart (`riscv,cpu-intc`), the CLINT's machine timer at 18.432 MHz, the PLIC (18 sources), the UART (`ns16550`, PLIC source 10) and the RAM, **56 KiB** at 0x80000000 |
| `module/soc/wally/` | `SOC_WALLY_RV32IMAC` (Machine mode only kernel, no S mode), the PLIC as second-level interrupt controller (32 sources at most), `PMP_SLOTS` 16 |
| `module/boards/openhwgroup/wally_chip/` | the board: console on the UART, no XIP (the bootloader copies the image to the RAM, as for FreeRTOS), PMP |
| `app/` | the demo (`main.c`) and its `prj.conf` (`CONFIG_USERSPACE`) |

The RAM is 56 KiB, not 64: the last 8 KiB (0x8000E000-0x8000FFFF) are the instruction trace buffer's when
`TRACE_IN_RAM` is on, and a hart or a user thread must not touch them while the trace sink is active. Zephyr's linker
never places anything there and no user domain includes it. The image (flat binary: code, constants and initialised
data; `.bss` and the stacks are cleared and used in RAM) must fit in those 56 KiB with its `.bss`: the demo takes
about 46 KiB.

## Memory protection: User mode and memory domains

The kernel runs in Machine mode; with `CONFIG_USERSPACE` the application threads (`K_USER`) run in User mode and
every access they make goes through the 16 PMP entries, which Zephyr reloads at each context switch. The chip has no
virtual memory (no S mode, no MMU), so isolation is by physical regions:

- **global entries** (the same for every thread): the kernel's code and read-only data, the kernel's data and stacks
  as no access for User mode (no entry matches, and in User mode no match means a fault);
- **per thread**: its stack (2 entries as a TOR pair, 1 if aligned to a power of two) and the **partitions of its
  memory domain** (`k_mem_domain`, 1 or 2 entries each). Threads of different domains see different PMP contents,
  so a thread of domain A cannot read or write domain B's data, the kernel's, or the peripherals, and cannot
  execute data.
- Kernel objects (semaphores, queues, threads) are reachable from User mode only through system calls, which
  Zephyr validates (object permissions, buffers) before they run in Machine mode.

`app/main.c` shows it and `chipsim`'s `zephyr` test checks it in the RTL: two threads in two domains sleep in turn
and each keeps its data; then one user thread per case does a store or load outside its domain (domain B's data:
causes 7 and 5), a store to kernel data, kernel code and the UART (7), a jump into data (instruction access fault, 1),
a load from the RAM's trace area (5), and a system call on a kernel object it has no permission for (kernel oops, the
`ecall`). The kernel's `k_sys_fatal_error_handler` records `mcause` and returns, so Zephyr aborts only the faulting
thread and the demo goes on, ending with `ZEPHYR OK`.

The PMP of Wally has TOR, NA4 and NAPOT and a 4-byte grain, which is what Zephyr assumes by default
(`PMP_GRANULARITY` 4). With 16 entries a domain can hold only a few partitions at once: `arch_mem_domain_max_partitions_get()`
reports how many; a partition that does not fit makes only its thread fault, never the kernel.

Not done: peripherals other than the UART as Zephyr drivers (GPIO, SPI, I2C, timers), the PLIC-driven UART
interrupt mode, XIP from the SPI flash, and the trace buffer under Zephyr.
