# JTAG debug port

Wally's SoC can include a debug port after the **RISC-V Debug Specification 1.0**. It has a
JTAG Debug Transport Module (DTM), an execution-based Debug Module (DM) and a Debug Mode in the
hart. A debugger such as OpenOCD, with GDB on top, can:

- halt the hart and resume it, and single-step it;
- read and write its registers and CSRs;
- set software breakpoints (`ebreak`), and hardware breakpoints and watchpoints (triggers);
- read and write memory and peripherals, through the hart or through System Bus Access;
- hold the core in reset while it loads a program, and reset the SoC.

It serves several harts, and each hart can have an E-Trace instruction trace with a RAM sink
(`TRACE_SUPPORTED`, `docs/trace.md`), read through System Bus Access or by the harts.

## Enabling it

Set `DEBUG_SUPPORTED` to 1 in the configuration's `config.vh`; every base configuration
declares it 0. Two derivative configurations in `config/derivlist.txt` enable it:

- `debug_rv32imc`: `rv32imc` with 1 MiB of RAM on the bus instead of IROM/DTIM, as in a chip,
  so that System Bus Access and GDB can load programs.
- `debug_rv64gc`: `rv64gc` with its caches and 64-bit bus.

`DEBUG_TRIGGERS` sets the number of triggers (0 in every base configuration, 4 in both
derivative configurations). Each trigger costs two address comparators of `XLEN` bits and its
registers, so a chip can keep only what it needs.

`wallypipelinedsoc` gets four pins: inputs `TCK`, `TMS` and `TDI`, and output `TDO`. The inputs
default to 0 (IEEE 1800-2009 port defaults), so existing instances of the SoC need no change
when the port is unused. The TAP has no TRST pin: it resets with `reset_ext` and with TMS.

## What a debugger sees

| DMI address | Register | Implemented |
|---|---|---|
| 0x04, 0x05 | `data0`, `data1` | abstract data; the hart sees them in memory at 0x380 |
| 0x10 | `dmcontrol` | `dmactive`, `ndmreset`, `hartsel` (up to 1024 harts), and, for the selected hart, `hartreset`, `haltreq`, `resumereq`, `ackhavereset`, `setresethaltreq`/`clrresethaltreq`; no `hasel` |
| 0x11 | `dmstatus` | version 3 (1.0), `authenticated`, `hasresethaltreq`, `impebreak`, and for the selected hart `halted`/`running`/`unavail`/`nonexistent`, `resumeack`, `havereset` (the `any` bits equal the `all` bits); `ndmresetpending` |
| 0x12 | `hartinfo` | `nscratch` 1, `dataaccess` 1, `datasize` 2, `dataaddr` 0x380 |
| 0x16 | `abstractcs` | `progbufsize` 8, `datacount` 2, `busy`, `cmderr` |
| 0x17 | `command` | Access Register (cmdtype 0) for GPRs, FPRs and CSRs, 32 or 64 bits, with `transfer`, `write`, `postexec`, `aarpostincrement`; other commands set `cmderr` 2 |
| 0x18 | `abstractauto` | `autoexecdata` (2 bits) and `autoexecprogbuf` (8 bits) |
| 0x20–0x27 | `progbuf0`–`progbuf7` | the program buffer; an `ebreak` follows it (`impebreak`) |
| 0x40 | `haltsum0` | bit *i*: hart 32·`hartsel[19:5]`+*i* is halted |
| 0x13 | `haltsum1` | bit *j*: some hart of the group of 32 *j* (in the 1024 around the selected hart) is halted; `haltsum2` and `haltsum3` are not needed with up to 1024 harts |
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
  - on a halt request (`dcsr.cause` 3);
  - on its first instruction after a reset, with `setresethaltreq` (`cause` 5);
  - after a single step (`cause` 4);
  - on an `ebreak` that `dcsr.ebreakm`, `ebreaks` or `ebreaku` sends to the debugger for the
    current privilege mode (`cause` 1).

  - when a trigger fires with `action` 1 (`cause` 2).

  When several apply, `cause` follows the specification's priority: trigger, `ebreak`,
  `resethaltreq`, halt request, step.

  It saves the PC in `dpc` and the privilege mode in `dcsr.prv`, changes to M-mode and jumps to
  the DM's ROM at 0x800. No other CSR changes.
