# Instruction trace (E-Trace)

Status: **the instruction trace interface, the encoder, the RAM sink and their control registers
are done and verified, on one hart and on several harts tracing at once** (steps 1 to 4 below).
This page records the decisions, so that the
implementation and its verification follow one plan. It is phase 5 of the debug work
(`docs/debug.md`).

The trace follows **Efficient Trace for RISC-V v2.0** (E-Trace). The encoder is small, and the
configuration is the one of the specification's reference flow (`itype3_basic`):

| Parameter | Value | Why |
|---|---|---|
| `itype_width_p` | 3 | itypes 0–6: no call/return stack, no implicit return |
| `iaddress_lsb_p` | 1 | 16-bit instruction alignment (the C extension) |
| Address mode | differential | full addresses only in sync packets |
| Resynchronization | every 2^(`resync-max`+4) packets | a counter of packets, as the reference model has; it lets a decoder pick up a trace in the middle |
| Retirement | single per cycle | Wally retires one instruction per cycle |
| Time, context, data trace | none | not needed for a first encoder |
| Optional format 0 | none | branch count and jump target cache are optional |

## Structure

```
core (privileged.sv)
└── etraceingress    retired instruction → one line of the instruction trace interface (ITI)
        │            itype, iaddr, iretire, ilastsize, cause, tval, priv
wallypipelinedsoc
└── etrace           (src/debug/etrace.sv) the control registers' bus window; for each hart:
    ├── etraceencoder   the three-instruction pipeline and the packet algorithm of the specification
    └── etracesink      a Trace RAM Sink: a packet queue and a RAM of TRACE_RAM_WORDS words
```

Only the ingress sits inside the core, as the debug unit does; it uses signals that `privileged`
already receives (`InstrOrigM`, `PCM`, `IClassM`, `CauseM`, the privilege mode, the trap
signals). The core gets output ports for the ITI line and `etrace` is instantiated by
`wallypipelinedsoc`, one per hart, so that the encoder can change without touching the core.
Everything is off unless `TRACE_SUPPORTED` is 1.

## The ingress: what a line means

One line per retired instruction, and one more for each exception or interrupt, in the order
the reference flow expects:

- **A retired instruction**: `iretire` 1, `iaddr` its address, `ilastsize` its length, and
  `itype`: 4/5 for a branch not taken/taken, 6 for an uninferable jump (`jalr`, `c.jr`,
  `c.jalr`, and `mret`/`sret`), 0 otherwise. Returns use 6 rather than 3 (exception or interrupt
  return) because the reference encoder sends the address after an itype 6 and not after a 3.
- **An exception**: `itype` 1, `iretire` 0, `iaddr` the faulting instruction, `cause` and `tval`
  as written to `xcause` and `xtval`. `ecall` and `ebreak` raise the exception and count as
  retired (the reference flow does the same).
- **An interrupt**: `itype` 2, `cause` its code.
- The line of a trap comes one cycle after the instruction that retires beside it, so that
  retirements and traps never share a cycle.
- The line leaves `etraceingress` from a register, one cycle after the cycle it describes. Its logic depends on `StallW`,
  which comes from the memory system, and the encoder follows: without the register the chip's longest path on an FPGA ran
  from the load/store address to the sink's queue.
- Tracing stops while the hart is in Debug Mode (`priv` 4, the encoder treats it as a halt).

## The encoder

`src/debug/etraceencoder.sv` is the flowchart of the specification's reference algorithm, written
to follow `encoder_model.py` step for step:

- **Pipeline**: the previous, current and next lines of the interface. A line shifts it in and the
  current instruction is encoded (the first line of a trace only fills it), so the encoder sends at
  most one packet per line, in the cycle the line arrives.
- **Decision**, in the order of the flowchart: after an exception, a trap packet (format 3.1, with
  `thaddr` 0 when the next instruction traps too) or a start packet; a start packet (3.0) for the
  first instruction, a privilege change or an overdue resynchronization; after an uninferable jump,
  an address packet, or a trap packet; an address packet (format 2, or 1 when branches are pending)
  for a resynchronization with branches pending, a retired exception, or before a trap or privilege
  change; a branch packet without address (format 1, `branches` 0) when the map holds 31 branches.
- **Fields**: start and trap packets carry the full address, the others the difference to the last
  address sent (in units of 2 bytes); `notify`, `updiscon` and `irreport` are sent as the reference
  sends them, XORed with the bit before, so that compression usually removes them.
