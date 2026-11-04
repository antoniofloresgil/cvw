# JTAG debug port

Wally's SoC can include a debug port after the **RISC-V Debug Specification 1.0**. It has a
JTAG Debug Transport Module (DTM), an execution-based Debug Module (DM) and a Debug Mode in the
hart. A debugger such as OpenOCD, with GDB on top, can:

- halt the hart and resume it, and single-step it;
- read and write its registers and CSRs;
- set software breakpoints (`ebreak`);
- read and write memory and peripherals, through the hart or through System Bus Access;
- hold the core in reset while it loads a program, and reset the SoC.

Hardware triggers, several harts and trace come in later phases (see the roadmap at the end).

## Enabling it

Set `DEBUG_SUPPORTED` to 1 in the configuration's `config.vh`; every base configuration
declares it 0. Two derivative configurations in `config/derivlist.txt` enable it:

- `debug_rv32imc`: `rv32imc` with 1 MiB of RAM on the bus instead of IROM/DTIM, as in a chip,
  so that System Bus Access and GDB can load programs.
- `debug_rv64gc`: `rv64gc` with its caches and 64-bit bus.

`wallypipelinedsoc` gets four pins: inputs `TCK`, `TMS` and `TDI`, and output `TDO`. The inputs
default to 0 (IEEE 1800-2009 port defaults), so existing instances of the SoC need no change
when the port is unused. The TAP has no TRST pin: it resets with `reset_ext` and with TMS.

## What a debugger sees

| DMI address | Register | Implemented |
|---|---|---|
| 0x04, 0x05 | `data0`, `data1` | abstract data; the hart sees them in memory at 0x380 |
| 0x10 | `dmcontrol` | `dmactive`, `ndmreset`, `hartreset`, `haltreq`, `resumereq`, `ackhavereset`, `setresethaltreq`/`clrresethaltreq`; `hartsel` reads 0 (one hart) |
| 0x11 | `dmstatus` | version 3 (1.0), `authenticated`, `hasresethaltreq`, `impebreak`, `allhalted`/`allrunning`/`allunavail`, `allresumeack`, `allhavereset`, `ndmresetpending` (the `any` bits equal the `all` bits) |
| 0x12 | `hartinfo` | `nscratch` 1, `dataaccess` 1, `datasize` 2, `dataaddr` 0x380 |
| 0x16 | `abstractcs` | `progbufsize` 8, `datacount` 2, `busy`, `cmderr` |
| 0x17 | `command` | Access Register (cmdtype 0) for GPRs, FPRs and CSRs, 32 or 64 bits, with `transfer`, `write`, `postexec`, `aarpostincrement`; other commands set `cmderr` 2 |
| 0x18 | `abstractauto` | `autoexecdata` (2 bits) and `autoexecprogbuf` (8 bits) |
| 0x20–0x27 | `progbuf0`–`progbuf7` | the program buffer; an `ebreak` follows it (`impebreak`) |
| 0x40 | `haltsum0` | bit 0: the hart is halted |
| 0x38 | `sbcs` | `sbversion` 1, `sbasize` = `PA_BITS`, 8/16/32-bit accesses (and 64 with a 64-bit bus), `sbautoincrement`, `sbreadonaddr`, `sbreadondata`, `sbbusy`, `sbbusyerror`, `sberror` (2 bus error, or an address that no region on the bus decodes, as the PMA checker sees it: the uncore itself completes those without an error; 3 misaligned; 4 size not supported) |
| 0x39, 0x3A | `sbaddress0`, `sbaddress1` | the physical address |
| 0x3C, 0x3D | `sbdata0`, `sbdata1` | the data |

`cmderr` reports 1 (busy) for a write to `command`, `abstractcs`, `abstractauto`, `data` or
`progbuf` while a command runs, 2 (not supported), 3 (exception: the hart took an exception
while it executed the command or the program buffer) and 4 (the hart is not halted).

The DTM's `dtmcs` reports version 1 (0.13 and 1.0), `abits` 7 and `idle` 2. Its IDCODE is
0x00000001 (the `IDCODE` parameter of `dtm`).

