#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""E-Trace instruction trace decoder for Wally's encoder (docs/trace.md), standard library only.

It reconstructs the program counters that a hart retired from the te_inst packets of
src/debug/etraceencoder.sv and the program (the ELF), so that the trace can be checked without the
specification's reference flow.  It decodes the configuration of Wally's encoder only:
  - formats 1 (branches), 2 (address) and 3 (start, trap, support); no format 0;
  - iaddress_lsb_p 1, differential addresses (or full ones, if the support packet says so);
  - no time, context, call counter or return stack (no implicit return), privilege 2 bits,
    ecause 5 bits;
  - packets framed as in the reference flow: a header byte {msg_type, length} and the payload,
    least significant byte first, sign-compressed (bytes 0 between packets are idle bytes).
The algorithm is the decoder of the specification (chapter "Decoder"), written to follow the
reference decoder_model.py of riscv-trace-spec step by step, so that both reconstruct the same
program counters from the same packets.  It reads the program from the ELF's executable sections
itself, with a decoder of the few instruction classes that the algorithm needs.

    etracedecode.py --packets trace.packets --elf program.elf --xlen 64 [--csv trace.csv]
With --csv (the instruction trace interface, +EtraceCsv=) it checks the program counters against
the ones that the hart retired.
"""

import argparse
import csv
import struct
import sys
from pathlib import Path

# te_inst formats and sync subformats
FMT_BRANCH, FMT_ADDR, FMT_SYNC = 1, 2, 3
SYNC_START, SYNC_TRAP, SYNC_CONTEXT, SYNC_SUPPORT = 0, 1, 2, 3
QUAL_NO_CHANGE = 0

# The configuration of Wally's encoder
IADDRESS_LSB = 1
PRIVILEGE_WIDTH = 2
ECAUSE_WIDTH = 5


class DecodeError(Exception):
    """The packets do not describe a path through the program."""


###########################################################################################
# The program
###########################################################################################

class Instr:
    """The attributes of an instruction that the decoder needs."""

    __slots__ = ("imm", "kind", "rd", "rs1", "size")

    # kind: "branch", "jal" (inferable jump), "jalr" (jalr: inferable if rs1 is x0),
    # "ujump" (c.jr, c.jalr), "discon" (mret, sret, uret, dret, ecall, ebreak, c.ebreak), "other"
    def __init__(self, size, kind="other", imm=0, rs1=None, rd=None):
        self.size, self.kind, self.imm, self.rs1, self.rd = size, kind, imm, rs1, rd

    @property
    def is_branch(self):
        return self.kind == "branch"

    @property
    def is_trap_instr(self):
        """ecall, ebreak, c.ebreak: the exception address is the instruction itself."""
        return self.kind == "discon" and self.rd == "trap"


def sext(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def decode32(w):
    opcode = w & 0x7F
    rd, rs1 = (w >> 7) & 0x1F, (w >> 15) & 0x1F
    if opcode == 0x63:                                      # beq, bne, blt, bge, bltu, bgeu
        imm = ((w >> 31) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1)
        return Instr(4, "branch", sext(imm, 13), rs1)
    if opcode == 0x6F:                                      # jal
        imm = ((w >> 31) << 20) | (((w >> 12) & 0xFF) << 12) | (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1)
        return Instr(4, "jal", sext(imm, 21), rd=rd)
    if opcode == 0x67:                                      # jalr
        return Instr(4, "jalr", sext(w >> 20, 12), rs1, rd)
    if w in (0x00000073, 0x00100073):                       # ecall, ebreak
        return Instr(4, "discon", rd="trap")
    if w in (0x30200073, 0x10200073, 0x00200073, 0x7B200073):   # mret, sret, uret, dret
        return Instr(4, "discon")
    return Instr(4)


def decode16(h, xlen):
    quadrant, funct3 = h & 3, h >> 13
    if quadrant == 1 and funct3 in (6, 7):                  # c.beqz, c.bnez
        imm = (((h >> 12) & 1) << 8) | (((h >> 5) & 3) << 6) | (((h >> 2) & 1) << 5) \
            | (((h >> 10) & 3) << 3) | (((h >> 3) & 3) << 1)
        return Instr(2, "branch", sext(imm, 9), 8 + ((h >> 7) & 7))
    if quadrant == 1 and (funct3 == 5 or (funct3 == 1 and xlen == 32)):   # c.j, c.jal (RV32)
        imm = (((h >> 12) & 1) << 11) | (((h >> 8) & 1) << 10) | (((h >> 9) & 3) << 8) \
            | (((h >> 6) & 1) << 7) | (((h >> 7) & 1) << 6) | (((h >> 2) & 1) << 5) \
            | (((h >> 11) & 1) << 4) | (((h >> 3) & 7) << 1)
        return Instr(2, "jal", sext(imm, 12), rd=1 if funct3 == 1 else 0)
    if quadrant == 2 and funct3 == 4 and ((h >> 2) & 0x1F) == 0:
        rs1 = (h >> 7) & 0x1F
        if (h >> 12) & 1 == 0 and rs1 != 0:                 # c.jr
            return Instr(2, "ujump", rs1=rs1, rd=0)
        if (h >> 12) & 1 == 1 and rs1 != 0:                 # c.jalr
            return Instr(2, "ujump", rs1=rs1, rd=1)
        if (h >> 12) & 1 == 1:                              # c.ebreak
            return Instr(2, "discon", rd="trap")
    return Instr(2)


def read_program(elf, xlen):
    """The instructions of the ELF's executable sections, by address (a linear sweep)."""
    data = Path(elf).read_bytes()
    if data[:4] != b"\x7fELF" or data[5] != 1:
        raise DecodeError(f"{elf} is not a little-endian ELF file")
    is64 = data[4] == 2
    if is64:
        shoff, = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    else:
        shoff, = struct.unpack_from("<I", data, 0x20)
        shentsize, shnum = struct.unpack_from("<HH", data, 0x2E)
    program = {}
    for i in range(shnum):
        base = shoff + i * shentsize
        if is64:
            _, sh_type, flags, addr, offset, size = struct.unpack_from("<IIQQQQ", data, base)
        else:
            _, sh_type, flags, addr, offset, size = struct.unpack_from("<IIIIII", data, base)
        if sh_type == 8 or not flags & 4:                   # SHT_NOBITS, or not SHF_EXECINSTR
            continue
        code = data[offset:offset + size]
        pc = 0
        while pc + 2 <= len(code):
            half = code[pc] | (code[pc + 1] << 8)
            if half & 3 == 3:
                if pc + 4 > len(code):
                    break
                instr = decode32(half | (code[pc + 2] << 16) | (code[pc + 3] << 24))
            else:
                instr = decode16(half, xlen)
            program[addr + pc] = instr
            pc += instr.size
    return program