- **On and off** (`TraceOn`): turning trace on sends a support packet (3.3, `ienable` 1,
  `qual_status` 0) and empties the pipeline; turning it off flushes it in three cycles: the last
  instruction is encoded, its address is sent, and a support packet with `ienable` 0 and
  `qual_status` 1 (ended, representative) ends the trace.
- **Compression and framing**: each packet loses the copies of its most significant bit, is
  sign-extended to whole bytes, and gets a header byte `{1'b0, msg_type 2, payload bytes}`, the
  byte stream of the reference (`te_inst_raw`). The output is one whole packet per cycle
  (`PacketValid`, `PacketLen`, `Packet`: header in byte 0, payload least significant byte first),
  at most 1 + 18 bytes (a 64-bit trap packet with `tval`).
- `ResyncMax`: a start packet at least every 2^(`ResyncMax`+4) packets (the reference's
  `resync-max`).

## Control registers and the RAM sink

The trace is controlled through the registers of the **RISC-V Trace Control Interface v1.0**
(ratified), so that trace tools that follow it need no customization. Each hart has a trace encoder
and a Trace RAM Sink in SRAM mode, at

| Address | Component | Registers |
|---|---|---|
| `TRACE_BASE + h*0x2000` | trace encoder of hart h | `trTeControl` (0x000), `trTeImpl` (0x004) |
| `TRACE_BASE + h*0x2000 + 0x1000` | RAM sink of hart h | `trRamControl` (0x000), `trRamImpl` (0x004), `trRamStartLow` (0x010, 0), `trRamLimitLow` (0x018), `trRamWPLow` (0x020), `trRamRPLow` (0x028), `trRamData` (0x040) |

`TRACE_BASE` is 0x04000000 (`config/shared/config-shared.vh`), a window that no region of any
configuration decodes. The registers are 32-bit and reached in two ways, as the specification
recommends: by an external debugger through **System Bus Access** (`src/debug/dmsba.sv` accepts
the window), and by the harts' loads and stores (the PMA, `src/mmu/pmachecker.sv`, allows 32-bit
accesses there: not cacheable, not idempotent, not executable). The uncore does not decode the
window, so it completes a transfer there as it completes any undecoded one (ready, OKAY, data 0);
`etrace` watches the address phase after the debug arbiter and supplies the read data. The uncore
is not changed.

- **`trTeControl`**: `trTeActive` (0 resets the encoder), `trTeEnable`, `trTeInstTracing` (the
  encoder traces while both are 1; clearing either flushes it), `trTeEmpty` (the flush is done),
  `trTeInstMode` 3 (baseline), `trTeInstSyncMode` 1 (count packets), `trTeInstSyncMax`
  (resynchronization every 2^(n+4) packets), `trTeInstStallOrOverflow` (a packet was dropped;
  write 1 to clear), `trTeFormat` 0 (E-Trace). `trTeImpl` reads 0x00020101: version 1.0, encoder,
  E-Trace 2.0.
