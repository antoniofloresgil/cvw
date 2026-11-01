///////////////////////////////////////////
// csri.sv
//
// Written:  David Harris David_Harris@hmc.edu 9 January 2021
// Modified: Ben Bracker, Rose Thompson, Kip Macsai-Goren, Harshini Srinath
//
// Purpose: Interrupt pending and enable CSRs.
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2021-26 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module csri import cvw::*; #(parameter cvw_t P) (
  input  logic              clk, reset,
  input  logic              CSRMWriteM, CSRSWriteM,
  input  logic [P.XLEN-1:0] CSRWriteValM,
  input  logic [11:0]       CSRAdrM,
  input  logic              MExtInt, SExtInt, MTimerInt, STimerInt, MSwInt,
  input  logic              LCOFIPSetM,
  input  logic [13:0]       MIDELEG_REGW,
  input  logic              ENVCFG_STCE,
  output logic [13:0]       MIP_REGW, MIE_REGW,
  output logic [13:0]       MIP_REGW_writeable // SEIP, STIP, SSIP and optional LCOFIP are writable
);

  logic [13:0]              MIP_WRITE_MASK, SIP_WRITE_MASK, MIE_WRITE_MASK, SIE_WRITE_MASK;
  logic                     WriteMIPM, WriteMIEM, WriteSIPM, WriteSIEM;
  logic                     STIP;
  logic                     LCOFIP;

  localparam MIE = 12'h304;
  localparam MIP = 12'h344;
  localparam SIE = 12'h104;
  localparam SIP = 12'h144;

  // Interrupt Write Enables
  assign WriteMIPM = CSRMWriteM & (CSRAdrM == MIP);
  assign WriteMIEM = CSRMWriteM & (CSRAdrM == MIE);
  assign WriteSIPM = CSRSWriteM & (CSRAdrM == SIP);
  assign WriteSIEM = CSRSWriteM & (CSRAdrM == SIE);

  // Interrupt Pending and Enable Registers
  // MEIP, MTIP, MSIP are read-only
  // SEIP, STIP, SSIP are writable in MIP if S mode exists
  // SSIP is writable in SIP if S mode exists
  if (P.S_SUPPORTED) begin : mask
    if (P.SSTC_SUPPORTED) begin
      assign MIP_WRITE_MASK = (ENVCFG_STCE ? 14'h0202 : 14'h0222) | (P.SSCOFPMF_SUPPORTED ? 14'h2000 : 14'h0); // STIP is not writable when STIMECMP is implemented
      assign STIP = ENVCFG_STCE ? STimerInt : MIP_REGW_writeable[5];
    end else begin
      assign MIP_WRITE_MASK = 14'h0222 | (P.SSCOFPMF_SUPPORTED ? 14'h2000 : 14'h0);
      assign STIP = MIP_REGW_writeable[5];
    end
    assign SIP_WRITE_MASK = (14'h0002 | (P.SSCOFPMF_SUPPORTED ? 14'h2000 : 14'h0)) & MIDELEG_REGW;
    assign MIE_WRITE_MASK = 14'h0AAA | (P.SSCOFPMF_SUPPORTED ? 14'h2000 : 14'h0);
    assign SIE_WRITE_MASK = (14'h0222 | (P.SSCOFPMF_SUPPORTED ? 14'h2000 : 14'h0)) & MIDELEG_REGW;
  end else begin : mask
    assign MIP_WRITE_MASK = 14'h0000;
    assign SIP_WRITE_MASK = 14'h0000;
    assign MIE_WRITE_MASK = 14'h0888; // MEIE, MTIE, MSIE
    assign SIE_WRITE_MASK = 14'h0000;
    assign STIP = '0;
  end
  always_ff @(posedge clk)
    if (reset)          MIP_REGW_writeable <= 14'b0;
    else if (WriteMIPM) MIP_REGW_writeable <= (CSRWriteValM[13:0] & MIP_WRITE_MASK) | (P.SSCOFPMF_SUPPORTED ? {LCOFIPSetM, 13'b0} : 14'b0);
    else if (WriteSIPM) MIP_REGW_writeable <= (CSRWriteValM[13:0] & SIP_WRITE_MASK) | (MIP_REGW_writeable & ~SIP_WRITE_MASK) | (P.SSCOFPMF_SUPPORTED ? {LCOFIPSetM, 13'b0} : 14'b0);
    else if (P.SSCOFPMF_SUPPORTED & LCOFIPSetM) MIP_REGW_writeable[13] <= 1'b1;
  always_ff @(posedge clk)
    if (reset)          MIE_REGW <= 14'b0;
    else if (WriteMIEM) MIE_REGW <= (CSRWriteValM[13:0] & MIE_WRITE_MASK); // MIE controls M and S fields
    else if (WriteSIEM) MIE_REGW <= (CSRWriteValM[13:0] & SIE_WRITE_MASK) | (MIE_REGW & ~SIE_WRITE_MASK); // only S fields

  assign LCOFIP = P.SSCOFPMF_SUPPORTED & MIP_REGW_writeable[13];
  assign MIP_REGW = {LCOFIP, 1'b0, MExtInt,   1'b0, SExtInt | MIP_REGW_writeable[9], 1'b0,
                     MTimerInt, 1'b0, STIP,                            1'b0,
                     MSwInt,    1'b0, MIP_REGW_writeable[1],           1'b0};
endmodule
