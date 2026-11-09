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
| `module/dts/riscv/wally/wally-rv32imac.dtsi` | the SoC from its `config.vh`: one hart (`riscv,cpu-intc`), the CLINT's machine timer at 18.432 MHz, the PLIC (18 sources), the UART (`ns16550`, PLIC source 10), the MCU peripherals and the RAM, **56 KiB** at 0x80000000 |
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

## Peripheral drivers

Six demo images, each with a `chipsim` test that plays the other side on the pads (`make chipsim` builds them with
`sim.overlay`):

| App | Driver | What the test checks |
|---|---|---|
| `app` | (the PMP demo above) | threads isolated by memory domains |
| `periph` | UART (`ns16550`, polled), GPIO (`wally,gpio`), SPI (`sifive,spi0`), PWM (`sifive,pwm0`), pinctrl (`sifive,pinctrl`) | three letters echoed, GPIO4 read and GPIO5 driven, three edge interrupts and a level interrupt on GPIO4, the flash's first bytes read over SPI, the duty cycles on GPIO1 and GPIO2 |
| `uart_irq` | UART in interrupt mode | the PLIC's source 10 reaches the callback and wakes the main thread |
| `mcu` | I2C (`wally,i2c`, interrupt-driven), watchdog (`wally,wdt`), the two drivers of `module/drivers/` | a write and a read with an I2C device at 0x50, a NACK from 0x51, and the chip reset the watchdog causes |
| `trace` | the instruction trace (E-Trace, `docs/trace.md`) switched on by the kernel itself | the packets in the RAM sink decoded against Zephyr's ELF: the workload, the semaphore calls, six context switches and the timer's interrupt handler |
| `timer` | the MCU timer as a Counter with capture (`wally,timer`) and as a PWM (`wally,timer-pwm`), the RTC (`wally,rtc`) | the top value, four kinds of alarm, edges captured from GPIO2 (rising, then both), the duty cycles on GPIO0 and GPIO1, the RTC's time and an alarm that wakes the idle thread |

The FE310-compatible blocks (SPI, PWM, the IOF pin muxing) use Zephyr's own SiFive drivers: the SoC only provides
`SIFIVE_PERIPHERAL_CLOCK_FREQUENCY` (`soc.h`), the pin state type (`pinctrl_soc.h`) and the devicetree nodes. The I2C
master and the two-stage watchdog are the chip's own (`src/uncore/mcu/`) and have drivers here: the I2C one is interrupt-driven (it polls if its node has no `interrupts`),
the watchdog supports only the reset action (the first timeout is half of Zephyr's window, the second resets), and it
cannot be disabled once on, as the hardware cannot.

Things that are not obvious:

- **GPIO: one interrupt line for eight pins.** The chip raises PLIC source 3 for any pin with a pending condition, but
  Zephyr's `sifive,gpio0` driver expects one line per pin, so the GPIO is `wally,gpio` (`module/drivers/gpio_wally.c`):
  the same registers, one handler that reads which pins are pending and runs their callbacks once. Edge and level
  interrupts work on every pin; a level interrupt fires again at once while the level holds, so the callback disables
  it (as with any controller) and the interrupt wakes a `wfi`.
- **I2C by interrupt.** With `interrupts` in the node (PLIC source 17) `wally,i2c` starts a command and sleeps on a
  semaphore that the controller's interrupt gives when the command finishes; without the property it polls. A mutex
  serialises the threads, and a command that does not finish in 100 ms returns `-ETIMEDOUT`.
- **PWM polarity.** The PWM follows the SiFive FU540: the output is high from the compare match to the end of the period
  and Zephyr's driver writes the pulse into the comparator, so a pulse of 25 % gives a pad that is high 75 % of the
  time. Channel 0 sets the period and channels 1-3 are on GPIO1-3. The pins must also be outputs (`gpio_pin_configure`):
  for IOF0 the output enable is still the GPIO's.
- **Timer: one counter, four channels.** `wally,timer` implements the Counter API (start/stop, `counter_set_top_value()`
  with a callback at each wrap, one alarm per channel, and `counter_capture_configure()`/`counter_enable_capture()`
  with rising, falling or both edges, single shot or continuous) on GPIO0-3 (IOF1). Its child node `wally,timer-pwm`
  is the PWM API on the same channels: the output is high while the counter is below the pulse, the period is the top
  value plus one and is the same for the four channels, `PWM_POLARITY_INVERTED` inverts one channel. They share the
  counter and the channels, so a channel serves one use at a time and the period or top value can only change while no
  other channel is in use (`-EBUSY`); `counter_stop()` stops the PWM. Only one of `pwm0` (the FU540 PWM, IOF0 on
  GPIO1-3) and `timer0_pwm` can be enabled, since both set the pads' alternate function: `timer/app.overlay` does it.
  A channel that is not a capture drives its pad whenever the PWM's pin state is applied, also as an alarm. An alarm
  late by the time it is set returns `-ETIME`, or expires at once with `COUNTER_ALARM_CFG_EXPIRE_WHEN_LATE`; the
  counter capture API is experimental in Zephyr 4.5 (`COUNTER_CAPTURE` selects `EXPERIMENTAL`). The capture register
  is read in the interrupt and the next edge overwrites it, so edges closer than the interrupt's latency (several hundred
  clocks) are lost or read late; the capture does not report which edge it was.