- **hartreset** holds only the core in reset; the memories and peripherals keep working. A
  debugger can load a program into RAM through System Bus Access while the core is held. When
  it releases the core, the core starts at its reset vector, or halts there first if
  `setresethaltreq` is set.
- **ndmreset** resets the whole SoC except the DTM and DM, which only the power-on reset
  (`reset_ext`) resets.

### The hart in Debug Mode

The debug CSRs exist only in Debug Mode; outside it they are illegal, as the specification
requires.

| CSR | Implemented |
|---|---|
| `dcsr` (0x7B0) | `debugver` 4, `ebreakm`, `ebreaks`, `ebreaku`, `stepie`, `cause`, `step`, `prv`; `stopcount`, `stoptime`, `mprven`, `nmip` and `v` read 0 |
| `dpc` (0x7B1) | the PC at which the hart halted, and to which `dret` returns |
| `dscratch0`, `dscratch1` (0x7B2, 0x7B3) | scratch registers; the DM's ROM uses `dscratch1` |

- **Entry.** The hart enters Debug Mode before the instruction in the Memory stage, which does
  not execute, at the same instruction boundaries as an interrupt. It enters:
  - on a halt request (`dcsr.cause` 3; `setresethaltreq` also reports 3);
  - after a single step (`cause` 4);
  - on an `ebreak` that `dcsr.ebreakm`, `ebreaks` or `ebreaku` sends to the debugger for the
    current privilege mode (`cause` 1).

  It saves the PC in `dpc` and the privilege mode in `dcsr.prv`, changes to M-mode and jumps to
  the DM's ROM at 0x800. No other CSR changes.
- **In Debug Mode** interrupts are masked and `mstatus.MPRV` does not apply. An `ebreak` jumps
  back to 0x800. Any other exception jumps to 0x808 without changing any CSR.
- **dret** returns to `dpc` in the privilege mode of `dcsr.prv`. With `dcsr.step` set, the hart
  executes one instruction (or takes one trap, and then halts on the first instruction of the
  handler) and enters Debug Mode again. Interrupts stay masked during the step unless
  `dcsr.stepie` is set.

## Structure

```
wallypipelinedsoc
├── core(s)                                     DebugHaltReq ← dm
│   └── privileged
│       └── debugmode (src/debug/debugmode.sv)  dcsr, dpc, dscratch; entry, dret, step
├── multicore_memory_system  ──┐
├── debug (DEBUG_SUPPORTED)    │ AHB
│   ├── dtm (src/debug/dtm.sv)    TCK domain: TAP, dtmcs, dmi; DMI to the clk domain
│   ├── dm  (src/debug/dm.sv)     DM registers, abstract commands, debug memory (AHB slave)
│   │   └── dmsba (src/debug/dmsba.sv)   System Bus Access (AHB-Lite master)
│   └── ahbdebugarb (src/debug/ahbdebugarb.sv)   core + DM → uncore; core → debug memory
└── uncore
```

### Execution-based Debug Module

As in PULP's `riscv-dbg`, the DM does not reach into the hart's registers. A halted hart
executes code from the DM's **debug memory**, an AHB slave at 0x0–0xFFF:

| Address | Content |
|---|---|
| 0x100 | `HALTED`: the ROM writes its hart ID here while the hart waits |
| 0x104 | `GOING`: the ROM acknowledges a command |
| 0x108 | `RESUMING`: the ROM acknowledges a resume |
| 0x10C | `EXCEPTION`: the command or the program buffer took an exception |
| 0x300 | `WHERETO`: a `jal` to the abstract command or to the program buffer |
| 0x338 | the abstract command: 8 instructions generated from `command` |
| 0x358 | the program buffer (8 instructions), then an `ebreak` at 0x378 |
| 0x380 | `data0`, `data1` |
| 0x400 | `FLAGS`: one byte per hart, bit 0 go, bit 1 resume |
| 0x800 | the ROM: halt entry 0x800, resume 0x804, exception entry 0x808 |

