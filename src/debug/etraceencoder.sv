///////////////////////////////////////////
// etraceencoder.sv
//
// Purpose: The instruction trace encoder of Efficient Trace for RISC-V v2.0 for one hart: the
//          compressed branch trace algorithm of the specification (chapter "Reference compressed
//          branch trace algorithm") in the configuration of docs/trace.md: itype_width_p 3,
//          iaddress_lsb_p 1, differential addresses, no context, no time, no call/return stack,
//          no branch prediction or jump target cache, single retirement.
//
//          It follows the reference model of the specification (referenceFlow/scripts/
//          encoder_model.py) step for step, so that its packets are equal to the model's byte for
//          byte (testbench/debug/etrace/etracecheck.py):
//            - a pipeline of three lines of the instruction trace interface (src/debug/
//              etraceingress.sv): the previous, the current and the next instruction; a line that
//              arrives shifts it and the current instruction is encoded, so at most one packet
//              per line;
//            - when trace is turned on, a support packet (ienable 1); when it is turned off, the
//              pipeline is flushed: the last instruction is encoded, then its address is sent, then
//              a support packet with ienable 0 (one packet per cycle);
//            - every packet is compressed by removing the copies of its most significant bit
//              (sign-based compression), extended with its sign to whole bytes, and preceded by a
//              header byte: {1'b0, msg_type 2 (te_inst), payload length in bytes}.
//          Packet holds the header in byte 0 and the payload from byte 1, least significant first.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module etraceencoder import cvw::*; #(parameter cvw_t P,
  localparam int PAYLOAD = 2*P.XLEN + 13,           // bits of the longest packet: a trap with tval
  localparam int NBYTES  = 1 + (PAYLOAD + 7) / 8   // header and payload
) (
  input  logic                  clk, reset,
  input  logic                  TraceOn,            // trace enable; a falling edge flushes the encoder
  input  logic [3:0]            ResyncMax,          // a sync packet at least every 2^(ResyncMax+4) packets
  input  logic [2*P.XLEN+13:0]  ITrace,             // one line of the instruction trace interface
  output logic                  PacketValid,
  output logic [4:0]            PacketLen,          // bytes of Packet, header included
  output logic [8*NBYTES-1:0]   Packet
);

  localparam int AW = P.XLEN - 1;                   // address field: iaddress_width_p - iaddress_lsb_p

  // itype (itype_width_p 3), packet formats and sync subformats
  localparam logic [2:0] EXCEPTION = 3'd1, INTERRUPT = 3'd2, NONTAKEN = 3'd4, TAKEN = 3'd5, UJUMP = 3'd6;

  typedef struct packed {
    logic              q;                           // qualified: holds an instruction
    logic [2:0]        itype;
    logic              iretire;
    logic [1:0]        priv;
    logic [4:0]        cause;
    logic [P.XLEN-1:0] iaddr, tval;
  } inst_t;

  typedef enum logic [2:0] {PK_NONE, PK_START, PK_TRAP, PK_ADDR, PK_BRANCHES, PK_SUPPORT} pkt_t;
  typedef enum logic [2:0] {S_OFF, S_ON, S_FLUSH_ADDR, S_FLUSH_SUPPORT} state_t;

  ///////////////////////////////////////////
  // The line of the instruction trace interface
  ///////////////////////////////////////////

  logic   LValid, LHalted, LSize;
  inst_t  Line;
  assign {LValid, LHalted, Line.itype, Line.iretire, LSize, Line.priv, Line.cause, Line.iaddr, Line.tval} = ITrace;
  assign Line.q = 1'b1;

  ///////////////////////////////////////////
  // State
  ///////////////////////////////////////////

  state_t            State;
  inst_t             Prev, Curr, Next;              // the pipeline
  logic              Started;                       // a line has arrived since trace was turned on
  logic [4:0]        Branches;                      // branches in BranchMap
  logic [30:0]       BranchMap;                     // bit i: 1 if branch i was not taken
  logic [15:0]       ResyncCount;                   // packets since the last start or trap packet
  logic              TrapReported;                  // the last packet was a trap with thaddr 0 that reports the next trap too
  logic [P.XLEN-1:0] LastAddr;                      // the last address sent
  logic              FlushUpdiscon;                 // updiscon flag of the flush, for its address packet

  logic [15:0]       ResyncLimit;
  assign ResyncLimit = 16'd1 << (ResyncMax + 4'd4);

  ///////////////////////////////////////////
  // The algorithm: encode the current instruction, given the previous and the next
  ///////////////////////////////////////////

  logic   Encode, Flush;                            // a line arrives / the pipeline is flushed
  inst_t  IPrev, ICurr, INext;
  assign Encode = State == S_ON & TraceOn & LValid & Started;
  assign Flush  = State == S_ON & ~TraceOn;
  assign IPrev  = Curr;                             // the pipeline after the shift
  assign ICurr  = Next;
  assign INext  = Flush ? Next : Line;              // the flush repeats the last instruction

  function automatic logic Exc(inst_t i);
    return i.itype == EXCEPTION | i.itype == INTERRUPT;
  endfunction

  logic        IsBranch;
  logic [4:0]  BranchesE;                           // with the current instruction
  logic [30:0] BranchMapE;
  logic        PrevUpdiscon, Updiscon, PrevException, CurrExcOnly, NextExcOnly, NextException,
               PrevReported, FirstQualified, Ppccd, PpccdBr, ErN, ResyncBr, RptBr, ResyncExceeded;
  pkt_t        EncPkt;
  inst_t       EncExc;                              // the exception that a trap packet reports
  logic        EncThaddr;

  always_comb begin
    IsBranch   = ICurr.itype == NONTAKEN | ICurr.itype == TAKEN;
    BranchesE  = Branches + {4'b0, IsBranch};
    BranchMapE = BranchMap;
    if (IsBranch) BranchMapE[Branches] = ICurr.itype == NONTAKEN;

    PrevUpdiscon   = IPrev.itype == UJUMP;
    Updiscon       = PrevUpdiscon & (Exc(INext) | INext.priv != ICurr.priv | ResyncCount == ResyncLimit);
    PrevException  = Exc(IPrev);
    CurrExcOnly    = ~ICurr.iretire & Exc(ICurr);
    NextExcOnly    = ~INext.iretire & Exc(INext);
    NextException  = Exc(INext);
    PrevReported   = PrevException & TrapReported;
    FirstQualified = ~IPrev.q & ICurr.q;
    Ppccd          = ICurr.priv != IPrev.priv;
    PpccdBr        = BranchesE != 0 & INext.priv != ICurr.priv;
    ErN            = ICurr.iretire & Exc(ICurr);
    ResyncBr       = ResyncCount == ResyncLimit & BranchesE != 0;
    RptBr          = BranchesE == 5'd31;
    ResyncExceeded = ResyncCount > ResyncLimit;

    EncExc = IPrev; EncThaddr = 1'b1;
    if (~ICurr.q)                                           EncPkt = PK_NONE;
    else if (PrevException) begin
      if (CurrExcOnly)       begin EncPkt = PK_TRAP; EncThaddr = 1'b0; end
      else if (PrevReported)       EncPkt = PK_START;
      else                         EncPkt = PK_TRAP;
    end
    else if (FirstQualified | Ppccd | ResyncExceeded)       EncPkt = PK_START;
    else if (PrevUpdiscon) begin
      if (CurrExcOnly)       begin EncPkt = PK_TRAP; EncThaddr = 1'b0; EncExc = ICurr; end
      else                         EncPkt = PK_ADDR;
    end
    else if (ResyncBr | ErN | NextExcOnly | PpccdBr)        EncPkt = PK_ADDR;
    else if (RptBr)                                         EncPkt = PK_BRANCHES;
    else                                                    EncPkt = PK_NONE;
  end

  ///////////////////////////////////////////
  // The packet of this cycle
  ///////////////////////////////////////////

  pkt_t  Pkt;
  inst_t PInst, PExc;                               // the instruction it reports, and the exception of a trap
  logic  PThaddr, PUpdiscon;
  logic  PBranchFlags;                              // the branch map of this cycle (encoding) or of the state
  always_comb begin
    PInst = ICurr; PExc = EncExc; PThaddr = EncThaddr; PUpdiscon = Updiscon; PBranchFlags = 1'b1;
    case (State)
      S_OFF:           Pkt = TraceOn ? PK_SUPPORT : PK_NONE;
      S_ON:            Pkt = (Encode | Flush) ? EncPkt : PK_NONE;
      S_FLUSH_ADDR:    begin Pkt = Curr.q ? PK_ADDR : PK_NONE;    // the address of the last instruction
                             PInst = Curr; PUpdiscon = FlushUpdiscon; PBranchFlags = 1'b0; end
      S_FLUSH_SUPPORT: Pkt = PK_SUPPORT;
      default:         Pkt = PK_NONE;
    endcase
  end

  logic [4:0]        PBranches;
  logic [30:0]       PBranchMap;
  logic [P.XLEN-1:0] Diff;
  logic              Notify, UpdisconBit;
  assign PBranches  = PBranchFlags ? BranchesE : Branches;
  assign PBranchMap = PBranchFlags ? BranchMapE : BranchMap;
  assign Diff        = PInst.iaddr - LastAddr;
  assign Notify      = Diff[P.XLEN-1];              // notify flag (0) xor the address msb
  assign UpdisconBit = PUpdiscon ^ Notify;

  // Fields, from the least significant bit; Len is the length before compression
  logic [8*(NBYTES-1)-1:0] Raw, Sext;
  int                      Len;
  always_comb begin
    int pos;
    Raw = '0; pos = 0;
    case (Pkt)
      PK_START, PK_TRAP: begin
        Raw[1:0] = 2'd3; Raw[3:2] = Pkt == PK_START ? 2'd0 : 2'd1;
        Raw[4]   = PInst.itype != TAKEN;            // branch: 0 if the instruction is a taken branch
        Raw[6:5] = PInst.priv;
        pos = 7;
        if (Pkt == PK_TRAP) begin
          Raw[pos +: 5] = PExc.cause;
          Raw[pos+5]    = PExc.itype == INTERRUPT;
          Raw[pos+6]    = PThaddr;
          pos += 7;
        end
        Raw[pos +: AW] = PInst.iaddr[P.XLEN-1:1];    // full address
        pos += AW;
        if (Pkt == PK_TRAP & PExc.itype != INTERRUPT) begin
          Raw[pos +: P.XLEN] = PExc.tval;
          pos += P.XLEN;
        end
      end
      PK_ADDR, PK_BRANCHES: begin
        if (Pkt == PK_BRANCHES | PBranches != 0) begin   // format 1: branches and branch map
          Raw[1:0] = 2'd1;
          Raw[6:2] = Pkt == PK_BRANCHES ? 5'd0 : PBranches; // 31 branches without address are sent as 0
          Raw[7 +: 31] = PBranchMap;                // the bits above the branches are zero
          pos = 7 + (Pkt == PK_BRANCHES    ? 31 :
                     PBranches == 5'd1     ? 1  :
                     PBranches <= 5'd3     ? 3  :
                     PBranches <= 5'd7     ? 7  :
                     PBranches <= 5'd15    ? 15 : 31);
        end else begin                              // format 2: address only
          Raw[1:0] = 2'd2;
          pos = 2;
        end
        if (Pkt == PK_ADDR) begin
          Raw[pos +: AW] = Diff[P.XLEN-1:1];        // differential address
          Raw[pos+AW]    = Notify;
          Raw[pos+AW+1]  = UpdisconBit;
          Raw[pos+AW+2]  = UpdisconBit;             // irreport (0) xor updiscon
          pos += AW + 3;
        end
      end
      PK_SUPPORT: begin
        Raw[1:0] = 2'd3; Raw[3:2] = 2'd3;
        Raw[4]   = State == S_OFF;                  // ienable
        // encoder_mode 0; qual_status 0 when turned on, 1 (ended, representative) at the flush
        Raw[7:6] = {1'b0, State == S_FLUSH_SUPPORT & Next.q};
        // ioptions 0 (5 bits), denable, dloss, doptions (4 bits) 0
        pos = 19;
      end
      default: pos = 1;
    endcase
    Len = pos;
  end

  // Sign-based compression: the shortest length whose sign extension is the packet
  logic [4:0] PayloadBytes;
  always_comb begin
    int n;
    for (int i = 0; i < 8*(NBYTES-1); i++) Sext[i] = (i < Len) ? Raw[i] : Raw[Len-1];
    n = 1;
    for (int i = 0; i < 8*(NBYTES-1) - 1; i++)
      if (Sext[i] != Sext[8*(NBYTES-1)-1]) n = i + 2;
    PayloadBytes = 5'((n + 7) / 8);
  end

  assign PacketValid = Pkt != PK_NONE;
  assign PacketLen   = PayloadBytes + 5'd1;
  assign Packet      = {Sext, 1'b0, 2'd2, PayloadBytes};

  ///////////////////////////////////////////
  // Next state
  ///////////////////////////////////////////

  logic Sent, SentSync;
  assign Sent     = PacketValid;
  assign SentSync = Pkt == PK_START | Pkt == PK_TRAP;

  always_ff @(posedge clk)
    if (reset) begin
      State <= S_OFF;
      Prev.q <= 1'b0; Curr.q <= 1'b0; Next.q <= 1'b0;
    end else begin
      case (State)
        S_OFF:           if (TraceOn) State <= S_ON;
        S_ON:            if (~TraceOn) State <= S_FLUSH_ADDR;
        S_FLUSH_ADDR:    State <= S_FLUSH_SUPPORT;
        S_FLUSH_SUPPORT: State <= S_OFF;
        default:         State <= S_OFF;
      endcase

      // Turned on: an empty pipeline, as the reference model starts
      if (State == S_OFF & TraceOn) begin
        Prev <= '0; Curr <= '0; Next <= '0; Started <= 1'b0;
        Branches <= '0; BranchMap <= '0; TrapReported <= 1'b0;
        ResyncCount <= 16'd1;                       // the support packet counts
      end else begin
        // The pipeline: a line arrives, or the flush repeats the last instruction
        if (State == S_ON & ((TraceOn & LValid) | Flush)) begin
          Prev <= Curr; Curr <= Next; Next <= INext;
        end
        if (State == S_ON & TraceOn & LValid) Started <= 1'b1;

        // The branch map and the flags of the algorithm, when an instruction is encoded
        if ((Encode | Flush) & ICurr.q) begin
          Branches <= BranchesE; BranchMap <= BranchMapE;
          TrapReported <= Pkt == PK_TRAP & ~PThaddr & (PrevUpdiscon | NextException);
        end
        if (Flush) FlushUpdiscon <= Updiscon;

        // A packet empties the branch map, and counts towards the resynchronization
        if (Sent) begin
          Branches <= '0; BranchMap <= '0;
          ResyncCount <= SentSync ? 16'd0 : ResyncCount + 16'd1;
        end
        if (SentSync | Pkt == PK_ADDR) LastAddr <= PInst.iaddr;
      end
    end
endmodule