###########################################################################################
# The packets
###########################################################################################

def split_packets(raw):
    """Split a te_inst byte stream into packet payloads: a header byte, whose low 5 bits are the
    payload length, then the payload.  Bytes 0 between packets are idle bytes (the RAM sink fills
    its last word with them)."""
    packets, i = [], 0
    while i < len(raw):
        if raw[i] == 0:
            i += 1
            continue
        end = i + 1 + (raw[i] & 0x1F)
        if end > len(raw):
            raise DecodeError(f"the last packet, at byte {i}, is cut short")
        packets.append(raw[i:end])
        i = end
    return packets


class Bits:
    """The fields of a payload, least significant first; sign-extended past its end."""

    def __init__(self, payload):
        self.nbits = 8 * len(payload)
        self.value = int.from_bytes(payload, "little")
        if self.nbits and self.value >> (self.nbits - 1):
            self.value -= 1 << self.nbits               # a negative number: an endless sign
        self.pos = 0

    def get(self, n):
        v = (self.value >> self.pos) & ((1 << n) - 1)
        self.pos += n
        return v

    def check(self, what):
        if self.nbits - self.pos > 7:
            raise DecodeError(f"{what}: {self.nbits - self.pos} bits of the payload are not used")


class Packet:
    """A te_inst packet: the fields as attributes (None when absent)."""

    FIELDS = ("format", "subformat", "branch", "privilege", "ecause", "interrupt", "thaddr", "address",
              "tval", "ienable", "encoder_mode", "qual_status", "ioptions", "notify", "updiscon",
              "irreport", "branches", "branch_map")

    def __init__(self, payload, xlen):
        for f in self.FIELDS:
            setattr(self, f, None)
        aw = xlen - IADDRESS_LSB
        b = Bits(payload)
        self.format = b.get(2)
        if self.format == FMT_SYNC:
            self.subformat = b.get(2)
            if self.subformat in (SYNC_START, SYNC_TRAP):
                self.branch = b.get(1)
                self.privilege = b.get(PRIVILEGE_WIDTH)
                if self.subformat == SYNC_TRAP:
                    self.ecause = b.get(ECAUSE_WIDTH)
                    self.interrupt = b.get(1)
                    self.thaddr = b.get(1)
                self.address = b.get(aw)
                if self.subformat == SYNC_TRAP and not self.interrupt:
                    self.tval = b.get(xlen)
            elif self.subformat == SYNC_CONTEXT:
                self.privilege = b.get(PRIVILEGE_WIDTH)
            else:
                self.ienable = b.get(1)
                self.encoder_mode = b.get(1)
                self.qual_status = b.get(2)
                self.ioptions = b.get(5)
                b.get(6)                                    # denable, dloss, doptions
        elif self.format == FMT_ADDR:
            self.address = b.get(aw)
            self.notify, self.updiscon, self.irreport = b.get(1), b.get(1), b.get(1)
        elif self.format == FMT_BRANCH:
            self.branches = b.get(5)
            n = self.branches
            bits = 31 if n == 0 else 1 if n == 1 else 3 if n <= 3 else 7 if n <= 7 else 15 if n <= 15 else 31
            self.branch_map = b.get(bits)
            if n != 0:
                self.address = b.get(aw)
                self.notify, self.updiscon, self.irreport = b.get(1), b.get(1), b.get(1)
        else:
            raise DecodeError("format 0 packet: Wally's encoder does not send it")
        b.check(f"format {self.format} packet")

    @property
    def has_address(self):
        return self.format == FMT_ADDR or (self.format == FMT_BRANCH and self.branches != 0)


