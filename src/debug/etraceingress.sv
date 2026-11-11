///////////////////////////////////////////
// etraceingress.sv
//
// Purpose: The instruction trace interface (ingress port) of Efficient Trace for RISC-V v2.0,
//          section 4.2, for one hart that retires one instruction per cycle: one line per retired
//          instruction, and one per exception or interrupt.  It feeds the trace encoder (see
//          docs/trace.md), with itype_width_p 3:
//            0 none, 1 exception, 2 interrupt, 4 nontaken branch, 5 taken branch,
//            6 uninferable jump (jalr, c.jr, c.jalr, mret, sret)
//          mret and sret are uninferable jumps, not itype 3 (exception or interrupt return): the
//          reference encoder of the specification sends the address that follows an itype 6 but
//          not one that follows an itype 3, and the decoder needs it.
//
//          A retired instruction waits here until the address of the next one is known: that
//          address tells a taken branch from a nontaken one without any signal from the pipeline.
//          It comes from the next instruction to retire, from a trap (the address of the
//          instruction that traps or is interrupted), or from entering Debug Mode (dpc).
//
//          A line of a trap follows the line of the last instruction before it, one or two cycles
//          after the trap: after a trap the pipeline has no instruction to retire for longer than
//          that.  ecall, ebreak and c.ebreak retire as they raise their exception (iretire 1), as
//          in the reference flow of the specification; any other exception has iretire 0.
//          Instructions executed in Debug Mode are not traced.
//
//          ITrace, one line, from the most significant bit:
//            Valid, Halted, IType[2:0], IRetire, ILastSize, Priv[1:0], Cause[4:0], IAddr, Tval
//          Halted is the hart's Debug Mode; ILastSize is 1 for 32-bit instructions, 0 for 16-bit.
//          The line is registered (see below): it leaves one cycle after the one it describes.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module etraceingress import cvw::*; #(parameter cvw_t P) (
  input  logic                  clk, reset,
  input  logic                  StallW, FlushW,
  // The instruction in the Memory stage
  input  logic                  InstrValidM,
  input  logic [P.XLEN-1:0]     PCM, PCSpillM, IEUAdrxTvalM,
  input  logic [31:0]           InstrOrigM,                 // as fetched: 16 or 32 bits
  input  logic                  xRetM,                      // mret or sret
  input  logic [1:0]            PrivilegeModeW,
  input  logic                  DebugMode,
  // Traps taken before the instruction in M
  input  logic                  ArchTrapM, InterruptM,      // an architectural trap, and whether an interrupt
  input  logic                  EcallM, EBreakM,            // the instruction is an ecall, or an ebreak (c.ebreak)
  input  logic [4:0]            CauseM,
  input  logic                  DebugEnterM,
  // The instruction trace interface
  output logic [2*P.XLEN+13:0]  ITrace
);

  localparam logic [2:0] NONE = 3'd0, EXCEPTION = 3'd1, INTERRUPT = 3'd2, NONTAKEN = 3'd4, TAKEN = 3'd5,
                         UJUMP = 3'd6;

  logic Taken;
  assign Taken = ~StallW;                                   // a trap or debug entry takes effect

  ///////////////////////////////////////////
  // The instruction in M, and when it retires from W
  ///////////////////////////////////////////

  // Branches and uninferable jumps (jalr, c.jr, c.jalr), from the instruction as fetched
  logic Size4M, BranchM, UJumpM;
  assign Size4M  = InstrOrigM[1:0] == 2'b11;
  assign BranchM = Size4M ? InstrOrigM[6:0] == 7'b1100011
                          : InstrOrigM[1:0] == 2'b01 & InstrOrigM[15:14] == 2'b11;      // c.beqz, c.bnez
  assign UJumpM  = Size4M ? InstrOrigM[6:0] == 7'b1100111
                          : InstrOrigM[1:0] == 2'b10 & InstrOrigM[15:13] == 3'b100 &  // c.jr, c.jalr
                            InstrOrigM[6:2] == 5'b0 & InstrOrigM[11:7] != 5'b0;

  logic             ValidW, Size4W, BranchW, UJumpW, XRetW;
  logic [P.XLEN-1:0] PCW;
  logic [1:0]       PrivW;
  flopenrc #(1)      validreg(clk, reset, FlushW, ~StallW, InstrValidM & ~DebugMode, ValidW);
  flopenrc #(P.XLEN) pcreg(clk, reset, FlushW, ~StallW, PCM, PCW);
  flopenrc #(6)      classreg(clk, reset, FlushW, ~StallW, {Size4M, BranchM, UJumpM, xRetM, PrivilegeModeW},
                              {Size4W, BranchW, UJumpW, XRetW, PrivW});
  logic RetireW;
  assign RetireW = ValidW & ~StallW;

  ///////////////////////////////////////////
  // xtval of the trap, as csr.sv writes it
  ///////////////////////////////////////////

  logic [P.XLEN-1:0] TvalM;
  always_comb
    if (InterruptM) TvalM = '0;
    else case (CauseM)
      5'd12, 5'd1:                                    TvalM = PCSpillM;
      5'd3:                                           TvalM = PCM;
      5'd2:                                           TvalM = P.XLEN'(InstrOrigM);
      5'd0, 5'd4, 5'd6, 5'd13, 5'd15, 5'd5, 5'd7:     TvalM = IEUAdrxTvalM;
      default:                                        TvalM = '0;
    endcase

  ///////////////////////////////////////////
  // Lines
  ///////////////////////////////////////////

  // The held instruction: the last that retired, waiting for the address that follows it
  logic             HValid, HSize4, HBranch, HUJump, HXRet;
  logic [P.XLEN-1:0] HPC;
  logic [1:0]       HPriv;
  // A trap, and an entry in Debug Mode, waiting for the held instruction's line to go first
  logic             TPend, TInt, TRetire, TSize4, DPend;
  logic [P.XLEN-1:0] TPC, TTval, DPC;
  logic [4:0]       TCause;
  logic [1:0]       TPriv;

  // The line of the held instruction, given the address that follows it
  logic [P.XLEN-1:0] NextPC, FallThrough;
  logic [2:0]       HIType;
  assign FallThrough = HPC + (HSize4 ? P.XLEN'(4) : P.XLEN'(2));
  assign NextPC = TPend ? TPC : DPend ? DPC : PCW;
  always_comb
    if (HXRet | HUJump) HIType = UJUMP;
    else if (HBranch) HIType = NextPC == FallThrough ? NONTAKEN : TAKEN;
    else              HIType = NONE;

  // One line per cycle: the held instruction's when its next address is known, then a trap's
  logic             EmitH, EmitT;
  assign EmitH = HValid & (TPend | DPend | RetireW);
  assign EmitT = TPend & ~HValid;

  logic             LValid;
  logic [2:0]       LIType;
  logic             LRetire, LSize4;
  logic [1:0]       LPriv;
  logic [4:0]       LCause;
  logic [P.XLEN-1:0] LAddr, LTval;
  always_comb
    if (EmitH) begin
      LValid = 1'b1; LIType = HIType; LRetire = 1'b1; LSize4 = HSize4; LPriv = HPriv;
      LCause = '0; LAddr = HPC; LTval = '0;
    end else begin
      LValid = EmitT; LIType = TInt ? INTERRUPT : EXCEPTION; LRetire = TRetire; LSize4 = TSize4; LPriv = TPriv;
      LCause = TCause; LAddr = TPC; LTval = TTval;
    end
  // The line is registered: RetireW depends on StallW, which comes from the memory system (the LSU's address and the PMP/PMA checks
  // among others), and the encoder's packet logic follows, so without this register one cycle spans from the checkers to the sink's queue
  // (the longest path of the chip on an FPGA).  The trace is delayed one cycle; nothing else sees it.
  logic [2*P.XLEN+13:0] ILine;
  assign ILine = {LValid, DebugMode, LIType, LRetire, LSize4, LPriv, LCause, LAddr, LTval};
  flopr #(2*P.XLEN+14) itracereg(clk, reset, ILine, ITrace);

  always_ff @(posedge clk)
    if (reset) begin
      HValid <= 1'b0; TPend <= 1'b0; DPend <= 1'b0;
    end else begin
      // The held instruction (no instruction retires while a trap or debug entry is pending)
      if (TPend | DPend) begin
        if (EmitH) HValid <= 1'b0;
      end else if (RetireW) begin
        HValid <= 1'b1; HPC <= PCW; HSize4 <= Size4W; HBranch <= BranchW; HUJump <= UJumpW;
        HXRet <= XRetW; HPriv <= PrivW;
      end
      if (EmitT) TPend <= 1'b0;
      if (DPend & ~TPend) DPend <= 1'b0;                 // its only effect is NextPC, this cycle
      // A trap or an entry in Debug Mode, taken before the instruction in M
      if (ArchTrapM & Taken) begin
        TPend <= 1'b1; TPC <= PCM; TInt <= InterruptM; TCause <= CauseM; TTval <= TvalM;
        TPriv <= PrivilegeModeW; TSize4 <= Size4M; TRetire <= ~InterruptM & (EcallM | EBreakM);
      end
      if (DebugEnterM & Taken) begin
        DPend <= 1'b1; DPC <= PCM;
      end
    end
endmodule
