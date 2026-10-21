///////////////////////////////////////////
// pmucountercontrol.sv
//
// Purpose: Optional counter privilege filters, increments, and overflow requests.
//          The counter and selector CSR storage remains in csrc.sv.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module pmucountercontrol import cvw::*; #(
  parameter cvw_t P,
  parameter int HPMEVENTTOP = P.COUNTERS > 3 ? int'(P.COUNTERS) - 1 : 3
) (
  input  logic                    clk, reset,
  input  logic                    CSRMWriteM, CSRSWriteM,
  input  logic [11:0]             CSRAdrM,
  input  logic [4:0]              SelectedCounterM,
  input  logic [P.XLEN-1:0]       CSRWriteValM,
  input  logic [1:0]              PrivilegeModeW,
  input  logic [31:0]             MCOUNTINHIBIT_REGW, MCOUNTEREN_REGW,
  input  logic [P.XLEN-1:0]       SISELECT_REGW,
  input  logic                    CounterDelegationEnabled,
  input  logic [31:0]             CounterEvent,
  input  logic [1:0]              CounterEventMode[31:0],
  input  logic [P.XLEN-1:0]       HPMCOUNTER_REGW[P.COUNTERS-1:0],
  input  logic [P.XLEN-1:0]       HPMCOUNTERH_REGW[P.COUNTERS-1:0],
  input  logic [63:0]             MHPMEVENT_REGW[HPMEVENTTOP:3],
  input  logic [63:0]             HPMCOUNTERPlusM[P.COUNTERS-1:0],
  input  logic [P.COUNTERS-1:0]   WriteHPMCOUNTERM, WriteHPMCOUNTERHM,
  output logic [63:0]             MCYCLECFG_REGW, MINSTRETCFG_REGW,
  output logic [P.COUNTERS-1:0]   CounterInc, CounterOverflow,
  output logic [31:0]             VisibleOverflowFlags,
  output logic                    LCOFIPSetM,
  output logic                    WriteSIREGM, WriteSIREG2M, WriteSIREG4M, WriteSIREG5M,
  output logic                    IndirectCSRAdrM, IndirectIllegalM,
  output logic [P.XLEN-1:0]       IndirectReadValM
);

  localparam MCYCLECFG = 12'h321;
  localparam MINSTRETCFG = 12'h322;
  localparam MCYCLECFGH = 12'h721;
  localparam MINSTRETCFGH = 12'h722;
  localparam SIREG = 12'h151;
  localparam SIREG2 = 12'h152;
  localparam SIREG3 = 12'h153;
  localparam SIREG4 = 12'h155;
  localparam SIREG5 = 12'h156;
  localparam SIREG6 = 12'h157;
  localparam logic [63:0] MCNTRCFG_MASK = 64'h4000_0000_0000_0000 |
                                          (P.S_SUPPORTED ? 64'h2000_0000_0000_0000 : 64'b0) |
                                          (P.U_SUPPORTED ? 64'h1000_0000_0000_0000 : 64'b0);
  logic [63:0] MCNTRCFGWriteValM, MCYCLECFGNextM, MINSTRETCFGNextM;
  logic WriteMCYCLECFGM, WriteMINSTRETCFGM;
  logic DelegatedCounterM;
  logic [31:0] OverflowFlags;

  function automatic logic CountModeEnabled(input logic [63:0] cfg, input logic [1:0] mode);
    return !P.SMCNTRPMF_SUPPORTED |
           (mode == P.M_MODE & ~cfg[62]) |
           (mode == P.S_MODE & ~cfg[61]) |
           (mode == P.U_MODE & ~cfg[60]);
  endfunction

  // RV32 exposes the filter bits through the high CSR half only.
  assign MCNTRCFGWriteValM = (P.XLEN == 64) ? 64'(CSRWriteValM) : {CSRWriteValM[31:0], 32'b0};
  assign DelegatedCounterM = P.SMCDELEG_SUPPORTED & CounterDelegationEnabled &
      (SISELECT_REGW >= P.XLEN'('h40)) & (SISELECT_REGW <= P.XLEN'('h5f)) &
      (SelectedCounterM != 5'd1) & (12'(SelectedCounterM) < P.COUNTERS) &
      MCOUNTEREN_REGW[SelectedCounterM] &
      ((SelectedCounterM < 3) ? P.ZICNTR_SUPPORTED : P.ZIHPM_SUPPORTED);
  assign WriteSIREGM  = CSRSWriteM & DelegatedCounterM & CSRAdrM == SIREG;
  assign WriteSIREG2M = CSRSWriteM & DelegatedCounterM & CSRAdrM == SIREG2 &
                         (SelectedCounterM >= 3 | P.SMCNTRPMF_SUPPORTED);
  assign WriteSIREG4M = CSRSWriteM & DelegatedCounterM & (P.XLEN == 32) & CSRAdrM == SIREG4;
  assign WriteSIREG5M = CSRSWriteM & DelegatedCounterM & (P.XLEN == 32) & CSRAdrM == SIREG5 &
                         ((SelectedCounterM >= 3 & P.SSCOFPMF_SUPPORTED) |
                          (SelectedCounterM < 3 & P.SMCNTRPMF_SUPPORTED));
  assign IndirectCSRAdrM = P.SMCDELEG_SUPPORTED &
                           (CSRAdrM == SIREG | CSRAdrM == SIREG2 | CSRAdrM == SIREG3 |
                            CSRAdrM == SIREG4 | CSRAdrM == SIREG5 | CSRAdrM == SIREG6);
  always_comb begin
    IndirectReadValM = '0;
    IndirectIllegalM = 1'b1;
    if (DelegatedCounterM & (CSRAdrM == SIREG |
        (CSRAdrM == SIREG2 & (SelectedCounterM >= 3 | P.SMCNTRPMF_SUPPORTED)) |
        (P.XLEN == 32 & CSRAdrM == SIREG4) |
        (P.XLEN == 32 & CSRAdrM == SIREG5 &
         ((SelectedCounterM >= 3 & P.SSCOFPMF_SUPPORTED) |
          (SelectedCounterM < 3 & P.SMCNTRPMF_SUPPORTED))))) begin
      IndirectIllegalM = 1'b0;
      /* verilator lint_off WIDTH */
      if (CSRAdrM == SIREG) IndirectReadValM = HPMCOUNTER_REGW[SelectedCounterM];
      else if (CSRAdrM == SIREG4) IndirectReadValM = HPMCOUNTERH_REGW[SelectedCounterM];
      else if (SelectedCounterM >= 3) begin
        if (CSRAdrM == SIREG2)
          IndirectReadValM = MHPMEVENT_REGW[SelectedCounterM][P.XLEN-1:0] & ~(P.XLEN'(1) << 62);
        else IndirectReadValM = P.XLEN'(MHPMEVENT_REGW[SelectedCounterM][63:32] & 32'hBFFFFFFF);
      end else if (CSRAdrM == SIREG2)
        IndirectReadValM = (SelectedCounterM == 0 ? MCYCLECFG_REGW[P.XLEN-1:0] :
                            MINSTRETCFG_REGW[P.XLEN-1:0]) & ~(P.XLEN'(1) << 62);
      else IndirectReadValM = P.XLEN'((SelectedCounterM == 0 ?
                            MCYCLECFG_REGW[63:32] : MINSTRETCFG_REGW[63:32]) & 32'hBFFFFFFF);
      /* verilator lint_on WIDTH */
    end
  end
  always_comb begin
    MCYCLECFGNextM = MCNTRCFGWriteValM & MCNTRCFG_MASK;
    MINSTRETCFGNextM = MCNTRCFGWriteValM & MCNTRCFG_MASK;
    if (WriteSIREG2M | WriteSIREG5M) begin
      MCYCLECFGNextM[62] = MCYCLECFG_REGW[62];
      MINSTRETCFGNextM[62] = MINSTRETCFG_REGW[62];
    end
  end
  assign WriteMCYCLECFGM = P.SMCNTRPMF_SUPPORTED & CSRMWriteM &
                           ((P.XLEN == 64 & CSRAdrM == MCYCLECFG) | (P.XLEN == 32 & CSRAdrM == MCYCLECFGH)) |
                           (((P.XLEN == 64 & WriteSIREG2M) | WriteSIREG5M) & SelectedCounterM == 0);
  assign WriteMINSTRETCFGM = P.SMCNTRPMF_SUPPORTED & CSRMWriteM &
                             ((P.XLEN == 64 & CSRAdrM == MINSTRETCFG) | (P.XLEN == 32 & CSRAdrM == MINSTRETCFGH)) |
                             (((P.XLEN == 64 & WriteSIREG2M) | WriteSIREG5M) & SelectedCounterM == 2);
  if (P.SMCNTRPMF_SUPPORTED) begin : mcntrcfg
    always_ff @(posedge clk)
      if (reset) begin
        MCYCLECFG_REGW <= '0;
        MINSTRETCFG_REGW <= '0;
      end else begin
        if (WriteMCYCLECFGM) MCYCLECFG_REGW <= MCYCLECFGNextM;
        if (WriteMINSTRETCFGM) MINSTRETCFG_REGW <= MINSTRETCFGNextM;
      end
  end else begin : mcntrcfg
    assign MCYCLECFG_REGW = '0;
    assign MINSTRETCFG_REGW = '0;
  end

  for (genvar i = 0; i < P.COUNTERS; i++) begin : counter
    if (i == 0) assign CounterInc[i] = CounterEvent[i] & ~MCOUNTINHIBIT_REGW[i] & CountModeEnabled(MCYCLECFG_REGW, PrivilegeModeW);
    else if (i == 2) assign CounterInc[i] = CounterEvent[i] & ~MCOUNTINHIBIT_REGW[i] & CountModeEnabled(MINSTRETCFG_REGW, PrivilegeModeW);
    else if (i < 3) assign CounterInc[i] = CounterEvent[i] & ~MCOUNTINHIBIT_REGW[i];
    else begin
      // The event selector must be enabled independently of its mode controls.
      assign CounterInc[i] = CounterEvent[i] & ~MCOUNTINHIBIT_REGW[i] &
                             (P.SSCOFPMF_SUPPORTED ? (MHPMEVENT_REGW[i][55:0] != 0) : (MHPMEVENT_REGW[i][P.XLEN-1:0] != 0)) &
                             (~P.SSCOFPMF_SUPPORTED | (CounterEventMode[i] == P.M_MODE & ~MHPMEVENT_REGW[i][62]) |
                             (CounterEventMode[i] == P.S_MODE & ~MHPMEVENT_REGW[i][61]) |
                             (CounterEventMode[i] == P.U_MODE & ~MHPMEVENT_REGW[i][60]));
      assign CounterOverflow[i] = P.SSCOFPMF_SUPPORTED & CounterInc[i] & (HPMCOUNTERPlusM[i] == 0) &
                                  ~WriteHPMCOUNTERM[i] & ~WriteHPMCOUNTERHM[i];
    end
    if (i < 3) assign CounterOverflow[i] = 1'b0;
  end

  assign OverflowFlags[2:0] = '0;
  for (genvar i = 3; i < 32; i++) begin : overflowflags
    if (i < P.COUNTERS) assign OverflowFlags[i] = MHPMEVENT_REGW[i][63];
    else                assign OverflowFlags[i] = 1'b0;
  end
  assign LCOFIPSetM = |(CounterOverflow & ~OverflowFlags[P.COUNTERS-1:0]);
  assign VisibleOverflowFlags = OverflowFlags & ((PrivilegeModeW == P.M_MODE) ? 32'hFFFFFFFF : MCOUNTEREN_REGW);
endmodule
