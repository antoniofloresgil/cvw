///////////////////////////////////////////
// pmuevents.sv
//
// Purpose: Fixed Wally performance events and their privilege-mode tags.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module pmuevents import cvw::*; #(parameter cvw_t P) (
  input  logic       clk, reset,
  input  logic       StallE, StallM, StallW, FlushM,
  input  logic       InstrValidNotFlushedM, LoadStallD, StoreStallD,
  input  logic       CSRWriteM, BPDirWrongM, BTAWrongM, RASPredPCWrongM,
  input  logic       IClassWrongM, BPWrongM,
  input  logic [3:0] IClassM,
  input  logic       DCacheMiss, DCacheAccess, ICacheMiss, ICacheAccess,
  input  logic       ICacheStallF, DCacheStallM,
  input  logic       sfencevmaM, InterruptM, TrapM, InvalidateICacheM,
  input  logic       DivBusyE, FDivBusyE,
  input  logic [1:0] PrivilegeModeW,
  output logic [31:0] CounterEvent,
  output logic [1:0]  CounterEventMode[31:0]
);

  logic LoadStallE, LoadStallM, StoreStallE, StoreStallM;

  // Keep the existing stall-event pipeline aligned with its mode metadata.
  flopenrc #(1) LoadStallEReg(.clk, .reset, .clear(1'b0), .en(~StallE), .d(LoadStallD), .q(LoadStallE));
  flopenrc #(1) LoadStallMReg(.clk, .reset, .clear(FlushM), .en(~StallM), .d(LoadStallE), .q(LoadStallM));
  flopenrc #(1) StoreStallEReg(.clk, .reset, .clear(1'b0), .en(~StallE), .d(StoreStallD), .q(StoreStallE));
  flopenrc #(1) StoreStallMReg(.clk, .reset, .clear(FlushM), .en(~StallM), .d(StoreStallE), .q(StoreStallM));

  // Only Sscofpmf needs these tags; the disabled configuration adds no registers.
  if (P.SSCOFPMF_SUPPORTED) begin : eventmodetag
    logic [1:0] LoadStallModeE, LoadStallModeM;
    logic [1:0] StoreStallModeE, StoreStallModeM;
    logic [1:0] ICacheOwnerMode, DCacheOwnerMode, DivideOwnerMode;
    logic ICacheStallPrev, DCacheStallPrev, DivideBusyPrev;
    logic DivideBusy;

    flopenrc #(2) LoadStallModeEReg(.clk, .reset, .clear(1'b0), .en(~StallE), .d(PrivilegeModeW), .q(LoadStallModeE));
    flopenrc #(2) LoadStallModeMReg(.clk, .reset, .clear(FlushM), .en(~StallM), .d(LoadStallModeE), .q(LoadStallModeM));
    flopenrc #(2) StoreStallModeEReg(.clk, .reset, .clear(1'b0), .en(~StallE), .d(PrivilegeModeW), .q(StoreStallModeE));
    flopenrc #(2) StoreStallModeMReg(.clk, .reset, .clear(FlushM), .en(~StallM), .d(StoreStallModeE), .q(StoreStallModeM));
    assign DivideBusy = DivBusyE | FDivBusyE;
    always_ff @(posedge clk) begin
      if (reset | FlushM) begin
        ICacheStallPrev <= 1'b0;
        DCacheStallPrev <= 1'b0;
        DivideBusyPrev <= 1'b0;
        ICacheOwnerMode <= P.M_MODE;
        DCacheOwnerMode <= P.M_MODE;
        DivideOwnerMode <= P.M_MODE;
      end else begin
        ICacheStallPrev <= ICacheStallF;
        DCacheStallPrev <= DCacheStallM;
        DivideBusyPrev <= DivideBusy;
        if (ICacheStallF & ~ICacheStallPrev) ICacheOwnerMode <= PrivilegeModeW;
        if (DCacheStallM & ~DCacheStallPrev) DCacheOwnerMode <= PrivilegeModeW;
        if (DivideBusy & ~DivideBusyPrev) DivideOwnerMode <= PrivilegeModeW;
      end
    end
    always_comb begin
      for (int eventnum = 0; eventnum < 32; eventnum++) CounterEventMode[eventnum] = PrivilegeModeW;
      CounterEventMode[11] = LoadStallModeM;
      CounterEventMode[12] = StoreStallModeM;
      CounterEventMode[14] = DCacheStallPrev ? DCacheOwnerMode : PrivilegeModeW;
      CounterEventMode[15] = DCacheStallPrev ? DCacheOwnerMode : PrivilegeModeW;
      CounterEventMode[17] = ICacheStallPrev ? ICacheOwnerMode : PrivilegeModeW;
      CounterEventMode[18] = ICacheStallPrev ? ICacheOwnerMode : PrivilegeModeW;
      CounterEventMode[24] = DivideBusyPrev ? DivideOwnerMode : PrivilegeModeW;
    end
  end else begin : eventmodetag
    for (genvar eventnum = 0; eventnum < 32; eventnum++) begin : unfiltered
      assign CounterEventMode[eventnum] = PrivilegeModeW;
    end
  end

  // Keep these counter numbers aligned with linux/pmu/events.py; the map is
  // still duplicated until the event-catalog cleanup is done.
  assign CounterEvent[0] = 1'b1;
  assign CounterEvent[1] = 1'b0;
  assign CounterEvent[2] = InstrValidNotFlushedM;
  if (P.COUNTERS > 3) begin : events
    assign CounterEvent[3]  = IClassM[0] & InstrValidNotFlushedM;
    assign CounterEvent[4]  = IClassM[1] & ~IClassM[2] & InstrValidNotFlushedM;
    assign CounterEvent[5]  = IClassM[2] & InstrValidNotFlushedM;
    assign CounterEvent[6]  = BPWrongM & InstrValidNotFlushedM;
    assign CounterEvent[7]  = BPDirWrongM & InstrValidNotFlushedM;
    assign CounterEvent[8]  = BTAWrongM & InstrValidNotFlushedM;
    assign CounterEvent[9]  = RASPredPCWrongM & InstrValidNotFlushedM;
    assign CounterEvent[10] = IClassWrongM & InstrValidNotFlushedM;
    assign CounterEvent[11] = LoadStallM;
    assign CounterEvent[12] = StoreStallM;
    assign CounterEvent[13] = DCacheAccess;
    assign CounterEvent[14] = DCacheMiss; // refill has completed
    assign CounterEvent[15] = DCacheStallM;
    assign CounterEvent[16] = ICacheAccess;
    assign CounterEvent[17] = ICacheMiss; // refill has completed
    assign CounterEvent[18] = ICacheStallF;
    assign CounterEvent[19] = CSRWriteM & InstrValidNotFlushedM;
    assign CounterEvent[20] = InvalidateICacheM & InstrValidNotFlushedM;
    assign CounterEvent[21] = sfencevmaM & InstrValidNotFlushedM;
    assign CounterEvent[22] = TrapM & ~StallW & InterruptM;
    assign CounterEvent[23] = TrapM & ~StallW & ~InterruptM;
    assign CounterEvent[24] = DivBusyE | FDivBusyE;
    // Preserve legacy slots 3-24. These two slots implement standard perf branch aggregates.
    assign CounterEvent[25] = |IClassM[2:0] & InstrValidNotFlushedM;
    assign CounterEvent[26] = BPWrongM & |IClassM[2:0] & InstrValidNotFlushedM;
    assign CounterEvent[31:27] = '0;
  end else begin : events
    assign CounterEvent[31:3] = '0;
  end
endmodule