- **The sink** stores the packets byte after byte in a circular buffer of `TRACE_RAM_WORDS`
  32-bit words (1024, 4 KiB: the shape of IHP's SRAM macro), first byte in the least significant
  byte. A queue of 4 packets absorbs bursts, and the RAM takes up to 4 bytes per cycle. A packet
  that finds the queue full is dropped and sets `trTeInstStallOrOverflow`; the hart is never
  stalled. `trRamWPLow` holds the next word and `trRamWrap`; with `trRamStopOnWrap` the sink stops
  when the buffer is full. Disabling the sink writes what is queued and fills the last word with
  idle bytes 0 (never a header, whose `msg_type` is 2). `trRamRPLow` and `trRamData` read the
  buffer back, while the sink is disabled and empty. `trRamImpl` reads 0x00001091: version 1.0,
  RAM sink, SRAM mode.
- **`TRACE_IN_RAM`** (default 0) puts the buffer in the last `TRACE_RAM_WORDS` words of the uncore RAM
  instead of a RAM of the sink's own, so that a SoC with a small RAM macro budget (the open-ASIC chip: 64 KiB
  in eight 8 KiB macros, the last of them the buffer) has the whole RAM when it does not trace. `ram_ahb`
  then splits the RAM into power-of-two parts (the chip's memory adapter banks only those) and gives the
  last part a second client: in a cycle in which a hart does not address that area, the port is the sink's
  (`TrGrant`); when a hart does, it goes first and the sink waits, and the queue absorbs the delay (a full
  queue drops a packet, as ever). Rules for software: while the sink is active (`trRamActive` 1), do not load
  from or store to the area (the chip: 0x8000E000-0x8000FFFF), which holds the trace, and while `trRamData`
  is read, no hart access to it may fall between two reads, or the word read is the hart's. One hart only
  (`NHARTS` 1), `XLEN` 32, no preload, `RAM_LATENCY` 0 (elaboration errors otherwise). `trace_inram_rv32gc`
  (`derivlist.txt`: 64 KiB RAM, 2048 words) runs the same program and check as `trace_rv32gc`
  (`make -C testbench/debug/etrace check` runs them all), and the chip's cocotb test `trace` runs through it.

Using it, in the order of the specification (offsets from hart h's block):

```
sink + 0x000 = 1            trRamActive
sink + 0x020 = 0            trRamWPLow: from word 0
sink + 0x000 = 3            trRamEnable
te   + 0x000 = 1            trTeActive
te   + 0x000 = 0x00010037   trTeEnable, trTeInstTracing (| n << 20 for trTeInstSyncMax)
   ... the hart runs ...
te   + 0x000 = 0x00010031   trTeEnable 0: flush; wait for trTeEmpty (bit 3)
sink + 0x000 = 1            trRamEnable 0; wait for trRamEmpty (bit 3)
read sink + 0x020           trRamWPLow: bytes of trace (bit 0: wrapped)
sink + 0x028 = 0, then read sink + 0x040 repeatedly
```

With OpenOCD the same writes and reads go through System Bus Access (`riscv set_mem_access
sysbus`, then `mww`/`mdw`); a program can do them itself, as `etracetest.S` does.

## Verification

Two checks, both in `testbench/debug/etrace/etracecheck.py`:

- **Our decoder**, `testbench/debug/etrace/etracedecode.py` (Python, standard library only),
  decodes the packets that the program reads back from the RAM sink (the testbench records the
  `trRamData` reads with `+EtracePackets=`) and reconstructs the program counters, which must
  equal the ones the hart retired. It decodes the configuration of Wally's encoder only (formats
  1, 2 and 3), reads the program from the ELF's executable sections itself, and follows the
  algorithm of the specification as the reference `decoder_model.py` writes it, step for step.
  It always runs, so the regression needs nothing outside the repository.
- **The reference flow** of the specification's repository (BSD-2-Clause, standard library only):
  `encoder_model.py` is the flowchart of the encoder as executable code, `decoder_model.py`
  reconstructs the program counters from the packets. It is **not** copied into this repository:
  it runs when `ETRACE_SPEC` names a clone, and is skipped otherwise.
  1. The testbench writes the ITI lines that the encoder takes in the reference's CSV format
     (`itype_0, cause, tval, priv, iaddr_0, context, ctype, iretire_0, ilastsize_0`).
  2. The reference `encoder_model.py` turns them into packets; Wally's packets must be **equal,
     byte for byte, packet by packet**.
  3. The reference `decoder_model.py` decodes them, with the program's disassembly; the program
     counters it reconstructs must equal the ones the core retired.

Our decoder was checked against the reference: both reconstruct the same program counters from
every trace of `make check` and `make check-harts` (32 and 64 bits, one and two harts,
`RESYNC_MAX` 0, 1 and 3). Flipping one random bit of a trace makes it fail in about 9 cases out of
10; the rest fall in fields that do not decide the path (a trap's `tval` and cause, the privilege,
the support packet's options, the unused bits of a branch map). Removing one packet makes it fail
for 111 of the 114 packets of a trace; the other three are the support packets at either end and
a resynchronization packet, which repeat what the decoder already knows.

## Running the check

```bash
make -C testbench/debug/etrace check                                # our decoder only
git clone https://github.com/riscv-non-isa/riscv-trace-spec.git ~/riscv-trace-spec   # once, outside Wally
make -C testbench/debug/etrace check ETRACE_SPEC=~/riscv-trace-spec   # and the reference flow
make -C testbench/debug/etrace check ETRACE_SPEC=~/riscv-trace-spec RESYNC_MAX=1   # another period
make -C testbench/debug/etrace check-harts ETRACE_SPEC=~/riscv-trace-spec           # two harts
python3 testbench/debug/etrace/etracedecode.py --packets <file> --elf <elf> --xlen 64 --print   # any trace
```

`regression-wally --nightly` runs `make check` and `make check-harts` (and `debug_tb`), with the
reference flow too when `ETRACE_SPEC` is set.

`make check` builds `etracetest.S` (`testbench/debug/etrace`) for RV32 and RV64, runs it on
`trace_rv32gc` (the trace without the Debug Module) and `debug_rv64gc` with `+EtraceCsv=` and
`+EtracePackets=`, and runs `etracecheck.py` on each trace. The program turns the trace on and off
through the control registers, fails if a packet was dropped or the buffer wrapped, and reads the
trace back through `trRamData`. It covers every case of the interface and every packet of the
encoder: branch maps of 1 to 31 branches, full maps sent without
address, `updiscon`, traps with `thaddr` 0 and 1, interrupts, privilege changes and periodic
resynchronization.

Result, with `RESYNC_MAX` 0, 1 and 3: the reference decoder reconstructs every retired
program counter (888 in 32 bits, 904 in 64), and the packets read back from the RAM sink are equal
to the reference's, byte for byte (with `RESYNC_MAX` 0: 123 packets, 463 bytes in 32 bits and 485
in 64, idle bytes included). `testbench/debug/debug_tb.sv` checks the System Bus Access path:
each hart's `trTeImpl`, `trRamImpl`, reset values and `trRamLimitLow`, then it traces hart 0
while the program runs, from enabling to reading back, as an external debugger does.
The program has no data in its code section, which the reference decoder cannot parse; that is
also why the ACT programs (which have some) are not used here.

`make check-harts` (`NHARTS`, 2 by default) does the same on SoCs with several harts,
`debug_rv32imc` and `debug_rv64gc_nocache` (several harts need a configuration without caches).
`testbench.sv` runs one hart, so `testbench/debug/etrace/etrace_tb.sv` instantiates the SoC with
`NCORES` harts, loads the program into RAM and waits for every hart's result. Every hart runs
`etracetest.S` at once, each with its own encoder and sink (`TRACE_BASE + hartid*0x2000`),
`mtimecmp` and interrupt flag; hart h goes h more times round the first loop, so that the harts'
traces differ and a trace routed to the wrong sink fails the check. `etracedump.sv` writes the
files of hart h with the suffix `.h<h>`, and `etracecheck.py` checks each hart.

Result of step 4, two harts: in 32 bits 877 and 879 program counters, in 64 bits 875 and 877
(the extra loop of hart 1), each hart's packets equal to the reference byte for byte (123 packets
each). `debug_tb.sv` also reads `trTeImpl` and `trRamImpl` of every hart through System Bus Access.