- **The ROM** (25 words; its source is in `dm.sv`) saves `s0` in `dscratch1`, then loops: it
  writes `HALTED` and reads the hart's `FLAGS` byte.
  - On *go* it restores `s0`, writes `GOING` and jumps to `WHERETO`. The command or the program
    buffer ends with an `ebreak`, which brings the hart back to the ROM.
  - On *resume* it writes `RESUMING`, restores `s0` and executes `dret`.
- **Access Register** generates the instructions at 0x338:
  - a GPR or FPR: a load or store between the register and `data0` (and `data1` for 64 bits);
  - a CSR: it goes through `s0`, saved in `dscratch1` around the access.

  `postexec` jumps on to the program buffer instead of ending with `ebreak`.
- **The core's accesses to 0x0–0xFFF** go to the DM instead of the uncore: `ahbdebugarb`
  selects the DM's slave and returns its read data with no wait states. Outside Debug Mode the
  same addresses are readable (as in other execution-based DMs), but the hart has no reason to
  touch them.

### Bus and clock domains

- **DMI clock crossing.** An Update-DR of `dmi` registers the request in the TCK domain and
  flips a toggle. The system clock domain synchronizes the toggle, serves the request in one
  cycle and flips a response toggle back. A `dmi` scan before the response arrives returns
  busy (op 3), which stays set until `dmireset`, as the specification requires. TDO changes on
  the falling edge of TCK.
- **The arbiter adds no latency to the core.** The core owns the bus. When System Bus Access
  wants it, the arbiter waits for a free cycle: no data phase left over and no new address phase
  from the core. It then gives the address phase to the DM and holds the core's `HREADY` low
  until the DM's transfer completes. This works because of how the core's bus masters behave
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
  running core and a write-back D-cache, recent stores may not be in memory yet. OpenOCD
  accesses memory through the halted hart (the Program Buffer) unless told otherwise, which is
  coherent.

## Changes outside src/debug

To keep merges from upstream simple, the core's own modules (`trap`, `privmode`, `privdec`,
`csr`, the pipeline) are unchanged. Outside `src/debug` the changes are:

- `src/privileged/privileged.sv` instantiates `debugmode` (with `DEBUG_SUPPORTED`) and steers
  the existing trap and return paths with its outputs:
  - entering Debug Mode is a trap that `privmode` sees as undelegated, to M-mode, and that the
    CSRs do not see (no `mepc`, `mcause` or `mstatus` update); its vector is the ROM;
  - `dret` is a return that `privmode` sees as an `mret` to `dcsr.prv`, to `dpc`;
  - `ebreak` to the debugger does not reach `trap`; interrupts are masked through `MIE_REGW`;
  - the debug CSRs are read in parallel with `csr` (their value is ORed into `CSRReadValW`) and
    clear its illegal-access flag; `dret` clears the illegal-instruction flag;
  - `mstatus.MPRV` is gated off in Debug Mode;
  - a halt request wakes a `wfi`.

  With `DEBUG_SUPPORTED` = 0 every debug signal is 0 and the wiring is as before.
- `src/wally/wallypipelinedcore.sv`: the `DebugHaltReq` input (default 0), passed to
  `privileged`.
- `src/mmu/pmachecker.sv`: with `DEBUG_SUPPORTED`, 0x0–0xFFF is a region that the hart may
  read, write and execute (not cacheable, idempotent), so that it can run the ROM.
