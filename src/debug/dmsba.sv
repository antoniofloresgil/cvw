///////////////////////////////////////////
// dmsba.sv
//
// Purpose: System Bus Access of the Debug Module (RISC-V Debug Specification 1.0, 3.10): sbcs,
//          sbaddress0/1 and sbdata0/1, and an AHB-Lite master doing single transfers of 8 to 32
//          bits (64 with a 64-bit bus), with auto-increment and read-on-address/read-on-data.
//          An access starts on a write of sbaddress0 with sbreadonaddr (read), a write of sbdata0
//          (write), or a read of sbdata0 with sbreadondata (read).  An address that no region on
//          the bus decodes, as the PMA checker sees it, fails with sberror 2 without a transfer.
//          ahbdebugarb merges this master with the core's bus.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module dmsba import cvw::*; #(parameter cvw_t P) (
  input  logic                  clk,
  input  logic                  reset,        // power-on reset, or dmactive written 0
  input  logic                  DMActive,
  // DMI accesses to the System Bus Access registers
  input  logic                  Write, Read,
  input  logic [6:0]            DMIAddr,
  input  logic [31:0]           DMIWData,
  output logic [31:0]           DMIRData,     // for SBCS, SBADDRESS0/1 and SBDATA0/1, else 0
  // AHB-Lite master
  output logic [P.PA_BITS-1:0]  SBHADDR,
  output logic [P.AHBW-1:0]     SBHWDATA,
  output logic [P.AHBW/8-1:0]   SBHWSTRB,
  output logic                  SBHWRITE,
  output logic [2:0]            SBHSIZE,
  output logic [1:0]            SBHTRANS,
  input  logic                  SBHREADY,
  input  logic [P.AHBW-1:0]     SBHRDATA,
  input  logic                  SBHRESP
);

  localparam logic [6:0] SBCS = 7'h38, SBADDRESS0 = 7'h39, SBADDRESS1 = 7'h3A, SBDATA0 = 7'h3C, SBDATA1 = 7'h3D;
  localparam int unsigned LANES = P.AHBW/8;
  localparam int unsigned OFFSETBITS = $clog2(LANES);

  logic        SBBusyError, SBReadOnAddr, SBAutoIncrement, SBReadOnData;
  logic [2:0]  SBAccess, SBError;
  logic [63:0] SBAddress, SBData;
  logic        SBBusy, SBStart, SBStartWrite, SBDone;

  typedef enum logic [1:0] {SB_IDLE, SB_ADDR, SB_DATA} sbstate_t;
  sbstate_t    SBState;

  assign SBBusy = SBState != SB_IDLE;

  // sbcs: sbversion 1, sbbusyerror, sbbusy, sbreadonaddr, sbaccess, sbautoincrement,
  // sbreadondata, sberror, sbasize, the access sizes the bus supports
  always_comb
    case (DMIAddr)
      SBCS:       DMIRData = {3'd1, 6'b0, SBBusyError, SBBusy, SBReadOnAddr, SBAccess, SBAutoIncrement,
                              SBReadOnData, SBError, 7'(P.PA_BITS), 1'b0, P.AHBW == 64, 3'b111};
      SBADDRESS0: DMIRData = SBAddress[31:0];
      SBADDRESS1: DMIRData = P.PA_BITS > 32 ? SBAddress[63:32] : 32'b0;
      SBDATA0:    DMIRData = SBData[31:0];
      SBDATA1:    DMIRData = P.AHBW == 64 ? SBData[63:32] : 32'b0;
      default:    DMIRData = 32'b0;
    endcase

  // A request while an access is under way sets sbbusyerror; none starts while an error is pending
  logic SBAccessBusy, SBRequest, SBRequestWrite, SBNoErrors, SBSizeOK, SBAligned, SBAddressOK;
  logic [63:0] NewAddress;
  logic [12:0] SelRegions;
  assign SBAccessBusy = DMActive && SBBusy &&
    ((Write && (DMIAddr == SBADDRESS0 || DMIAddr == SBADDRESS1 || DMIAddr == SBDATA0 || DMIAddr == SBDATA1)) ||
     (Read && (DMIAddr == SBDATA0 || DMIAddr == SBDATA1)));
  assign SBNoErrors = !SBBusyError && SBError == 3'd0;
  assign SBRequestWrite = Write && DMIAddr == SBDATA0;
  assign SBRequest = DMActive && !SBBusy && SBNoErrors &&
    ((Write && DMIAddr == SBADDRESS0 && SBReadOnAddr) || SBRequestWrite ||
     (Read && DMIAddr == SBDATA0 && SBReadOnData));
  assign NewAddress = Write && DMIAddr == SBADDRESS0 ? {SBAddress[63:32], DMIWData} : SBAddress;
  assign SBSizeOK = SBAccess <= 3'd2 || (SBAccess == 3'd3 && P.AHBW == 64);
  assign SBAligned = (NewAddress[2:0] & ((3'b1 << SBAccess) - 3'b1)) == 3'b0;
  // The uncore completes an access to an unmapped address without an error (the hart's PMA
  // checker faults it first), so decode the address as the PMA checker does: a region on the bus
  // (not the core's DTIM or IROM) that supports the access and its size, else sberror 2
  adrdecs #(P) adrdecs(NewAddress[P.PA_BITS-1:0], 1'b1, ~SBRequestWrite, 1'b1, SBAccess[1:0], SelRegions);
  assign SBAddressOK = |SelRegions[12:3] && (P.PA_BITS == 64 || NewAddress >> P.PA_BITS == 64'b0);
  assign SBStart = SBRequest && SBSizeOK && SBAligned && SBAddressOK;
  assign SBStartWrite = SBRequestWrite;

  // Read data right-justified, from the byte lanes of the address
  logic [P.AHBW-1:0]     LaneData;
  logic [63:0]           ReadData;
  logic [OFFSETBITS-1:0] Offset;
  assign Offset = SBAddress[OFFSETBITS-1:0];
  assign LaneData = SBHRDATA >> (8 * Offset);
  always_comb
    case (SBAccess)
      3'd0:    ReadData = 64'(LaneData[7:0]);
      3'd1:    ReadData = 64'(LaneData[15:0]);
      3'd2:    ReadData = 64'(LaneData[31:0]);
      default: ReadData = 64'(LaneData);
    endcase
  assign SBDone = SBState == SB_DATA && SBHREADY;

  always_ff @(posedge clk)
    if (reset) begin
      SBBusyError <= 1'b0; SBReadOnAddr <= 1'b0; SBAccess <= 3'd2; SBAutoIncrement <= 1'b0;
      SBReadOnData <= 1'b0; SBError <= '0; SBAddress <= '0; SBData <= '0;
      SBState <= SB_IDLE; SBHWRITE <= 1'b0;
    end else if (DMActive) begin
      if (Write && DMIAddr == SBCS) begin
        if (DMIWData[22]) SBBusyError <= 1'b0;
        SBReadOnAddr    <= DMIWData[20];
        SBAccess        <= DMIWData[19:17];
        SBAutoIncrement <= DMIWData[16];
        SBReadOnData    <= DMIWData[15];
        SBError         <= SBError & ~DMIWData[14:12];
      end
      if (SBAccessBusy) SBBusyError <= 1'b1;
      else begin
        if (Write && DMIAddr == SBADDRESS0) SBAddress[31:0] <= DMIWData;
        if (Write && DMIAddr == SBADDRESS1 && P.PA_BITS > 32) SBAddress[63:32] <= DMIWData;
        if (Write && DMIAddr == SBDATA0) SBData[31:0] <= DMIWData;
        if (Write && DMIAddr == SBDATA1 && P.AHBW == 64) SBData[63:32] <= DMIWData;
      end
      if (SBRequest && !SBSizeOK)       SBError <= 3'd4;     // size not supported
      else if (SBRequest && !SBAligned) SBError <= 3'd3;     // misaligned
      else if (SBRequest && !SBAddressOK) SBError <= 3'd2;   // bad address
      if (SBStart) begin
        SBState  <= SB_ADDR;
        SBHWRITE <= SBStartWrite;
      end
      if (SBState == SB_ADDR && SBHREADY) SBState <= SB_DATA;
      if (SBDone) begin
        SBState <= SB_IDLE;
        if (SBHRESP) SBError <= 3'd2;                        // bus error
        else begin
          if (!SBHWRITE) SBData <= ReadData;
          if (SBAutoIncrement) SBAddress <= SBAddress + (64'b1 << SBAccess);
        end
      end
    end

  // AHB-Lite master: single transfers, data replicated on every byte lane
  logic [P.AHBW-1:0] Replicated;
  always_comb
    case (SBAccess)
      3'd0:    Replicated = {LANES{SBData[7:0]}};
      3'd1:    Replicated = {(LANES/2){SBData[15:0]}};
      3'd2:    Replicated = {(LANES/4){SBData[31:0]}};
      default: Replicated = SBData[P.AHBW-1:0];
    endcase
  assign SBHADDR  = SBAddress[P.PA_BITS-1:0];
  assign SBHSIZE  = SBAccess;
  assign SBHTRANS = SBState == SB_ADDR ? 2'b10 : 2'b00;   // NONSEQ until the address phase is taken
  assign SBHWDATA = Replicated;
  assign SBHWSTRB = LANES'(((16'b1 << (1 << SBAccess)) - 16'b1) << Offset);
endmodule