## Order of work

1. The ingress and the CSV dump, checked with the reference encoder and decoder (done).
2. The encoder, compared with the reference packet by packet (done).
3. The sink and its control registers, read through System Bus Access or by the harts (done).
4. Several harts traced at once, each against the reference (done).
5. Under an RTOS: Zephyr switches the trace on itself and the sink's buffer is read back over System Bus Access with the
   hart running and decoded against Zephyr's ELF (`asic/librelane/chip/zephyr/trace`, chipsim's `zephyr_trace`; done).

## To do

- **Restart after lost trace.** A packet that finds the sink's queue full is dropped and sets
  `trTeInstStallOrOverflow`, but the encoder does not then send a support packet with
  `qual_status` 2 (trace lost) and a new sync, as the specification recommends; a decoder cannot
  tell where the trace was broken. The test programs fail if it happens.
- **Optional E-Trace features** left out to keep the encoder small (table at the top): format 0
  (branch counts, jump target cache), the resynchronization timer (`trTeInstSyncMode` 2, cycles),
  implicit returns and the call stack, time, context and data trace, and other trace sinks
  (SMEM, SBA streaming, an external trace port). `trTeInstMode` is fixed at 3 (baseline).
- **The ASIC configuration** (`open-asic-flow`): the trace adds about 70,000 µm² for one RV32 hart
  in IHP SG13G2 (RAM aside), half of its flops in the 4-packet queue of the sink; `QUEUE` 2 and a
  smaller `TRACE_RAM_WORDS` are the knobs to measure.
