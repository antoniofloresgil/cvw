///////////////////////////////////////////
// dtm.sv
//
// Purpose: JTAG Debug Transport Module (RISC-V Debug Specification 1.0, chapter 6).
//          A JTAG TAP with a 5-bit IR (IDCODE, DTMCS, DMI, BYPASS) in the TCK domain, and the
//          Debug Module Interface (DMI) to the Debug Module in the system clock domain.
//
//          The DMI crosses domains with a toggle handshake: an Update-DR of dmi with op read or
//          write registers the request and flips ReqToggle; the system clock domain
//          synchronizes the toggle, serves the request in one cycle and flips RespToggle, which
//          the TCK domain synchronizes back.  Request and response registers hold still while
//          their toggle crosses.  A dmi scan before the response arrives reports busy (op 3),
//          sticky until dmireset, as the specification asks; dtmcs.idle tells the debugger how
//          many Run-Test/Idle cycles to leave after each request.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module dtm #(
  parameter logic [31:0] IDCODE = 32'h0000_0001,  // version, part number, manufacturer, 1
  parameter int unsigned ABITS = 7                // DMI address bits
)(
  // JTAG
  input  logic             TRSTn,       // asynchronous TAP reset: the power-on reset
  input  logic             TCK, TMS, TDI,
  output logic             TDO,
  // DMI, in the system clock domain
  input  logic             clk,
  input  logic             reset,
  output logic             DMIReq,      // one cycle per request
  output logic [ABITS-1:0] DMIAddr,
  output logic [31:0]      DMIWData,
  output logic             DMIWrite,    // 1: write, 0: read
  input  logic [31:0]      DMIRData,    // read data in the cycle of DMIReq
  input  logic             DMIError     // the request failed (op 2)
);

  localparam int unsigned DMIW = ABITS + 34;

  typedef enum logic [3:0] {
    TEST_LOGIC_RESET, RUN_TEST_IDLE, SELECT_DR, CAPTURE_DR, SHIFT_DR, EXIT1_DR, PAUSE_DR, EXIT2_DR,
    UPDATE_DR, SELECT_IR, CAPTURE_IR, SHIFT_IR, EXIT1_IR, PAUSE_IR, EXIT2_IR, UPDATE_IR
  } tapstate_t;

  localparam logic [4:0] IR_IDCODE = 5'h01, IR_DTMCS = 5'h10, IR_DMI = 5'h11;

  tapstate_t        State, NextState;
  logic [4:0]       IR, IRShift;
  logic [DMIW-1:0]  DR, Capture;
  logic [1:0]       Stat;                     // sticky dmistat: 0 ok, 2 failed, 3 busy
  logic             ReqToggle, RespToggle, RespToggleSync, Pending;
  logic [ABITS-1:0] ReqAddr, NewAddr;
  logic [31:0]      ReqData, RespData, NewData, DTMCS;
  logic [1:0]       ReqOp, NewOp;
  logic             RespError, DTMCSWrite, DMIUpdate, DMICapture, PendingD;

  ///////////////////////////////////////////////////////////////
  // TAP controller (IEEE 1149.1)
  ///////////////////////////////////////////////////////////////

  always_comb
    case (State)
      TEST_LOGIC_RESET: NextState = TMS ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
      RUN_TEST_IDLE:    NextState = TMS ? SELECT_DR : RUN_TEST_IDLE;
      SELECT_DR:        NextState = TMS ? SELECT_IR : CAPTURE_DR;
      CAPTURE_DR:       NextState = TMS ? EXIT1_DR : SHIFT_DR;
      SHIFT_DR:         NextState = TMS ? EXIT1_DR : SHIFT_DR;
      EXIT1_DR:         NextState = TMS ? UPDATE_DR : PAUSE_DR;
      PAUSE_DR:         NextState = TMS ? EXIT2_DR : PAUSE_DR;
      EXIT2_DR:         NextState = TMS ? UPDATE_DR : SHIFT_DR;
      UPDATE_DR:        NextState = TMS ? SELECT_DR : RUN_TEST_IDLE;
      SELECT_IR:        NextState = TMS ? TEST_LOGIC_RESET : CAPTURE_IR;
      CAPTURE_IR:       NextState = TMS ? EXIT1_IR : SHIFT_IR;
      SHIFT_IR:         NextState = TMS ? EXIT1_IR : SHIFT_IR;
      EXIT1_IR:         NextState = TMS ? UPDATE_IR : PAUSE_IR;
      PAUSE_IR:         NextState = TMS ? EXIT2_IR : PAUSE_IR;
      EXIT2_IR:         NextState = TMS ? UPDATE_IR : SHIFT_IR;
      UPDATE_IR:        NextState = TMS ? SELECT_DR : RUN_TEST_IDLE;
      default:          NextState = TEST_LOGIC_RESET;
    endcase

  always_ff @(posedge TCK, negedge TRSTn)
    if (~TRSTn) State <= TEST_LOGIC_RESET;
    else        State <= NextState;

  // Instruction register: IDCODE after reset; unknown instructions select BYPASS
  always_ff @(posedge TCK, negedge TRSTn)
    if (~TRSTn) begin
      IR <= IR_IDCODE;
      IRShift <= '0;
    end else begin
      if (State == TEST_LOGIC_RESET) IR <= IR_IDCODE;
      else if (State == UPDATE_IR)   IR <= IRShift;
      if (State == CAPTURE_IR)       IRShift <= 5'b00001;
      else if (State == SHIFT_IR)    IRShift <= {TDI, IRShift[4:1]};
    end

  ///////////////////////////////////////////////////////////////
  // Data registers: one shift register, LSB first; a register of n bits uses DR[n-1:0]
  ///////////////////////////////////////////////////////////////

  // dtmcs: errinfo 0 (not implemented), dmihardreset, dmireset, idle 2, dmistat, abits, version 1
  assign DTMCS = {11'b0, 3'b0, 1'b0, 1'b0, 1'b0, 3'd2, Stat, 6'(ABITS), 4'd1};
  assign {NewAddr, NewData, NewOp} = DR;

  always_comb
    case (IR)
      IR_IDCODE: Capture = DMIW'(IDCODE);
      IR_DTMCS:  Capture = DMIW'(DTMCS);
      // Address of the last request, its read data, and the status (busy while it runs)
      IR_DMI:    Capture = {ReqAddr, RespData, Pending ? 2'd3 : Stat};
      default:   Capture = '0;                    // BYPASS: one bit, 0
    endcase

  always_ff @(posedge TCK, negedge TRSTn)
    if (~TRSTn) DR <= '0;
    else if (State == CAPTURE_DR) DR <= Capture;
    else if (State == SHIFT_DR)
      case (IR)
        IR_IDCODE, IR_DTMCS: DR <= DMIW'({TDI, DR[31:1]});
        IR_DMI:              DR <= {TDI, DR[DMIW-1:1]};
        default:             DR <= DMIW'(TDI);
      endcase

  // TDO changes on the falling edge of TCK
  always_ff @(negedge TCK, negedge TRSTn)
    if (~TRSTn)                 TDO <= 1'b0;
    else if (State == SHIFT_IR) TDO <= IRShift[0];
    else if (State == SHIFT_DR) TDO <= DR[0];
    else                        TDO <= 1'b0;

  ///////////////////////////////////////////////////////////////
  // DMI requests in the TCK domain
  ///////////////////////////////////////////////////////////////

  synchronizer respsync(.clk(TCK), .d(RespToggle), .q(RespToggleSync));
  assign Pending    = ReqToggle != RespToggleSync;
  assign DTMCSWrite = State == UPDATE_DR && IR == IR_DTMCS;
  assign DMICapture = State == CAPTURE_DR && IR == IR_DMI;
  assign DMIUpdate  = State == UPDATE_DR && IR == IR_DMI && (NewOp == 2'd1 || NewOp == 2'd2);

  always_ff @(posedge TCK, negedge TRSTn)
    if (~TRSTn) begin
      ReqToggle <= 1'b0; ReqAddr <= '0; ReqData <= '0; ReqOp <= '0; Stat <= '0; PendingD <= 1'b0;
    end else begin
      PendingD <= Pending;
      // dmireset and dmihardreset clear the sticky status; a request in flight still completes.
      // A scan while a request runs is busy; a failed request is sticky once its response arrives.
      if (DTMCSWrite && (DR[16] || DR[17]))                Stat <= '0;
      else if ((DMICapture || DMIUpdate) && Pending)        Stat <= 2'd3;
      else if (PendingD && !Pending && RespError && Stat == 2'd0) Stat <= 2'd2;
      if (DMIUpdate && !Pending && Stat == 2'd0) begin
        ReqAddr <= NewAddr; ReqData <= NewData; ReqOp <= NewOp;
        ReqToggle <= ~ReqToggle;
      end
    end

  ///////////////////////////////////////////////////////////////
  // DMI requests in the system clock domain
  ///////////////////////////////////////////////////////////////

  logic ReqToggleSync, ReqToggleSeen;
  synchronizer reqsync(.clk, .d(ReqToggle), .q(ReqToggleSync));
  assign DMIReq   = ReqToggleSync != ReqToggleSeen;
  assign DMIAddr  = ReqAddr;
  assign DMIWData = ReqData;
  assign DMIWrite = ReqOp == 2'd2;

  always_ff @(posedge clk)
    if (reset) begin
      ReqToggleSeen <= 1'b0; RespToggle <= 1'b0; RespData <= '0; RespError <= 1'b0;
    end else if (DMIReq) begin
      ReqToggleSeen <= ReqToggleSync;
      RespData <= DMIWrite ? '0 : DMIRData;
      RespError <= DMIError;
      RespToggle <= ReqToggleSync;
    end
endmodule
