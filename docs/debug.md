# JTAG debug port

Wally's SoC can include a debug port after the **RISC-V Debug Specification 1.0**: a JTAG Debug
Transport Module (DTM) and a Debug Module (DM) with **System Bus Access**. A debugger such as
OpenOCD reads and writes memory and peripherals over JTAG, holds the core in reset while it
loads a program, and resets the SoC.

The hart cannot halt yet. The core has no debug mode, so there are no abstract commands
(registers), no single-stepping and no breakpoints. GDB needs those, so for now OpenOCD drives
the port with `riscv dmi_read`/`riscv dmi_write`. The roadmap at the end describes the full
specification and trace.

## Enabling it

Set `DEBUG_SUPPORTED` to 1 in the configuration's `config.vh`; every base configuration
declares it 0. Two derivative configurations in `config/derivlist.txt` enable it:

- `debug_rv32imc`: `rv32imc` with RAM on the bus instead of IROM/DTIM, as in a chip, so that
  System Bus Access can load programs.
- `debug_rv64gc`: `rv64gc` with its caches and 64-bit bus.

`wallypipelinedsoc` gets four pins: inputs `TCK`, `TMS` and `TDI`, and output `TDO`. The inputs
default to 0 (IEEE 1800-2009 port defaults), so existing instances of the SoC need no change
when the port is unused. The TAP has no TRST pin: it resets with `reset_ext` and with TMS.

## What a debugger sees

| DMI address | Register | Implemented |
|---|---|---|
| 0x10 | `dmcontrol` | `dmactive`, `ndmreset`, `hartreset`, `ackhavereset`; `hartsel` reads 0 (one hart); `haltreq` and `resumereq` have no effect |
| 0x11 | `dmstatus` | version 3 (1.0), `authenticated`, `allrunning`/`allunavail` (the hart is in reset), `allhavereset`, `ndmresetpending`; never halted |
| 0x16 | `abstractcs` | `datacount` 0, `progbufsize` 0, `cmderr` |
| 0x17 | `command` | every command fails with `cmderr` 2 (not supported) |
| 0x38 | `sbcs` | `sbversion` 1, `sbasize` = `PA_BITS`, 8/16/32-bit accesses (and 64 with a 64-bit bus), `sbautoincrement`, `sbreadonaddr`, `sbreadondata`, `sbbusy`, `sbbusyerror`, `sberror` (2 bus error, 3 misaligned, 4 size not supported) |
| 0x39, 0x3A | `sbaddress0`, `sbaddress1` | the physical address |
| 0x3C, 0x3D | `sbdata0`, `sbdata1` | the data |

The DTM's `dtmcs` reports version 1 (0.13 and 1.0), `abits` 7 and `idle` 2. Its IDCODE is
0x00000001 (the `IDCODE` parameter of `dtm`).

- **hartreset** holds only the core in reset; the memories and peripherals keep working. A
  debugger loads a program into RAM through System Bus Access while the core is held. When it
  releases the core, the core starts at its reset vector.
- **ndmreset** resets the whole SoC except the DTM and DM, which only the power-on reset
  (`reset_ext`) resets.

## Structure

```
wallypipelinedsoc
├── core(s), multicore_memory_system   ──┐
├── debug (DEBUG_SUPPORTED)              │ AHB
│   ├── dtm (src/debug/dtm.sv)  TCK domain: TAP, dtmcs, dmi; DMI to the clk domain
│   ├── dm  (src/debug/dm.sv)   registers, resets, System Bus Access (AHB-Lite master)
│   └── ahbdebugarb (src/debug/ahbdebugarb.sv)   core + DM → uncore
└── uncore
```

- **DMI clock crossing.** An Update-DR of `dmi` registers the request in the TCK domain and
  flips a toggle. The system clock domain synchronizes the toggle, serves the request in one
  cycle and flips a response toggle back. A `dmi` scan before the response arrives returns
  busy (op 3), which stays set until `dmireset`, as the specification requires. TDO changes on
  the falling edge of TCK.
- **The arbiter adds no latency to the core.** The core owns the bus. When the DM wants it, the
  arbiter waits for a free cycle: no data phase left over and no new address phase from the
  core. It then gives the address phase to the DM and holds the core's `HREADY` low until the
  DM's transfer completes. This works because of how the core's bus masters behave
  (`busfsm`, `buscachefsm`, `ahbmulticore`):
  - they keep their address phase while `HREADY` is low;
  - they leave an idle cycle between accesses;
  - they issue an atomic's write right after its read, under `HMASTLOCK`.

  So a grant never splits a burst or a locked sequence.
