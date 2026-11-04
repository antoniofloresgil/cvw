///////////////////////////////////////////
// triggers.sv
//
// Purpose: Triggers (Sdtrig, RISC-V Debug Specification 1.0, chapter 5): DEBUG_TRIGGERS triggers
//          selected with tselect and programmed with tdata1 and tdata2 (tdata3 reads 0: no
//          context matching), and tinfo.  A trigger that is free (after reset, or after a write of
//          an unsupported type or of 0) reads as mcontrol6 with every field 0, which never fires:
//          OpenOCD 0.12 skips a trigger that reads as type 15 (disabled).  Supported types:
//          - mcontrol (2) and mcontrol6 (6): the address of an instruction (execute) or of a load
//            or store, equal (match 0), NAPOT (1), greater or equal (2), less (3), and the negated
//            equal and NAPOT (8, 9); no data matching (select 0), no chaining, any access size;
//          - icount (3): fires after count instructions (or traps);
//          - itrigger (4) and etrigger (5): fire after the hart takes one of the interrupts or
//            exceptions set in tdata2, before the first instruction of the handler.
//
//          A trigger fires before the instruction in the Memory stage, at the boundaries at which
//          an interrupt can be taken, so a load or store does not reach memory.  An address match
//          on an instruction whose bus access is already under way fires instead right after it
//          retires, before the next instruction (mcontrol6 reports hit1:hit0 = 3 then, 1 before).
//          action 1 enters Debug Mode (dcsr.cause 2) and requires dmode 1.  action 0 raises a
//          breakpoint exception; csr.sv sets mtval to the pc of the instruction, as for ebreak,
//          also for a load or store match (the privileged specification asks for the data
//          address there, which would need a change in csr.sv).  In M-mode action 0 fires only
//          with mstatus.MIE set (there is no tcontrol), so that a trigger does not fire again in
//          its own handler.  icount, itrigger and etrigger support only action 1.  Triggers do not fire in
//          Debug Mode, and only Debug Mode can write a trigger with dmode 1.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module triggers import cvw::*; #(parameter cvw_t P) (
  input  logic              clk, reset,
  input  logic              StallW, FlushW,
  input  logic              DebugMode,
  input  logic [1:0]        PrivilegeModeW,
  input  logic              STATUS_MIE,
  // The instruction in the Memory stage
  input  logic [31:0]       InstrM,
  input  logic              InstrValidM,
  input  logic              CommittedM, CommittedF,      // a bus access is under way: not interruptible
  input  logic              WaitedM,                     // a wfi has waited: it retires first
  input  logic [P.XLEN-1:0] PCM,
  input  logic [P.XLEN-1:0] IEUAdrM,                     // load or store address
  // Traps
  input  logic              ArchTrapM, InterruptM,
  input  logic [4:0]        CauseM,
  // CSR accesses
  input  logic              CSRReadM, CSRWriteM,
  input  logic [P.XLEN-1:0] SrcAM,
  output logic              TrigCSRHitM,
  output logic [P.XLEN-1:0] TrigCSRReadValM,
  // A trigger fires before the instruction in the Memory stage
  output logic              TrigDebugM,                  // enter Debug Mode (action 1)
  output logic              TrigBreakM                   // breakpoint exception (action 0)
);

  localparam int unsigned N = P.DEBUG_TRIGGERS;
  localparam int unsigned SELBITS = N > 1 ? $clog2(N) : 1;
  localparam int unsigned X = P.XLEN;
  localparam logic [11:0] TSELECT = 12'h7A0, TDATA1 = 12'h7A1, TDATA2 = 12'h7A2, TDATA3 = 12'h7A3, TINFO = 12'h7A4;
  localparam logic [3:0]  MCONTROL = 4'd2, ICOUNT = 4'd3, ITRIGGER = 4'd4, ETRIGGER = 4'd5, MCONTROL6 = 4'd6;
  // tinfo: version 1 (Sdtrig 1.0), types 2 to 6 and 15
  localparam logic [31:0] TINFOVAL = {8'd1, 8'b0, 16'b1000_0000_0111_1100};

  logic [SELBITS-1:0] Sel;
  logic [3:0]  Type   [N];
  logic [3:0]  Match  [N];
  logic [13:0] Count  [N];
  logic [1:0]  Hit    [N];                                // mcontrol6 hit1:hit0; the other types use bit 0
  logic [X-1:0] TData2 [N];
  logic [N-1:0] DMode, Action, MM, SS, UU, Execute, Store, Load, Pending;
  logic [N-1:0] ModeOK, AddrMatchM, MatchM, FireBefore, FireAfter, Fire, CountM, TrapHitM;
  logic        Interruptible, Taken, RetireM, IsLoadM, IsStoreM;

  assign Taken = ~StallW;
  assign RetireM = InstrValidM & ~StallW & ~FlushW;
  // The same boundaries as an interrupt: the instruction in M has not started a bus access
  assign Interruptible = InstrValidM & ~CommittedM & ~CommittedF & ~WaitedM;

  // Loads and stores of the instruction in M (decompressed): integer, floating point, atomic
  logic [6:0] Op;
  assign Op = InstrM[6:0];
  assign IsLoadM  = Op == 7'b0000011 | Op == 7'b0000111 | Op == 7'b0101111 & InstrM[31:27] != 5'b00011;  // not sc
  assign IsStoreM = Op == 7'b0100011 | Op == 7'b0100111 | Op == 7'b0101111 & InstrM[31:27] != 5'b00010;  // not lr

  // Address comparison of mcontrol and mcontrol6; match[3] negates equal and NAPOT
  function automatic logic compare(input logic [3:0] m, input logic [X-1:0] t2, input logic [X-1:0] v);
    logic [X-1:0] dontcare;
    logic         r;
    dontcare = t2 ^ (t2 + 1'b1);       // NAPOT: the trailing ones of tdata2 and the zero above them
    case (m[1:0])
      2'd0:    r = v == t2;
      2'd1:    r = ((v ^ t2) & ~dontcare) == '0;
      2'd2:    r = v >= t2;
      default: r = v < t2;
    endcase
    return r ^ m[3];
  endfunction

  ///////////////////////////////////////////
  // Matching and firing
  ///////////////////////////////////////////

  for (genvar i = 0; i < N; i++) begin : trig
    logic AddrType;
    assign AddrType = Type[i] == MCONTROL | Type[i] == MCONTROL6;
    assign ModeOK[i] = PrivilegeModeW == P.M_MODE & MM[i] | PrivilegeModeW == P.S_MODE & SS[i] |
                       PrivilegeModeW == P.U_MODE & UU[i];
    assign AddrMatchM[i] = Execute[i] & compare(Match[i], TData2[i], PCM) |
                           (Load[i] & IsLoadM | Store[i] & IsStoreM) & compare(Match[i], TData2[i], IEUAdrM);
    // action 0 in M-mode only with interrupts enabled
    assign MatchM[i] = AddrType & ~DebugMode & InstrValidM & ModeOK[i] & AddrMatchM[i] &
                       (Action[i] | PrivilegeModeW != P.M_MODE | STATUS_MIE);
    assign FireBefore[i] = MatchM[i] & Interruptible;
    assign FireAfter[i]  = Pending[i] & Interruptible & ~DebugMode;
    assign Fire[i] = FireBefore[i] | FireAfter[i];
    // icount counts instructions that retire or trap; itrigger and etrigger the traps in tdata2
    assign CountM[i] = Type[i] == ICOUNT & ~DebugMode & ModeOK[i] & Count[i] != '0 & (RetireM | ArchTrapM & Taken);
    assign TrapHitM[i] = ~DebugMode & ArchTrapM & Taken & ModeOK[i] & TData2[i][$clog2(X)'(CauseM)] &
                         (InterruptM ? Type[i] == ITRIGGER : Type[i] == ETRIGGER);
  end

  assign TrigDebugM = |(Fire & Action);
  assign TrigBreakM = |(Fire & ~Action);

  ///////////////////////////////////////////
  // CSRs
  ///////////////////////////////////////////

  logic [11:0]  CSRAdrM;
  logic [X-1:0] CSRSrcM, V, TData1Val;
  logic         WriteM, Writable;
  assign CSRAdrM = InstrM[31:20];
  assign TrigCSRHitM = (CSRReadM | CSRWriteM) & PrivilegeModeW == P.M_MODE & CSRAdrM >= TSELECT & CSRAdrM <= TINFO;

  // tdata1 of the selected trigger, in the layout of its type
  always_comb begin
    TData1Val = '0;
    TData1Val[X-1:X-4] = Type[Sel];
    TData1Val[X-5] = DMode[Sel];
    case (Type[Sel])
      MCONTROL, MCONTROL6: begin
        if (Type[Sel] == MCONTROL) begin
          TData1Val[X-6:X-11] = 6'(X - 1);                // maskmax: NAPOT ranges of any size
          TData1Val[20] = Hit[Sel][0];
        end else
          {TData1Val[25], TData1Val[22]} = Hit[Sel];
        TData1Val[12] = Action[Sel];
        TData1Val[10:7] = Match[Sel];
        {TData1Val[6], TData1Val[4], TData1Val[3]} = {MM[Sel], SS[Sel], UU[Sel]};
        {TData1Val[2], TData1Val[1], TData1Val[0]} = {Execute[Sel], Store[Sel], Load[Sel]};
      end
      ICOUNT: begin
        TData1Val[24] = Hit[Sel][0];
        TData1Val[23:10] = Count[Sel];
        {TData1Val[9], TData1Val[8], TData1Val[7], TData1Val[6]} = {MM[Sel], Pending[Sel], SS[Sel], UU[Sel]};
        TData1Val[0] = Action[Sel];
      end
      ITRIGGER, ETRIGGER: begin
        TData1Val[X-6] = Hit[Sel][0];
        {TData1Val[9], TData1Val[7], TData1Val[6]} = {MM[Sel], SS[Sel], UU[Sel]};
        TData1Val[0] = Action[Sel];
      end
      default: ;
    endcase
  end

  always_comb
    case (CSRAdrM)
      TSELECT: TrigCSRReadValM = X'(Sel);
      TDATA1:  TrigCSRReadValM = TData1Val;
      TDATA2:  TrigCSRReadValM = TData2[Sel];
      TDATA3:  TrigCSRReadValM = '0;                     // no context matching
      TINFO:   TrigCSRReadValM = X'(TINFOVAL);
      default: TrigCSRReadValM = '0;
    endcase

  // As csr.sv: rs1 or uimm, then write, set or clear
  assign CSRSrcM = InstrM[14] ? {{(X-5){1'b0}}, InstrM[19:15]} : SrcAM;
  always_comb
    case (InstrM[13:12])
      2'b01:   V = CSRSrcM;
      2'b10:   V = TrigCSRReadValM | CSRSrcM;
      2'b11:   V = TrigCSRReadValM & ~CSRSrcM;
      default: V = TrigCSRReadValM;
    endcase
  assign WriteM = TrigCSRHitM & CSRWriteM & RetireM;
  assign Writable = ~DMode[Sel] | DebugMode;            // dmode 1: only Debug Mode writes the trigger

  // Legal values of a tdata1 write (WARL): action 1 needs dmode; icount, itrigger and etrigger
  // need action 1, else the trigger is disabled
  logic [3:0] WType, WMatch;
  logic       WDMode, WAction;
  assign WType   = V[X-1:X-4];
  assign WDMode  = V[X-5] & DebugMode;
  assign WAction = WDMode & (WType == ICOUNT | WType == ITRIGGER | WType == ETRIGGER ? V[5:0] == 6'd1 : V[15:12] == 4'd1);
  assign WMatch  = V[10:7] inside {4'd0, 4'd1, 4'd2, 4'd3, 4'd8, 4'd9} ? V[10:7] : 4'd0;

  always_ff @(posedge clk)
    if (reset) begin
      Sel <= '0;
      for (int i = 0; i < N; i++) begin
        Type[i] <= MCONTROL6; Match[i] <= '0; Count[i] <= '0; Hit[i] <= '0; TData2[i] <= '0;
      end
      {DMode, Action, MM, SS, UU, Execute, Store, Load, Pending} <= '0;
    end else begin
      for (int i = 0; i < N; i++) begin
        // Firing: hit (mcontrol6: 1 before the instruction, 3 right after the previous one)
        if (Fire[i] & Taken) begin
          Hit[i] <= FireBefore[i] ? 2'b01 : 2'b11;
          Pending[i] <= 1'b0;
        end else if (MatchM[i] & RetireM) Pending[i] <= 1'b1;   // could not fire before: fire after
        if (CountM[i]) begin
          Count[i] <= Count[i] - 1'b1;
          if (Count[i] == 14'd1) Pending[i] <= 1'b1;
        end
        if (TrapHitM[i]) Pending[i] <= 1'b1;
      end
      // CSR writes
      if (WriteM & CSRAdrM == TSELECT & V < X'(N)) Sel <= V[SELBITS-1:0];
      if (WriteM & CSRAdrM == TDATA2 & Writable) TData2[Sel] <= V;
      if (WriteM & CSRAdrM == TDATA1 & Writable) begin
        DMode[Sel] <= WDMode; Action[Sel] <= WAction; Pending[Sel] <= 1'b0;
        Match[Sel] <= '0; Count[Sel] <= '0; Hit[Sel] <= '0;
        {MM[Sel], SS[Sel], UU[Sel], Execute[Sel], Store[Sel], Load[Sel]} <= '0;
        Type[Sel] <= MCONTROL6;                            // disabled: no mode enabled
        case (WType)
          MCONTROL, MCONTROL6: begin
            Type[Sel] <= WType;
            Hit[Sel] <= WType == MCONTROL ? {1'b0, V[20]} : {V[25], V[22]};
            Match[Sel] <= WMatch;
            MM[Sel] <= V[6]; SS[Sel] <= V[4] & P.S_SUPPORTED; UU[Sel] <= V[3] & P.U_SUPPORTED;
            Execute[Sel] <= V[2];
            Store[Sel] <= V[1]; Load[Sel] <= V[0];
          end
          ICOUNT: if (WAction) begin
            Type[Sel] <= ICOUNT; Hit[Sel] <= {1'b0, V[24]}; Count[Sel] <= V[23:10]; Pending[Sel] <= V[8];
            MM[Sel] <= V[9]; SS[Sel] <= V[7] & P.S_SUPPORTED; UU[Sel] <= V[6] & P.U_SUPPORTED;
          end
          ITRIGGER, ETRIGGER: if (WAction) begin
            Type[Sel] <= WType; Hit[Sel] <= {1'b0, V[X-6]};
            MM[Sel] <= V[9]; SS[Sel] <= V[7] & P.S_SUPPORTED; UU[Sel] <= V[6] & P.U_SUPPORTED;
          end
          default: ;
        endcase
      end
    end
endmodule