###########################################################################################
# The decoder (the specification's algorithm, as decoder_model.py writes it)
###########################################################################################

class Decoder:
    def __init__(self, program, xlen):
        self.program, self.xlen = program, xlen
        self.mask = (1 << xlen) - 1
        self.pc = self.last_pc = None
        self.address = 0
        self.branches = self.branch_map = 0
        self.stop_at_last_branch = False
        self.inferred_address = False
        self.start_of_trace = True
        self.full_address = False
        self.notify = self.updiscon = self.irreport = False
        self.pcs = []

    def instr(self, address):
        if address is None:
            raise DecodeError("no program counter: the trace did not start with a sync packet")
        if address not in self.program:
            raise DecodeError(f"no instruction at 0x{address:x} in the program")
        return self.program[address]

    def report(self, pc):
        self.pcs.append(pc)

    def add(self, p):
        if p.has_address:
            # The flags are sent as differences from the address msb, and from each other
            msb = (p.address << IADDRESS_LSB) >> (self.xlen - 1) & 1
            self.notify = p.notify != msb
            self.updiscon = p.updiscon != p.notify
            self.irreport = p.irreport != p.updiscon
        else:
            self.notify = self.updiscon = self.irreport = False

        if p.format == FMT_SYNC:
            if p.subformat == SYNC_SUPPORT:
                self.full_address = bool(p.ioptions >> 2 & 1)
                if p.qual_status != QUAL_NO_CHANGE:
                    self.start_of_trace = True              # the trace ended: wait for a start
                return
            if p.subformat == SYNC_CONTEXT:
                return
            if p.subformat == SYNC_TRAP:
                if not p.interrupt:
                    self.exception_address(p)
                if p.thaddr == 0:
                    return
            self.inferred_address = False
            self.address = p.address << IADDRESS_LSB
            if self.address == 0:
                raise DecodeError("sync packet with address 0")
            if p.subformat == SYNC_TRAP or self.start_of_trace:
                self.branches = self.branch_map = 0
            if self.instr(self.address).is_branch:
                self.branch_map |= p.branch << self.branches
                self.branches += 1
            if p.subformat == SYNC_START and not self.start_of_trace:
                self.follow_execution_path(self.address, p)
            else:
                self.pc = self.address
                self.report(self.pc)
                self.last_pc = self.pc
            self.start_of_trace = False
        else:
            if self.start_of_trace:
                raise DecodeError(f"format {p.format} packet before the trace started")
            if p.has_address:
                self.stop_at_last_branch = False
                address = p.address << IADDRESS_LSB
                if self.full_address:
                    self.address = address
                else:
                    self.address = (self.address + sext(address, self.xlen)) & self.mask
            if p.format == FMT_BRANCH:
                self.stop_at_last_branch = p.branches == 0
                self.branch_map |= p.branch_map << self.branches
                self.branches += 31 if p.branches == 0 else p.branches
            self.follow_execution_path(self.address, p)

    def branch_limit(self):
        return 1 if self.instr(self.pc).is_branch else 0

    def follow_execution_path(self, address, p):
        previous = self.pc
        for _ in range(1 << 20):                            # a bound against a runaway path
            if self.inferred_address:
                stop = self.next_pc(previous)
                self.report(self.pc)
                if stop:
                    self.inferred_address = False
                continue
            stop = self.next_pc(address)
            self.report(self.pc)
            if self.branches == 1 and self.instr(self.pc).is_branch and self.stop_at_last_branch:
                # The last branch of the map: its outcome is in the next packet
                self.stop_at_last_branch = False
                return
            if stop:
                # The target of an uninferable discontinuity
                if self.branches > self.branch_limit():
                    raise DecodeError(f"unprocessed branches at 0x{self.pc:x}")
                return
            if p.format != FMT_SYNC and self.pc == address and not self.stop_at_last_branch \
                    and self.notify and self.branches == self.branch_limit():
                return
            if p.format != FMT_SYNC and self.pc == address and not self.stop_at_last_branch \
                    and not self.is_uninferable_discon(self.instr(self.last_pc)) and not self.updiscon \
                    and self.branches == self.branch_limit() and not self.irreport:
                # The reported address, reached not as the target of an uninferable jump: it may
                # not be the last instruction retired
                self.inferred_address = True
                return
            if p.format == FMT_SYNC and self.pc == address and self.branches == self.branch_limit():
                return
        raise DecodeError(f"no end to the path towards 0x{address:x}")

    def next_pc(self, address):
        instr = self.instr(self.pc)
        this_pc = self.pc
        stop = False
        if instr.kind == "jal" or (instr.kind == "jalr" and instr.rs1 == 0):
            target = instr.imm & self.mask if instr.kind == "jalr" else (self.pc + instr.imm) & self.mask
            stop = target == self.pc                        # a jump to itself: stop
            self.pc = target
        elif self.is_uninferable_discon(instr):
            if self.stop_at_last_branch:
                raise DecodeError(f"unexpected uninferable discontinuity at 0x{self.pc:x}")
            self.pc = address
            stop = True
        elif instr.is_branch and self.take_branch():
            stop = instr.imm == 0
            self.pc = (self.pc + instr.imm) & self.mask
        else:
            self.pc = (self.pc + instr.size) & self.mask
        self.last_pc = this_pc
        return stop

    def take_branch(self):
        if self.branches == 0:
            raise DecodeError(f"cannot resolve the branch at 0x{self.pc:x}: no branch in the map")
        taken = self.branch_map & 1 == 0
        self.branches -= 1
        self.branch_map >>= 1
        return taken

    @staticmethod
    def is_uninferable_discon(instr):
        return instr.kind in ("ujump", "discon") or (instr.kind == "jalr" and instr.rs1 != 0)

    def exception_address(self, p):
        # As decoder_model.py does: for an instruction that is neither an uninferable
        # discontinuity reported with thaddr 0 nor ecall/ebreak, the exception address is found
        # by stepping over the instruction, which moves the decoder on.
        instr = self.instr(self.pc)
        if (self.is_uninferable_discon(instr) and p.thaddr == 0) or instr.is_trap_instr:
            return
        self.next_pc(self.pc)