- **In Debug Mode** interrupts are masked and `mstatus.MPRV` does not apply. An `ebreak` jumps
  back to 0x800. Any other exception jumps to 0x808 without changing any CSR.
- **dret** returns to `dpc` in the privilege mode of `dcsr.prv`. With `dcsr.step` set, the hart
  executes one instruction (or takes one trap, and then halts on the first instruction of the
  handler) and enters Debug Mode again. Interrupts stay masked during the step unless
  `dcsr.stepie` is set. A `wfi` that is stepped over does not wait: it is a `nop`.
- A halt request also ends a `wfi`: the `wfi` completes and the hart halts after it.

### Several harts

`wallypipelinedsoc` has one hart per `NCORES` (the multicore subsystem, `config/multicore`); the DM
serves all of them (`NHARTS` = `NCORES`, 1 to 1024), and every hart has its own Debug Mode and
triggers inside its `privileged` unit.

- **The DM keeps the state of each hart** (halted, `haltreq`, resume, go, reset, `havereset`,
  `resumeack`). `dmcontrol.hartsel` picks the hart that the `dmcontrol` bits and the abstract
  commands concern; `dmstatus` reports that hart (or `nonexistent`). `hasel` (halting several
  harts with one write) is not implemented.
- **Each hart has its own reset** (`hartreset`), and the bus requests of a hart that is held are
  silenced at its output in `wallypipelinedsoc`, so that the DM can use the bus while it loads a
  program. The other harts keep running.
- **One abstract command at a time**, on the selected hart. The data registers and the program
  buffer are shared, and the DM uses the hart's `mhartid` to give each hart its own `FLAGS` byte.
- A SoC with several harts needs a configuration without caches (the multicore subsystem's rule,
  `config/shared/multicore-config.vh`): `debug_rv32imc` and `debug_rv64gc_nocache` qualify,
  `debug_rv64gc` does not.

### Triggers (Sdtrig)

`src/debug/triggers.sv` implements `DEBUG_TRIGGERS` triggers. They are accessible from M-mode
and from Debug Mode:

| CSR | Implemented |
|---|---|
| `tselect` (0x7A0) | the trigger; a value beyond the last one is not written |
| `tdata1` (0x7A1) | the trigger's type and fields (below); a free trigger (after reset, or after writing 0 or an unsupported type) reads as `mcontrol6` with every field 0, which never fires (OpenOCD 0.12 skips triggers that read as type 15) |
| `tdata2` (0x7A2) | the address (`mcontrol`, `mcontrol6`) or the cause bitmask (`itrigger`, `etrigger`) |
| `tdata3` (0x7A3) | reads 0: no context matching |
| `tinfo` (0x7A4) | `version` 1, types 2–6 and 15 |

- **`mcontrol` (2) and `mcontrol6` (6)** match the address of an instruction (`execute`), a
  load or a store (atomics are both). Supported `match` values: equal (0), NAPOT (1), `>=` (2),
  `<` (3), not equal (8), not NAPOT (9). There is no data matching (`select` 0), no chaining
  and no size filter (`size` 0: any access).
- **`icount` (3)** counts instructions that retire or trap in the selected modes. When `count`
  reaches 0 it fires before the next instruction.
- **`itrigger` (4) and `etrigger` (5)** fire when the hart takes one of the interrupts or
  exceptions set in `tdata2`, before the first instruction of the handler.

A trigger fires before the instruction in the Memory stage, at the same boundaries as an
interrupt, so a matching load or store does not reach memory. If the instruction's bus access
has already started (an instruction fetch was under way when it reached the Memory stage), the
trigger fires right after the instruction retires instead. `mcontrol6` reports this in
`hit1:hit0`: 1 means it fired before the instruction, 3 right after it.