- `src/wally/wallypipelinedsoc.sv`:
  - the four JTAG pins;
  - separate resets: power-on for the DM, `reset` = power-on or `ndmreset` for the SoC, and
    `reset` or `hartreset` for the cores;
  - the `debug` block between `multicore_memory_system` and the uncore, and `DebugHaltReq`.
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
make                                        # debug_tb on debug_rv32imc and debug_rv64gc (Verilator)
make openocd                                # OpenOCD on openocd_tb (debug_rv32imc) through remote_bitbang
make openocd OPENOCD_CONFIG=debug_rv64gc    # the same on debug_rv64gc
```

- `debug_tb.sv` acts as the debugger itself, with TCK asynchronous to the clock. It checks:
  - the TAP (IDCODE, BYPASS, `dtmcs`), `dmstatus`, `dmcontrol`, `hartinfo`, `abstractcs`;
  - System Bus Access: auto-increment, read-on-address and read-on-data, byte and halfword
    accesses, and the misalignment and bad-address errors;
  - loading a program under `hartreset` and releasing the core, which then drives the GPIOs
    and writes RAM;
  - reads and writes while the core fetches over the same bus;
  - halting the running program: `dpc`, `dcsr` (`cause`, `prv`);
  - Access Register: reading and writing GPRs (including `s0`, which the ROM borrows) and
    `mhartid`, and `cmderr` 3 for a CSR that does not exist;
  - the program buffer, alone and after a transfer (`postexec`), and an illegal instruction in
    it (`cmderr` 3);
  - resuming (`resumeack`), a command while the hart runs (`cmderr` 4), an unsupported command
    (`cmderr` 2);
  - `ndmreset`.
- `make openocd` builds `openocd_tb.sv` with `jtag_rbb.cpp`, a remote_bitbang server over DPI
  (`+RBB_PORT=0` picks a free port and prints it). It runs OpenOCD with `openocd.cfg` and
  `openocd_test.tcl`, which examine the hart, load a program with System Bus Access and read the
  GPIOs back. Tested with OpenOCD 0.12.0 (Ubuntu) and 0.12.0+dev (oss-cad-suite).
  `OPENOCD=<path>` selects the binary.

Connect GDB to a simulation by hand:

```bash
$WALLY/sim/verilator/wkdir/debug/openocd-debug_rv32imc/Vopenocd_tb +RBB_PORT=9823 &
openocd -f testbench/debug/openocd.cfg      # GDB server on port 3333
riscv64-unknown-elf-gdb prog.elf -ex "target extended-remote :3333" -ex load
```

On a board, replace the adapter lines of `openocd.cfg`, for example with
`source [find interface/ftdi/c232hm.cfg]`.

### The official debug tests (riscv-tests/debug)

`testbench/debug/riscv-tests/` holds targets for the debug test suite of
[riscv-tests](https://github.com/riscv-software-src/riscv-tests) (`debug/gdbserver.py`), which
drives OpenOCD and GDB against the simulation. `wallysim.py` launches `Vopenocd_tb`, and
`wally.cfg` is the OpenOCD configuration, after the suite's `spike-1.cfg`.

```bash
make -C $WALLY/testbench/debug openocd OPENOCD_CONFIG=debug_rv32imc   # build the simulation
cd riscv-tests/debug          # with its env submodule (git submodule update --init env)
LC_ALL=C ./gdbserver.py --exclude-tests $WALLY/testbench/debug/riscv-tests/exclude.yaml \
    $WALLY/testbench/debug/riscv-tests/debug_rv32imc.py
```

- `LC_ALL=C`: the suite parses GDB's messages in English.
- `exclude.yaml` lists the tests skipped, each with its reason:
  - the trigger tests that the suite runs whatever the target declares (Wally has no triggers
    yet);
  - two that use OpenOCD commands 0.12 lacks;
  - two that need a faster simulation (`DownloadTest`, `InterruptTest`);
  - `Sv32Test` on rv32imc, where GDB reads back a `satp` it failed to write.

  The targets also declare no `mcontrol6` and no memory sampling.
- With OpenOCD 0.12 use riscv-tests before commit 6ca449c (for example 88ed3a9). From that
  commit on, the suite starts OpenOCD with the `gdb port` syntax of newer versions, which 0.12
  rejects.
- The targets declare no hardware triggers (`support_mcontrol`, `instruction_hardware_breakpoint_count`
  0), so trigger tests report `not_applicable`.

## Roadmap

1. **Halt and resume** (done): Debug Mode, Access Register, the program buffer, GDB.
2. **Step and resets:** `dcsr.cause` 5 for `resethaltreq`, step refinements.
3. **Triggers (Sdtrig):** `tselect`/`tdata1`-`tdata3`, address and data matches (`mcontrol6`),
   instruction count.
4. **Multiple harts:** `hartsel`, `hasel`, `haltsum`, one `FLAGS` byte per hart.
5. **Trace:** a trace buffer peripheral read through System Bus Access, then the RISC-V
   Efficient Trace (E-Trace) encoder.

The DTM, the DMI and System Bus Access stay as they are.