- **RTC.** `wally,rtc` implements the RTC API on a counter of seconds since 1970 that starts at 0 on every reset
  (set the time first). Its one alarm matches the whole counter, so `rtc_alarm_set_time()` takes a full mask (second to
  year) and refuses an alarm in the past (`-EINVAL`); the alarm interrupt (PLIC source 18) wakes a `wfi`. The chip's
  periodic wake-up (`PERIOD`) has no place in the RTC API and is not used. `tick-frequency` in the devicetree sets the
  ticks per second (1 on a board; `sim.overlay` makes it 1000 to see seconds go by in a short simulation).
- **UART callback.** `uart_irq_update()` refreshes the cached IIR that `uart_irq_is_pending()` reads, so call it in
  every turn of the loop of the callback; once only, a pending interrupt makes the loop endless inside the ISR (the
  kernel stays in `nested = 1` and never reschedules).
- **Pins.** `CONFIG_PINCTRL` is on in the board; the SPI has an empty pin state because its pads are dedicated.
- **Without west**, CMake reads Zephyr modules only from `ZEPHYR_MODULES`, which the Makefile sets to `module/`; its
  `zephyr/module.yml` supplies the board, SoC and devicetree roots and the drivers' CMake and Kconfig.

## Instruction trace

`trace/` switches the chip's E-Trace encoder on from the kernel: the hart reaches the Trace Control Interface registers
(`TRACE_BASE` 0x04000000, `docs/trace.md`) with ordinary loads and stores, in the order the specification gives (RAM sink
active and enabled, write pointer 0, encoder active, then trace on). It traces `traced_work()`, in which a thread of higher
priority is woken three times (six context switches) and the main thread sleeps 1 ms (the machine timer's interrupt),
switches the encoder off, waits for it and the sink to empty (`trTeEmpty`, `trRamEmpty`) and checks that no packet was
dropped (`trTeInstStallOrOverflow`). Do not print while tracing: the UART loops would overflow the sink. The sink's buffer is the
last 8 KiB of the RAM, outside Zephyr's 56 KiB, so the kernel never touches it. `chipsim`'s `zephyr_trace` test reads it
over JTAG System Bus Access **with the hart running** (it sleeps in `wfi`) and decodes it with
`testbench/debug/etrace/etracedecode.py` against `build-trace-sim/zephyr/zephyr.elf`: 988 bytes decode into 5,952
instructions that pass through `traced_work`, `z_impl_k_sem_give`/`z_impl_k_sem_take`, `z_riscv_switch` (at least six
times) and `timer_isr` after the third round trip. The image does not use `CONFIG_USERSPACE`; access to the registers
under the PMP of a user-mode image has not been tried.

## On the FPGA

The same images run on the chip built for the Nexys Video ([docs/fpga-chip.md](../../../../docs/fpga-chip.md)): its clock is
18.4375 MHz, 0.03 % from the 18.432 MHz of the devicetree, so no overlay is needed, and `chip/uart_load.py` loads
`build/zephyr/zephyr.bin` through the bootloader. The demos that need something at the pads (the I2C device, the SPI
flash, an edge for the capture) have nothing there on the board. It has not been run yet.

Not done: XIP from the SPI flash, which needs a hardware block the chip does not have (a memory-mapped flash reader,
ADR 0022 lists it as optional by area).