- **`action` 1** enters Debug Mode (`dcsr.cause` 2). It is legal only with `dmode` 1. Only Debug
  Mode can write a trigger with `dmode` 1.
- **`action` 0** raises a breakpoint exception, for software in M-mode:
  - It fires in M-mode only while `mstatus.MIE` is set. There is no `tcontrol`, and this keeps a
    trigger from firing again in its own handler.
  - `mtval` holds the instruction's pc, as for `ebreak`. For a load or store match the
    privileged specification asks for the data address; that would need a change in `csr.sv`.
  - `icount`, `itrigger` and `etrigger` support only `action` 1.
- Triggers never fire in Debug Mode.

## Structure

```
wallypipelinedsoc
├── core(s)                                     DebugHaltReq ← dm
│   └── privileged
│       ├── debugmode (src/debug/debugmode.sv)  dcsr, dpc, dscratch; entry, dret, step
│       └── triggers  (src/debug/triggers.sv)   tselect, tdata1-3, tinfo (DEBUG_TRIGGERS)
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

- **The ROM** (27 words; its source is in `dm.sv`) saves `s0` in `dscratch1`, then loops: it
  writes `HALTED` and reads the hart's `FLAGS` byte. Every report it writes (`HALTED`, `GOING`,
  `RESUMING`, `EXCEPTION`) carries the hart's `mhartid`, which is how the DM tells the harts
  apart.
  - On *go* it restores `s0`, writes `GOING` and jumps to `WHERETO`. The command or the program
    buffer ends with an `ebreak`, which brings the hart back to the ROM.
  - On *resume* it writes `RESUMING`, restores `s0` and executes `dret`.
- **Access Register** generates the instructions at 0x338:
  - a GPR or FPR: a load or store between the register and `data0` (and `data1` for 64 bits);
  - a CSR: it goes through `s0`, saved in `dscratch1` around the access.

  `postexec` jumps on to the program buffer instead of ending with `ebreak`.
- **The core's accesses to 0x0–0xFFF** go to the DM instead of the uncore: `ahbdebugarb`
  selects the DM's slave and returns its read data with no wait states. Only a hart in Debug
  Mode can reach them: outside it the PMA checker treats 0x0–0xFFF as unmapped, so a fetch, load
  or store there faults (access fault, `mtval` the address), and software cannot run the ROM or
  disturb the data registers and flags. Some execution-based DMs leave the region open (PULP's
  riscv-dbg); Wally closes it, as Ibex does.

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
  - a trigger with `action` 0 adds a breakpoint exception to `trap`'s inputs;
  - the debug CSRs are read in parallel with `csr` (their value is ORed into `CSRReadValW`) and
    clear its illegal-access flag; `dret` clears the illegal-instruction flag;
  - `mstatus.MPRV` is gated off in Debug Mode;
  - a halt request, or a step, ends a `wfi`.

  With `DEBUG_SUPPORTED` = 0 every debug signal is 0 and the wiring is as before.
- `src/wally/wallypipelinedcore.sv`: the `DebugHaltReq` and `DebugResetHaltReq` (the request
  is `resethaltreq`'s, for `dcsr.cause` 5) inputs, default 0, passed to `privileged`; and
  `DebugMode`, from `privileged` to the IFU and the LSU.
- `src/ifu/ifu.sv`, `src/lsu/lsu.sv`, `src/mmu/mmu.sv`: a `DebugMode` input passed on to the PMA
  checker.
- `src/mmu/pmachecker.sv`: with `DEBUG_SUPPORTED`, 0x0–0xFFF is a region that the hart may
  read, write and execute in Debug Mode only (not cacheable, idempotent), so that it can run the
  ROM.
- `src/wally/wallypipelinedsoc.sv`:
  - the four JTAG pins;
  - separate resets: power-on for the DM, `reset` = power-on or `ndmreset` for the SoC, and
    `reset` or `hartreset` for the cores;
  - the `debug` block between `multicore_memory_system` and the uncore, and the halt
    requests to the core.
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
make CONFIGS=debug_rv32imc NHARTS=2         # debug_tb on a SoC with two harts
make openocd NHARTS=2                       # and OpenOCD on it
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
  - a load from the debug memory outside Debug Mode: a load access fault;
  - the program buffer, alone and after a transfer (`postexec`), and an illegal instruction in
    it (`cmderr` 3);
  - single steps, also over a `wfi`; an `ebreak` with `dcsr.ebreakm`; `setresethaltreq`
    (`dcsr.cause` 4, 1 and 5, and `dpc`);
  - triggers: `tselect` and `tinfo`; execute and store address matches (the store does not
    reach the GPIO); `icount`; `etrigger`; a native trigger raising a breakpoint exception;
    WARL values of `tdata1`;
  - resuming (`resumeack`), a command while the hart runs (`cmderr` 4), an unsupported command
    (`cmderr` 2);
  - with `NHARTS` > 1: a hart that does not exist, halting, resuming and resetting one hart while
    the other runs, `haltsum0`, and the registers of each hart;
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
  - four that use OpenOCD commands 0.12 lacks (`RepeatReadTest`, and `EtriggerTest`, `IcountTest`
    and `ItriggerTest`, whose trigger types `debug_tb` checks itself);
  - two that need a faster simulation (`DownloadTest`, `InterruptTest`);
  - `Sv32Test` on the rv32imc targets, where GDB reads back a `satp` it failed to write;
  - `MulticoreRunAllHaltOne` on the two-hart targets: it gives the harts 1 s of wall-clock time.
    On rv32 both spend it in the timer handler, which outlasts the 256 ticks it rearms (the reason
    of `InterruptTest`); on rv64, two cacheless harts are still in the startup code.

  The targets also declare no memory sampling (`memory_sample` is not in OpenOCD 0.12).
- With OpenOCD 0.12 use riscv-tests before commit 6ca449c (for example 88ed3a9). From that
  commit on, the suite starts OpenOCD with the `gdb port` syntax of newer versions, which 0.12
  rejects.
- `debug_rv32imc_2harts.py` and `debug_rv64gc_nocache_2harts.py` are the targets with two harts
  (`wally-2.cfg`, like the suite's `spike-2.cfg`); build their simulations with
  `make -C $WALLY/testbench/debug openocd OPENOCD_CONFIG=<configuration> NHARTS=2`. They run
  the suite's multicore tests as well. `debug_rv64gc_nocache` is `rv64gc` without caches, since
  a SoC with several harts needs a cacheless memory system.
- The targets declare 4 hardware breakpoints (`instruction_hardware_breakpoint_count`), as
  `DEBUG_TRIGGERS` in both configurations.

## Roadmap

1. **Halt and resume** (done): Debug Mode, Access Register, the program buffer, GDB.
2. **Step and resets** (done): `dcsr.cause` 5 for `resethaltreq` and the priority of causes,
   `wfi` as a `nop` when stepped over.
3. **Triggers (Sdtrig)** (done): `mcontrol`, `mcontrol6` (address matches), `icount`,
   `itrigger`, `etrigger`.
4. **Multiple harts** (done, without `hasel`): `hartsel`, `haltsum0`/`haltsum1`, state per hart,
   one `FLAGS` byte per hart.
5. **Trace** (done, `docs/trace.md`): the E-Trace encoder of each hart and its RAM sink,
   controlled through the registers of the RISC-V Trace Control Interface and read through System
   Bus Access or by the harts.

The DTM, the DMI and System Bus Access stay as they are.

### To do

- **Run the whole official test suite with a newer OpenOCD.** OpenOCD 0.12 lacks `riscv
  etrigger/icount/itrigger set`, `repeat_read` and `memory_sample`, so `exclude.yaml` skips
  `EtriggerTest`, `IcountTest`, `ItriggerTest` and `RepeatReadTest`, and the targets declare no
  memory sampling. With a current OpenOCD (and the current riscv-tests, whose `gdb port`
  syntax 0.12 rejects) these tests could run; `debug_tb` covers the trigger types meanwhile.