- **A core held in reset still requests the bus.** It presents a NONSEQ fetch of its reset
  vector in every cycle, because `busfsm` stays in its address phase. The arbiter therefore
  ignores the core's requests while `hartreset` holds it.
- **System Bus Access is not coherent with the caches.** It reads and writes memory, not the
  hart's caches, as the specification allows; the debugger is responsible for coherence. A
  program loaded while the core is held is safe, because `hartreset` resets the caches. With a
  running core and a write-back D-cache, recent stores may not be in memory yet.

## Changes outside src/debug

To keep merges from upstream simple, the core is untouched. Outside `src/debug` the changes are:

- `src/wally/wallypipelinedsoc.sv`:
  - the four JTAG pins;
  - separate resets: power-on for the DM, `reset` = power-on or `ndmreset` for the SoC, and
    `reset` or `hartreset` for the cores;
  - the `debug` block between `multicore_memory_system` and the uncore.

  With `DEBUG_SUPPORTED` = 0 it is the same wiring as before.
- `src/cvw.sv`, `config/shared/parameter-defs.vh`, `config/*/config.vh`: the `DEBUG_SUPPORTED`
  parameter.
- `.TDO()` in the SoC instances that Verilator compiles with `-Wall`, where an unconnected output
  is an error (an output port cannot have a default): `testbench/wallywrapper.sv` (the lint top),
  `testbench/testbench.sv`, `linux/pmu/pmu_tb.sv`, `linux/smp/linux_tb.sv`,
  `tests/multicore/soc_tb.sv`, `tests/multicore/soc_clock_tb.sv`.
- `config/derivlist.txt`: `debug_rv32imc`, `debug_rv64gc`.

A synthesis tool that does not support input port defaults (IEEE 1800-2009 23.2.2.4) needs the
JTAG inputs tied to 0 in the instance. Verilator, Questa and slang support them.

For an ASIC or FPGA, TCK is a clock: give it its own `create_clock` and make it asynchronous to
the system clock (`set_clock_groups -asynchronous`). The DMI crossing only relies on the
two-flop synchronizers of the toggles.

## Tests

```bash
cd testbench/debug
make                  # debug_tb on debug_rv32imc and debug_rv64gc (Verilator)
make openocd          # OpenOCD on openocd_tb (debug_rv32imc) through remote_bitbang
```

- `debug_tb.sv` acts as the debugger itself, with TCK asynchronous to the clock. It checks:
  - the TAP (IDCODE, BYPASS, `dtmcs`), and `dmstatus` and `dmcontrol`;
  - abstract commands rejected;
  - System Bus Access: auto-increment, read-on-address and read-on-data, byte and halfword
    accesses, and the misalignment error;
  - loading a program under `hartreset` and releasing the core, which then drives the GPIOs
    and writes RAM;
  - reads and writes while the core fetches over the same bus;
  - `ndmreset`.
- `make openocd` builds `openocd_tb.sv` with `jtag_rbb.cpp`, a remote_bitbang server over
  DPI. It runs OpenOCD with `openocd.cfg` and `openocd_test.tcl`, which load the same program
  and read the GPIOs back. Tested with OpenOCD 0.12.0 (Ubuntu) and 0.12.0+dev (oss-cad-suite).
  `OPENOCD=<path>` selects the binary.

OpenOCD tries to halt the hart when it examines the target, and that fails ("Hart 0 failed to
halt during examine()"). The DMI commands work from then on. On a board, replace the adapter
lines of `openocd.cfg`, for example with `source [find interface/ftdi/c232hm.cfg]`.

## Roadmap

1. **Halt and resume:** debug mode in the core (`dcsr`, `dpc`, `dscratch`, the Sdext
   extension), halt on `haltreq`, `ebreak` or step, and `resumereq`. Abstract commands
   (Access Register for GPRs and CSRs, with `data0`/`data1`) or a program buffer, so that
   OpenOCD can examine the hart and GDB can connect.
2. **Triggers (Sdtrig):** `tselect`/`tdata1`-`tdata3`, address and data matches (`mcontrol6`),
   instruction count.
3. **Multiple harts:** `hartsel`, `hasel`, `haltsum`.
4. **Trace:** a trace buffer peripheral read through System Bus Access, then the RISC-V
   Efficient Trace (E-Trace) encoder.

The DTM, the DMI and System Bus Access stay as they are.
