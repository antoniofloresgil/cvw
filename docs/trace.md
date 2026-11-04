# Instruction trace (E-Trace)

Status: **the instruction trace interface and the encoder are done and verified** (steps 1 and 2
below); the sink and the control registers are to do. This page records the decisions, so that the
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
etrace (src/debug/trace)     per hart, outside the core
├── etrace_encoder   the three-instruction pipeline and the packet algorithm of the specification
└── sink             a RAM, read through System Bus Access, with the control registers
```

Until the sink exists (step 3), `testbench.sv` instantiates the encoder on hart 0 and turns the
trace on while a test runs (`STATE_RUN_TEST`); step 3 moves it into `wallypipelinedsoc` with the
control registers.

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

## Verification

The specification's repository has a **reference flow in Python** (BSD-2-Clause, standard
library only): `encoder_model.py` is the flowchart of the algorithm as executable code,
`decoder_model.py` reconstructs the program counters from the packets, and `compare_te_inst.py`
compares two packet streams. It is **not** copied into this repository: a clone is used from the
path in an environment variable, and the checks are skipped when it is missing.

1. The testbench writes the ITI lines of a run in the reference's CSV format
   (`itype_0, cause, tval, priv, iaddr_0, context, ctype, iretire_0, ilastsize_0`).
2. The reference `encoder_model.py` turns them into packets; the RTL packets (dumped with
   `+EtracePackets=`, one per line in hex bytes) must be **equal, byte for byte, packet by
   packet**.
3. The reference `decoder_model.py` decodes the RTL packets, with the program's disassembly; the
   program counters it reconstructs must equal the ones the core retired.

A decoder of our own in Python (no dependency) checks step 3 in the regression when the clone is
not available.

## Running the check

```bash
git clone https://github.com/riscv-non-isa/riscv-trace-spec.git ~/riscv-trace-spec   # once, outside Wally
make -C testbench/debug/etrace check ETRACE_SPEC=~/riscv-trace-spec
make -C testbench/debug/etrace check ETRACE_SPEC=~/riscv-trace-spec RESYNC_MAX=1   # another period
```

`make check` builds `etracetest.S` (`testbench/debug/etrace`) for RV32 and RV64, runs it on
`trace_rv32gc` (the trace without the Debug Module) and `debug_rv64gc` with `+EtraceCsv=` and
`+EtracePackets=`, and runs `etracecheck.py` on each trace. The program covers every case of the
interface and every packet of the encoder: branch maps of 1 to 31 branches, full maps sent without
address, `updiscon`, traps with `thaddr` 0 and 1, interrupts, privilege changes and periodic
resynchronization.

Result of step 2, with `RESYNC_MAX` 0, 1 and 3: the reference decoder reconstructs every retired
program counter (890 in 32 bits, 902 in 64), and Wally's packets are equal to the reference's,
byte for byte (with `RESYNC_MAX` 0: 123 packets, 419 bytes in 32 bits and 439 in 64).
The program has no data in its code section, which the reference decoder cannot parse; that is
also why the ACT programs (which have some) are not used here.

## Order of work

1. The ingress and the CSV dump, checked with the reference encoder and decoder (done).
2. The encoder, compared with the reference packet by packet (done).
3. The sink and its control registers, read through System Bus Access (or through the DM).
4. Several harts, and `denable`/`ienable` control from the debugger.
