///////////////////////////////////////////
// csrc.sv
//
// Written: David_Harris@hmc.edu 9 January 2021
// Modified:
//
// Purpose: Counter CSRs
//          See RISC-V Privileged Mode Specification 20190608 3.1.10-11
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module csrc import cvw::*; #(parameter cvw_t P) (
  input  logic              clk, reset,
  input  logic              StallE, StallM, StallW,
  input  logic              FlushM,
  input  logic              InstrValidNotFlushedM, LoadStallD, StoreStallD,
  input  logic              CSRMWriteM, CSRSWriteM, CSRWriteM,
  input  logic              BPDirWrongM,
  input  logic              BTAWrongM,
  input  logic              RASPredPCWrongM,
  input  logic              IClassWrongM,
  input  logic              BPWrongM,                                  // branch predictor is wrong
  input  logic [3:0]        IClassM,
  input  logic              DCacheMiss,
  input  logic              DCacheAccess,
  input  logic              ICacheMiss,
  input  logic              ICacheAccess,
  input  logic              ICacheStallF,
  input  logic              DCacheStallM,
  input  logic              sfencevmaM,
  input  logic              InterruptM,
  input  logic              TrapM,                                     // trap is occurring
  input  logic              InvalidateICacheM,
  input  logic              DivBusyE,                                  // integer divide busy
  input  logic              FDivBusyE,                                 // floating point divide busy
  input  logic [11:0]       CSRAdrM,
  input  logic [1:0]        PrivilegeModeW,
  input  logic [P.XLEN-1:0] CSRWriteValM,
  input  logic [31:0]       MCOUNTINHIBIT_REGW, MCOUNTEREN_REGW, SCOUNTEREN_REGW,
  input  logic [P.XLEN-1:0] SISELECT_REGW,
  input  logic              CounterDelegationEnabled,
  input  logic [63:0]       MTIME_CLINT,
  output logic [P.XLEN-1:0] CSRCReadValM,
  output logic              IllegalCSRCAccessM,
  output logic              LCOFIPSetM
);

  localparam MHPMCOUNTERBASE  = 12'hB00;
  localparam MTIME            = 12'hB01;               // this is a memory-mapped register; no such CSR exists, and access should fault
  localparam MHPMCOUNTERHBASE = 12'hB80;
  localparam MTIMEH           = 12'hB81;               // this is a memory-mapped register; no such CSR exists, and access should fault
  localparam MCYCLECFG        = 12'h321;
  localparam MINSTRETCFG      = 12'h322;
  localparam MCYCLECFGH       = 12'h721;
  localparam MINSTRETCFGH     = 12'h722;
  localparam MHPMEVENTBASE    = 12'h323;
  localparam MHPMEVENTLAST    = 12'h33F;
  localparam MHPMEVENTHBASE   = 12'h723;
  localparam MHPMEVENTHLAST   = 12'h73F;
  localparam SCOUNTOVF        = 12'hDA0;
  // SystemVerilog has no zero-width array, so keep one unused element when no hpmevents exist
  localparam HPMEVENTTOP      = P.COUNTERS > 3 ? P.COUNTERS - 1 : 3;
  localparam HPMCOUNTERBASE   = 12'hC00;
  localparam HPMCOUNTERHBASE  = 12'hC80;
  localparam TIME             = 12'hC01;
  localparam TIMEH            = 12'hC81;

  logic [4:0]              CounterNumM;
  logic [4:0]              SelectedCounterM;
  logic                    WriteSIREGM, WriteSIREG2M, WriteSIREG4M, WriteSIREG5M;
  logic                    IndirectCSRAdrM, IndirectIllegalM;
  logic [P.XLEN-1:0]       IndirectReadValM;
  logic [P.XLEN-1:0]       HPMCOUNTER_REGW[P.COUNTERS-1:0];
  logic [P.XLEN-1:0]       HPMCOUNTERH_REGW[P.COUNTERS-1:0];
  logic [63:0]             MHPMEVENT_REGW[HPMEVENTTOP:3];
  logic [63:0]             MCYCLECFG_REGW, MINSTRETCFG_REGW;
  logic [P.COUNTERS-1:0]   WriteHPMCOUNTERM;
  logic [P.COUNTERS-1:0]   WriteHPMCOUNTERHM;
  logic [HPMEVENTTOP:3]    WriteMHPMEVENTM;
  logic [HPMEVENTTOP:3]    WriteMHPMEVENTHM;
  logic [31:0]             VisibleOverflowFlags;
  logic [P.COUNTERS-1:0]   CounterOverflow;
  logic [31:0]             CounterEvent; // keep all events here even if P.COUNTERS < 32
  logic [1:0]              CounterEventMode[31:0];
  logic [P.COUNTERS-1:0]   CounterInc;
  logic [63:0]             HPMCOUNTERPlusM[P.COUNTERS-1:0];
  logic [P.XLEN-1:0]       NextHPMCOUNTERHM[P.COUNTERS-1:0];
  logic [P.XLEN-1:0]       NextHPMCOUNTERM[P.COUNTERS-1:0];
  logic [63:0]             NextMHPMEVENTM[HPMEVENTTOP:3];

  genvar                   i;

  assign SelectedCounterM = SISELECT_REGW[4:0];
  pmuevents #(P) events(
    .clk, .reset, .StallE, .StallM, .StallW, .FlushM,
    .InstrValidNotFlushedM, .LoadStallD, .StoreStallD, .CSRWriteM,
    .BPDirWrongM, .BTAWrongM, .RASPredPCWrongM, .IClassWrongM, .BPWrongM,
    .IClassM, .DCacheMiss, .DCacheAccess, .ICacheMiss, .ICacheAccess,
    .ICacheStallF, .DCacheStallM, .sfencevmaM, .InterruptM, .TrapM,
    .InvalidateICacheM, .DivBusyE, .FDivBusyE, .PrivilegeModeW,
    .CounterEvent, .CounterEventMode);

  pmucountercontrol #(P) control(
    .clk, .reset, .CSRMWriteM, .CSRSWriteM,
    .CSRAdrM, .SelectedCounterM, .CSRWriteValM, .PrivilegeModeW,
    .MCOUNTINHIBIT_REGW, .MCOUNTEREN_REGW, .SISELECT_REGW,
    .CounterDelegationEnabled, .CounterEvent, .CounterEventMode,
    .HPMCOUNTER_REGW, .HPMCOUNTERH_REGW, .MHPMEVENT_REGW,
    .HPMCOUNTERPlusM, .WriteHPMCOUNTERM, .WriteHPMCOUNTERHM,
    .MCYCLECFG_REGW, .MINSTRETCFG_REGW, .CounterInc, .CounterOverflow,
    .VisibleOverflowFlags, .LCOFIPSetM,
    .WriteSIREGM, .WriteSIREG2M, .WriteSIREG4M, .WriteSIREG5M,
    .IndirectCSRAdrM, .IndirectIllegalM, .IndirectReadValM);

  // Counter update and write logic
  for (i = 0; i < P.COUNTERS; i = i + 1) begin : cntr
    assign WriteHPMCOUNTERM[i] = (CSRMWriteM & (CSRAdrM == MHPMCOUNTERBASE + i)) |
                                 (WriteSIREGM & SelectedCounterM == i); // coverage tag: MTIME traps
    assign NextHPMCOUNTERM[i][P.XLEN-1:0] = WriteHPMCOUNTERM[i] ? CSRWriteValM : HPMCOUNTERPlusM[i][P.XLEN-1:0];
    always_ff @(posedge clk)
      if (reset) HPMCOUNTER_REGW[i][P.XLEN-1:0] <= '0;
      else       HPMCOUNTER_REGW[i][P.XLEN-1:0] <= NextHPMCOUNTERM[i];

    if (P.XLEN == 32) begin // write high and low separately
      assign HPMCOUNTERPlusM[i] = {HPMCOUNTERH_REGW[i], HPMCOUNTER_REGW[i]} + {63'b0, CounterInc[i]};
      assign WriteHPMCOUNTERHM[i] = (CSRMWriteM & (CSRAdrM == MHPMCOUNTERHBASE + i)) |
                                    (WriteSIREG4M & SelectedCounterM == i);
      assign NextHPMCOUNTERHM[i] = WriteHPMCOUNTERHM[i] ? CSRWriteValM : HPMCOUNTERPlusM[i][63:32];
      always_ff @(posedge clk)
        if (reset) HPMCOUNTERH_REGW[i][P.XLEN-1:0] <= '0;
        else       HPMCOUNTERH_REGW[i][P.XLEN-1:0] <= NextHPMCOUNTERHM[i];
    end else begin // XLEN=64; write entire register
      assign HPMCOUNTERPlusM[i] = HPMCOUNTER_REGW[i] + {63'b0, CounterInc[i]};
      assign HPMCOUNTERH_REGW[i] = '0; // disregard for RV64
      assign WriteHPMCOUNTERHM[i] = 1'b0;
    end
  end

  // hpmevent update and write logic
  if (P.COUNTERS > 3) begin : mhpmeventgen
    for (i = 3; i < P.COUNTERS; i = i + 1) begin : mhpmevent
      assign WriteMHPMEVENTM[i] = (CSRMWriteM & (CSRAdrM == MHPMEVENTBASE + i - 3)) |
                                  (WriteSIREG2M & SelectedCounterM == i);
      assign WriteMHPMEVENTHM[i] = P.SSCOFPMF_SUPPORTED & (P.XLEN == 32) &
                                   ((CSRMWriteM & (CSRAdrM == MHPMEVENTHBASE + i - 3)) |
                                    (WriteSIREG5M & SelectedCounterM == i));
      always_comb begin
        NextMHPMEVENTM[i] = MHPMEVENT_REGW[i];
        if (WriteMHPMEVENTM[i]) NextMHPMEVENTM[i][P.XLEN-1:0] = CSRWriteValM;
        if (WriteMHPMEVENTHM[i]) NextMHPMEVENTM[i][63:32] = CSRWriteValM[31:0];
        if (WriteSIREG2M | WriteSIREG5M)
          NextMHPMEVENTM[i][62] = MHPMEVENT_REGW[i][62]; // S-mode cannot change MINH
        // OF is sticky on a hardware overflow and software-writable. VS/VU and
        // reserved fields are hardwired zero because Wally has no H extension.
        if (P.SSCOFPMF_SUPPORTED) begin
          NextMHPMEVENTM[i][59:56] = '0;
          if (!P.S_SUPPORTED) NextMHPMEVENTM[i][61] = 1'b0;
          if (!P.U_SUPPORTED) NextMHPMEVENTM[i][60] = 1'b0;
          // A hardware increment still wins if software writes the selector in this cycle.
          if (CounterOverflow[i]) NextMHPMEVENTM[i][63] = 1'b1;
        end
      end
      always_ff @(posedge clk)
        if (reset) MHPMEVENT_REGW[i] <= '0;
        else       MHPMEVENT_REGW[i] <= NextMHPMEVENTM[i];
    end
  end else begin : mhpmeventgen // no hpmevents exist; drive the placeholder element HPMEVENTTOP reserves
    assign WriteMHPMEVENTM = '0;
    assign WriteMHPMEVENTHM = '0;
    assign NextMHPMEVENTM[3] = '0;
    assign MHPMEVENT_REGW[3] = '0;
  end

  // Read Counters, or cause exception if insufficient privilege in light of COUNTEREN flags
  assign CounterNumM = CSRAdrM[4:0]; // which counter to read?
  always_comb begin
    CSRCReadValM = '0; // default value
    IllegalCSRCAccessM = 1'b0;
    if (P.SSCOFPMF_SUPPORTED & P.S_SUPPORTED & CSRAdrM == SCOUNTOVF) begin
      if (CSRWriteM | PrivilegeModeW == P.U_MODE) IllegalCSRCAccessM = 1'b1;
      else CSRCReadValM = P.XLEN'(VisibleOverflowFlags);
    end
    else if (IndirectCSRAdrM) begin
      CSRCReadValM = IndirectReadValM;
      IllegalCSRCAccessM = IndirectIllegalM;
    end
    else if (P.SMCNTRPMF_SUPPORTED & PrivilegeModeW == P.M_MODE &
             (CSRAdrM == MCYCLECFG | CSRAdrM == MINSTRETCFG)) begin
      CSRCReadValM = (CSRAdrM == MCYCLECFG) ? MCYCLECFG_REGW[P.XLEN-1:0] : MINSTRETCFG_REGW[P.XLEN-1:0];
    end
    else if (P.SMCNTRPMF_SUPPORTED & (P.XLEN == 32) & PrivilegeModeW == P.M_MODE &
             (CSRAdrM == MCYCLECFGH | CSRAdrM == MINSTRETCFGH)) begin
      CSRCReadValM = (CSRAdrM == MCYCLECFGH) ? P.XLEN'(MCYCLECFG_REGW[63:32]) : P.XLEN'(MINSTRETCFG_REGW[63:32]);
    end
    else if (PrivilegeModeW == P.M_MODE & (CSRAdrM >= MHPMEVENTBASE & CSRAdrM <= MHPMEVENTLAST)) begin
      if (CSRAdrM < MHPMEVENTBASE+P.COUNTERS-3) CSRCReadValM = MHPMEVENT_REGW[CounterNumM][P.XLEN-1:0];
      else CSRCReadValM = '0; // unused event selectors are read-only zero
    end
    else if (P.SSCOFPMF_SUPPORTED & (P.XLEN == 32) & PrivilegeModeW == P.M_MODE &
             (CSRAdrM >= MHPMEVENTHBASE & CSRAdrM <= MHPMEVENTHLAST)) begin
      if (CSRAdrM < MHPMEVENTHBASE+P.COUNTERS-3) CSRCReadValM = P.XLEN'(MHPMEVENT_REGW[CounterNumM][63:32]);
      else CSRCReadValM = '0;
    end
    else if (PrivilegeModeW == P.M_MODE |
      MCOUNTEREN_REGW[CounterNumM] & (!P.S_SUPPORTED | PrivilegeModeW == P.S_MODE | SCOUNTEREN_REGW[CounterNumM])) begin
      // The branch conditions below guarantee CounterNumM < P.COUNTERS before it indexes the
      // counter arrays, but Verilator sizes the index from the array bound, so it warns whenever
      // P.COUNTERS < 32.  This region also covers the MTIME_CLINT reads, which Verilator does not
      // realize happen only at one XLEN.
      /* verilator lint_off WIDTH */
      if (P.XLEN == 64) begin // 64-bit counter reads
        // Veri lator doesn't realize this only occurs for XLEN=64
        if      (CSRAdrM == TIME & ~CSRWriteM & P.ZICNTR_SUPPORTED)  CSRCReadValM = MTIME_CLINT; // TIME register is a shadow of the memory-mapped MTIME from the CLINT
        else if (CSRAdrM >= MHPMCOUNTERBASE & CSRAdrM < MHPMCOUNTERBASE+P.COUNTERS & CSRAdrM != MTIME)
                CSRCReadValM = HPMCOUNTER_REGW[CounterNumM];
        else if (CSRAdrM >= MHPMCOUNTERBASE+P.COUNTERS & CSRAdrM < MHPMCOUNTERBASE+32)
                CSRCReadValM = '0; // unused counters are read-only zero
        else if (CSRAdrM >= HPMCOUNTERBASE  & CSRAdrM  < HPMCOUNTERBASE+3 & ~CSRWriteM & P.ZICNTR_SUPPORTED)  // read-only
                CSRCReadValM = HPMCOUNTER_REGW[CounterNumM];
        else if (CSRAdrM >= HPMCOUNTERBASE+3  & CSRAdrM  < HPMCOUNTERBASE+P.COUNTERS & ~CSRWriteM & P.ZIHPM_SUPPORTED)  // read-only
                CSRCReadValM = HPMCOUNTER_REGW[CounterNumM];
        else if (CSRAdrM >= HPMCOUNTERBASE+P.COUNTERS  & CSRAdrM  < HPMCOUNTERBASE+32 & ~CSRWriteM & P.ZIHPM_SUPPORTED)  // read-only
                CSRCReadValM = '0;
        else IllegalCSRCAccessM = 1'b1;  // requested CSR doesn't exist
      end else begin // 32-bit counter reads
        // Veril ator doesn't realize this only occurs for XLEN=32
        if      (CSRAdrM == TIME & ~CSRWriteM & P.ZICNTR_SUPPORTED)  CSRCReadValM = MTIME_CLINT[31:0]; // TIME register is a shadow of the memory-mapped MTIME from the CLINT
        else if (CSRAdrM == TIMEH & ~CSRWriteM & P.ZICNTR_SUPPORTED) CSRCReadValM = MTIME_CLINT[63:32];
        else if (CSRAdrM >= MHPMCOUNTERBASE  & CSRAdrM < MHPMCOUNTERBASE+P.COUNTERS & CSRAdrM != MTIME)
                CSRCReadValM = HPMCOUNTER_REGW[CounterNumM];
        else if (CSRAdrM >= MHPMCOUNTERBASE+P.COUNTERS & CSRAdrM < MHPMCOUNTERBASE+32)
                CSRCReadValM = '0; // unused counters are read-only zero
        else if (CSRAdrM >= HPMCOUNTERBASE   & CSRAdrM < HPMCOUNTERBASE+3  & ~CSRWriteM & P.ZICNTR_SUPPORTED)    // read-only
                CSRCReadValM = HPMCOUNTER_REGW[CounterNumM];
        else if (CSRAdrM >= HPMCOUNTERBASE+3   & CSRAdrM < HPMCOUNTERBASE+P.COUNTERS  & ~CSRWriteM & P.ZIHPM_SUPPORTED)    // read-only
                CSRCReadValM = HPMCOUNTER_REGW[CounterNumM];
        else if (CSRAdrM >= HPMCOUNTERBASE+P.COUNTERS   & CSRAdrM < HPMCOUNTERBASE+32  & ~CSRWriteM & P.ZIHPM_SUPPORTED)    // read-only
                CSRCReadValM = '0; // unused counters are read-only zero
        else if (CSRAdrM >= MHPMCOUNTERHBASE & CSRAdrM < MHPMCOUNTERHBASE+P.COUNTERS & CSRAdrM != MTIMEH)
                CSRCReadValM = HPMCOUNTERH_REGW[CounterNumM];
        else if (CSRAdrM >= MHPMCOUNTERHBASE+P.COUNTERS & CSRAdrM < MHPMCOUNTERHBASE+32)
                CSRCReadValM = '0; // unused counters are read-only zero
        else if (CSRAdrM >= HPMCOUNTERHBASE   & CSRAdrM < HPMCOUNTERHBASE+3  & ~CSRWriteM & P.ZICNTR_SUPPORTED)   // read-only
                CSRCReadValM = HPMCOUNTERH_REGW[CounterNumM];
        else if (CSRAdrM >= HPMCOUNTERHBASE+3 & CSRAdrM < HPMCOUNTERHBASE+P.COUNTERS & ~CSRWriteM & P.ZIHPM_SUPPORTED)   // read-only
                CSRCReadValM = HPMCOUNTERH_REGW[CounterNumM];
        else if (CSRAdrM >= HPMCOUNTERHBASE+P.COUNTERS & CSRAdrM < HPMCOUNTERHBASE+32 & ~CSRWriteM & P.ZIHPM_SUPPORTED)   // read-only
                CSRCReadValM = '0;
        else    IllegalCSRCAccessM = 1'b1; // requested CSR doesn't exist
      end
      /* verilator lint_on WIDTH */
    end
    else IllegalCSRCAccessM = 1'b1; // no privileges for this csr
  end
endmodule
