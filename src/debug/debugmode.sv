///////////////////////////////////////////
// debugmode.sv
//
// Purpose: Debug Mode of a hart (RISC-V Debug Specification 1.0, chapter 4), for the
//          execution-based Debug Module of src/debug/dm.sv: the debug CSRs (dcsr, dpc,
//          dscratch0, dscratch1), entering Debug Mode, dret and single-stepping.
//
//          The hart enters Debug Mode before the instruction in the Memory stage (dpc = its PC),
//          as for an interrupt, on a halt request of the Debug Module, after a single step, when a
//          trigger fires (triggers.sv), or on an ebreak that dcsr.ebreakm/s/u sends to the
//          debugger.  It then executes the Debug Module's ROM at HALT_ADDR in M-mode, with
//          interrupts masked; an ebreak there goes back to HALT_ADDR, any other exception to
//          EXCEPTION_ADDR, without changing any other CSR.
//          dret returns to dpc in the privilege mode of dcsr.prv.
//
//          privileged.sv steers the existing trap and return paths with the outputs of this
//          module, so that trap.sv, privmode.sv, privdec.sv and csr.sv are unchanged:
//          DebugTrapM redirects the PC to DebugTrapVectorM, and dret is a return to DPC.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module debugmode import cvw::*; #(parameter cvw_t P,
  parameter logic [P.XLEN-1:0] HALT_ADDR = 'h800,       // the Debug Module's ROM: halt entry
  parameter logic [P.XLEN-1:0] EXCEPTION_ADDR = 'h808   // and exception entry
) (
  input  logic              clk, reset,
  input  logic              StallW, FlushW,
  input  logic              DebugHaltReq,                // halt request from the Debug Module
  input  logic              DebugResetHaltReq,           // the halt request is resethaltreq's
  input  logic              TrigDebugM,                  // a trigger fires with action 1 (triggers.sv)
  // The instruction in the Memory stage
  input  logic [31:0]       InstrM,
  input  logic              PrivilegedM, InstrValidM,
  input  logic              CommittedM, CommittedF,      // a bus access is under way: not interruptible
  input  logic              WaitedM,                     // a wfi has waited: it retires first
  input  logic [P.XLEN-1:0] PCM,
  input  logic [1:0]        PrivilegeModeW,
  input  logic              BreakpointFaultM,            // ebreak
  input  logic              ExceptionM,                  // any exception (ebreak included) of the instruction
  input  logic              ArchTrapM,                   // an architectural trap is taken
  // CSR accesses
  input  logic              CSRReadM, CSRWriteM,
  input  logic [P.XLEN-1:0] SrcAM,
  // To the trap and return paths
  output logic              DebugMode,
  output logic              DebugEnterM,                 // enter Debug Mode before the instruction in M
  output logic              DebugTrapM,                  // redirect: DebugEnterM, or an exception in Debug Mode
  output logic [P.XLEN-1:0] DebugTrapVectorM,
  output logic              EBreakToDebugM,              // the ebreak enters Debug Mode instead of trapping
  output logic              dretM,
  output logic [P.XLEN-1:0] DPC,
  output logic [1:0]        DCSRPrv,                     // privilege mode to return to
  output logic              DebugIntMask,                // mask interrupts: in Debug Mode, or stepping without stepie
  output logic              DebugWakeM,                  // end a wfi: a halt request, or a step (wfi is then a nop)
  output logic              DebugCSRHitM,                // the instruction accesses a debug CSR in Debug Mode
  output logic [P.XLEN-1:0] DebugCSRReadValM
);

  localparam logic [11:0] DCSR = 12'h7B0, DPCADR = 12'h7B1, DSCRATCH0 = 12'h7B2, DSCRATCH1 = 12'h7B3;
  // dcsr.cause
  localparam logic [2:0] CAUSE_EBREAK = 3'd1, CAUSE_TRIGGER = 3'd2, CAUSE_HALTREQ = 3'd3, CAUSE_STEP = 3'd4, CAUSE_RESETHALTREQ = 3'd5;

  logic             EBreakM, EBreakS, EBreakU, StepIE, Step;
  logic [2:0]       Cause, NextCause;
  logic [P.XLEN-1:0] DScratch0, DScratch1;
  logic             StepArmed, StepHalt;
  logic             HaltM, Interruptible, Taken;
  logic [11:0]      CSRAdrM;
  logic [P.XLEN-1:0] CSRSrcM, CSRWriteValM;
  logic             WriteM;

  assign Taken = ~StallW;                      // the trap or return takes effect this cycle

  ///////////////////////////////////////////
  // Entering and leaving Debug Mode
  ///////////////////////////////////////////

  // An ebreak enters Debug Mode if dcsr allows it in the current privilege mode
  assign EBreakToDebugM = ~DebugMode & BreakpointFaultM &
    (PrivilegeModeW == P.M_MODE & EBreakM | PrivilegeModeW == P.S_MODE & EBreakS |
     PrivilegeModeW == P.U_MODE & EBreakU);
  // A halt request or a completed step stops the hart before the instruction in M, at the same
  // boundaries as an interrupt
  assign Interruptible = InstrValidM & ~CommittedM & ~CommittedF & ~WaitedM;
  assign HaltM = ~DebugMode & (DebugHaltReq | StepHalt) & Interruptible;
  assign DebugEnterM = EBreakToDebugM | HaltM | TrigDebugM;
  // Priority of dcsr.cause (the dcsr table of the Debug Specification): trigger, ebreak,
  // resethaltreq, haltreq, step
  assign NextCause = TrigDebugM ? CAUSE_TRIGGER : EBreakToDebugM ? CAUSE_EBREAK :
                     DebugHaltReq ? (DebugResetHaltReq ? CAUSE_RESETHALTREQ : CAUSE_HALTREQ) : CAUSE_STEP;

  assign dretM = DebugMode & PrivilegedM & InstrM[31:20] == 12'h7B2 & InstrM[19:7] == '0 & InstrValidM;

  // In Debug Mode, an ebreak goes back to the halt entry of the ROM, any other exception to its
  // exception entry
  assign DebugTrapM = DebugEnterM | DebugMode & ExceptionM & ~CommittedF;
  assign DebugTrapVectorM = DebugEnterM | BreakpointFaultM ? HALT_ADDR : EXCEPTION_ADDR;

  always_ff @(posedge clk)
    if (reset) DebugMode <= 1'b0;
    else if (DebugEnterM & Taken) DebugMode <= 1'b1;
    else if (dretM & Taken)       DebugMode <= 1'b0;

  // Single step: after dret with dcsr.step, let one instruction complete (retire or trap), then
  // halt before the next one (after a trap, the first instruction of its handler).  The dret
  // itself moves to W as it returns, before StepArmed is set.
  always_ff @(posedge clk)
    if (reset | DebugEnterM & Taken) begin
      StepArmed <= 1'b0; StepHalt <= 1'b0;
    end else if (dretM & Taken) begin
      StepArmed <= Step; StepHalt <= 1'b0;
    end else if (StepArmed & (InstrValidM & ~StallW & ~FlushW | ArchTrapM & Taken)) begin
      StepArmed <= 1'b0; StepHalt <= 1'b1;
    end

  assign DebugIntMask = DebugMode | (StepArmed | StepHalt) & ~StepIE;
  // A wfi does not wait for a halt request, nor while stepping: the specification's Single Step
  // section treats it as a nop, so the step completes
  assign DebugWakeM = DebugHaltReq | DebugMode | StepArmed;

  ///////////////////////////////////////////
  // Debug CSRs: accessible only in Debug Mode
  ///////////////////////////////////////////

  assign CSRAdrM = InstrM[31:20];
  assign DebugCSRHitM = DebugMode & (CSRReadM | CSRWriteM) &
    (CSRAdrM == DCSR | CSRAdrM == DPCADR | CSRAdrM == DSCRATCH0 | CSRAdrM == DSCRATCH1);

  // dcsr: debugver 4, ebreakm/s/u, stepie, cause, step, prv (stopcount, stoptime, mprven 0)
  logic [31:0] DCSRVal;
  assign DCSRVal = {4'd4, 12'b0, EBreakM, 1'b0, EBreakS, EBreakU, StepIE, 1'b0, 1'b0, Cause,
                    1'b0, 1'b0, 1'b0, Step, DCSRPrv};
  always_comb
    case (CSRAdrM)
      DCSR:      DebugCSRReadValM = P.XLEN'(DCSRVal);
      DPCADR:    DebugCSRReadValM = DPC;
      DSCRATCH0: DebugCSRReadValM = DScratch0;
      DSCRATCH1: DebugCSRReadValM = DScratch1;
      default:   DebugCSRReadValM = '0;
    endcase
  // As csr.sv: rs1 or uimm, then write, set or clear
  assign CSRSrcM = InstrM[14] ? {{(P.XLEN-5){1'b0}}, InstrM[19:15]} : SrcAM;
  always_comb
    case (InstrM[13:12])
      2'b01:   CSRWriteValM = CSRSrcM;
      2'b10:   CSRWriteValM = DebugCSRReadValM | CSRSrcM;
      2'b11:   CSRWriteValM = DebugCSRReadValM & ~CSRSrcM;
      default: CSRWriteValM = DebugCSRReadValM;
    endcase
  assign WriteM = DebugCSRHitM & CSRWriteM & InstrValidM & ~StallW & ~FlushW;

  // Privilege modes that dcsr.prv accepts
  logic PrvLegal;
  assign PrvLegal = CSRWriteValM[1:0] == P.M_MODE | CSRWriteValM[1:0] == P.S_MODE & P.S_SUPPORTED |
                    CSRWriteValM[1:0] == P.U_MODE & P.U_SUPPORTED;

  always_ff @(posedge clk)
    if (reset) begin
      EBreakM <= 1'b0; EBreakS <= 1'b0; EBreakU <= 1'b0; StepIE <= 1'b0; Step <= 1'b0;
      Cause <= '0; DCSRPrv <= P.M_MODE; DPC <= '0; DScratch0 <= '0; DScratch1 <= '0;
    end else if (DebugEnterM & Taken) begin
      Cause <= NextCause;
      DCSRPrv <= PrivilegeModeW;
      DPC <= PCM;
    end else if (WriteM)
      case (CSRAdrM)
        DCSR: begin
          EBreakM <= CSRWriteValM[15];
          EBreakS <= CSRWriteValM[13] & P.S_SUPPORTED;
          EBreakU <= CSRWriteValM[12] & P.U_SUPPORTED;
          StepIE  <= CSRWriteValM[11];
          Step    <= CSRWriteValM[2];
          if (PrvLegal) DCSRPrv <= CSRWriteValM[1:0];
        end
        DPCADR:    DPC <= P.ZCA_SUPPORTED ? {CSRWriteValM[P.XLEN-1:1], 1'b0} : {CSRWriteValM[P.XLEN-1:2], 2'b00};
        DSCRATCH0: DScratch0 <= CSRWriteValM;
        DSCRATCH1: DScratch1 <= CSRWriteValM;
        default: ;
      endcase
endmodule
