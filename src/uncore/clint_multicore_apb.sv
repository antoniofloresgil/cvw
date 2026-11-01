///////////////////////////////////////////
// clint_multicore_apb.sv
//
// Written: David_Harris@hmc.edu 14 January 2021
// Modified:
//
// Purpose: Core-Local Interruptor
//   See FE310-G002-Manual-v19p05 for specifications
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

module clint_multicore_apb import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 1
)(
  input  logic PCLK, PRESETn,
  input  logic PSEL,
  input  logic [15:0] PADDR,
  input  logic [P.XLEN-1:0] PWDATA,
  input  logic [P.XLEN/8-1:0] PSTRB,
  input  logic PWRITE, PENABLE,
  output logic [P.XLEN-1:0] PRDATA,
  output logic PREADY,
  output logic [63:0] MTIME,
  output logic [NCORES-1:0] MTimerInt, MSwInt
);
  logic [NCORES-1:0] MSIP;
  logic [NCORES-1:0][63:0] MTIMECMP;
  logic [15:0] Entry;
  logic Memwrite;
  logic [P.XLEN-1:0] ReadData;

  assign Memwrite = PWRITE && PENABLE && PSEL;
  assign PREADY = 1'b1;
  assign Entry = PADDR & (P.XLEN == 64 ? 16'hfff8 : 16'hfffc);

  // MTIME continues to use PCLK, as in the single-hart implementation.
  // Decode bytes so RV32 split accesses, RV64 paired MSIP slots and byte
  // strobes all retain their architectural address rather than aliasing hart 0.
  always_comb begin
    ReadData = '0;
    for (int b = 0; b < P.XLEN/8; b++) begin
      for (int h = 0; h < NCORES; h++) begin
        if (int'(Entry)+b == 4*h) ReadData[8*b +: 8] = {7'b0, MSIP[h]};
        for (int j = 0; j < 8; j++)
          if (int'(Entry)+b == 'h4000+8*h+j)
            ReadData[8*b +: 8] = MTIMECMP[h][8*j +: 8];
      end
      for (int j = 0; j < 8; j++)
        if (int'(Entry)+b == 'hbff8+j) ReadData[8*b +: 8] = MTIME[8*j +: 8];
    end
  end

  always_ff @(posedge PCLK) begin
    PRDATA <= ReadData;
    if (!PRESETn) begin
      MSIP <= '0;
      MTIMECMP <= '1;
      MTIME <= '0;
    end else begin
      // A write to MTIME pauses counting for that cycle; unstrobed bytes
      // retain their old values, including on RV32 split-register writes.
      if (!(Memwrite && (Entry == 16'hbff8 || (P.XLEN == 32 && Entry == 16'hbffc))))
        MTIME <= MTIME + 1'b1;
      if (Memwrite) begin
        for (int b = 0; b < P.XLEN/8; b++) begin
          if (PSTRB[b]) begin
            for (int h = 0; h < NCORES; h++) begin
              if (int'(Entry)+b == 4*h) MSIP[h] <= PWDATA[8*b];
              for (int j = 0; j < 8; j++)
                if (int'(Entry)+b == 'h4000+8*h+j)
                  MTIMECMP[h][8*j +: 8] <= PWDATA[8*b +: 8];
            end
            for (int j = 0; j < 8; j++)
              if (int'(Entry)+b == 'hbff8+j) MTIME[8*j +: 8] <= PWDATA[8*b +: 8];
          end
        end
      end
    end
  end

  assign MSwInt = MSIP;
  for (genvar h = 0; h < NCORES; h++) begin : timers
    assign MTimerInt[h] = MTIME >= MTIMECMP[h];
  end
endmodule