def decode(raw, program, xlen):
    """The program counters that the packets in the byte stream raw describe."""
    decoder = Decoder(program, xlen)
    for n, payload in enumerate(split_packets(raw)):
        try:
            decoder.add(Packet(payload[1:], xlen))
        except DecodeError as e:
            raise DecodeError(f"packet {n} ({payload.hex()}): {e}") from None
    return decoder.pcs


def retired_pcs(csv_file):
    """The program counters that the hart retired, from the instruction trace interface CSV."""
    with open(csv_file, newline="") as fd:
        return [int(row["iaddr_0"], 16) for row in csv.DictReader(fd) if row["iretire_0"] != "0"]


def compare(decoded, retired):
    """None if equal, else a description of the first difference."""
    for n, (d, r) in enumerate(zip(decoded, retired)):
        if d != r:
            return f"instruction {n}: decoded 0x{d:x}, retired 0x{r:x}"
    if len(decoded) != len(retired):
        return f"decoded {len(decoded)} instructions, the hart retired {len(retired)}"
    return None


def read_packets(path):
    """The bytes of a +EtracePackets= file (hex bytes, in order) or of a raw binary file."""
    data = Path(path).read_bytes()
    try:
        return bytes.fromhex(data.decode("ascii"))
    except ValueError:
        return data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--packets", required=True, help="the trace: +EtracePackets= hex file, or raw bytes")
    parser.add_argument("--elf", required=True, help="the program that ran")
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--csv", help="instruction trace interface CSV (+EtraceCsv=): check against it")
    parser.add_argument("--print", action="store_true", help="print the program counters")
    args = parser.parse_args()
    try:
        pcs = decode(read_packets(args.packets), read_program(args.elf, args.xlen), args.xlen)
    except DecodeError as e:
        sys.exit(f"FAIL: {e}")
    if args.print:
        print("".join(f"{pc:x}\n" for pc in pcs), end="")
    if args.csv:
        error = compare(pcs, retired_pcs(args.csv))
        if error:
            sys.exit(f"FAIL: {error}")
        print(f"decoder: the {len(pcs)} program counters match")


if __name__ == "__main__":
    main()
