///////////////////////////////////////////
// dm.sv
//
// Purpose: RISC-V Debug Module (RISC-V Debug Specification 1.0, chapter 3) for one hart, with
//          System Bus Access.  The hart has no debug mode yet: it cannot halt, so the DM offers
//          no abstract commands (abstractcs.datacount and progbufsize are 0, and a command
//          fails with cmderr 2, not supported) and never reports the hart halted.  What it
//          offers:
//          - System Bus Access (sbcs, sbaddress0/1, sbdata0/1): reads and writes of 8 to 32
//            bits (64 with a 64-bit bus) anywhere on the AHB, with auto-increment and
//            read-on-address/read-on-data, as an AHB-Lite master that ahbdebugarb merges with
//            the core's bus.
//          - hartreset: holds the core in reset while the memories and peripherals keep running,
//            so that a debugger can load a program through System Bus Access and start it.
//          - ndmreset: resets the whole SoC except the DTM and this module.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module dm import cvw::*; #(parameter cvw_t P) (
  input  logic                  clk,
  input  logic                  reset,        // power-on reset only: ndmreset must not reset the DM
  // DMI from the DTM
  input  logic                  DMIReq,
  input  logic [6:0]            DMIAddr,
  input  logic [31:0]           DMIWData,
  input  logic                  DMIWrite,
  output logic [31:0]           DMIRData,
  output logic                  DMIError,
  // Resets
  output logic                  NDMReset,     // the SoC, except the DTM and DM
  output logic                  HartReset,    // the core
  // System Bus Access: AHB-Lite master
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

  // data0 (0x04) and hartinfo (0x12) read 0: no abstract commands, no data registers
  localparam logic [6:0] DMCONTROL = 7'h10, DMSTATUS = 7'h11,
                         ABSTRACTCS = 7'h16, COMMAND = 7'h17, SBCS = 7'h38, SBADDRESS0 = 7'h39,
                         SBADDRESS1 = 7'h3A, SBDATA0 = 7'h3C, SBDATA1 = 7'h3D;
  localparam int unsigned LANES = P.AHBW/8;
  localparam int unsigned OFFSETBITS = $clog2(LANES);

  logic        DMActive, HaveReset;
  logic [2:0]  CmdErr;
  logic        SBBusyError, SBReadOnAddr, SBAutoIncrement, SBReadOnData;
  logic [2:0]  SBAccess, SBError;
  logic [63:0] SBAddress, SBData;
  logic        SBBusy, SBStart, SBStartWrite, SBDone;
  logic        Write, Read;

  typedef enum logic [1:0] {SB_IDLE, SB_ADDR, SB_DATA} sbstate_t;
  sbstate_t    SBState;

  assign Write = DMIReq &  DMIWrite;
  assign Read  = DMIReq & ~DMIWrite;
  assign DMIError = 1'b0;
  assign SBBusy = SBState != SB_IDLE;

  ///////////////////////////////////////////////////////////////
  // Register reads
  ///////////////////////////////////////////////////////////////

  logic        Unavail;
  logic [31:0] DMControl, DMStatus, AbstractCS, SBCS_r;
  assign Unavail = NDMReset | HartReset;   // the hart is in reset
  // dmcontrol: hartreset, ndmreset, dmactive; hartsel reads 0 (one hart); haltreq reads 0
  assign DMControl  = {2'b0, HartReset, 27'b0, NDMReset, DMActive};
  // dmstatus: ndmresetpending, allhavereset/anyhavereset, unavail or running (never halted),
  // authenticated, version 3 (1.0)
  assign DMStatus   = {7'b0, NDMReset, 1'b0, 1'b0, 2'b0, {2{HaveReset}}, 2'b0, 2'b0, {2{Unavail}},
                       {2{~Unavail}}, 2'b0, 1'b1, 1'b0, 1'b0, 1'b0, 4'd3};
  // abstractcs: progbufsize 0, busy 0, cmderr, datacount 0
  assign AbstractCS = {3'b0, 5'd0, 11'b0, 1'b0, 1'b0, CmdErr, 4'b0, 4'd0};
  // sbcs: sbversion 1, sbbusyerror, sbbusy, sbreadonaddr, sbaccess, sbautoincrement,
  // sbreadondata, sberror, sbasize, the access sizes the bus supports
  assign SBCS_r     = {3'd1, 6'b0, SBBusyError, SBBusy, SBReadOnAddr, SBAccess, SBAutoIncrement,
                       SBReadOnData, SBError, 7'(P.PA_BITS), 1'b0, P.AHBW == 64, 3'b111};

  always_comb
    case (DMIAddr)
      DMCONTROL:  DMIRData = DMControl;
      DMSTATUS:   DMIRData = DMStatus;
      ABSTRACTCS: DMIRData = AbstractCS;
      SBCS:       DMIRData = SBCS_r;
      SBADDRESS0: DMIRData = SBAddress[31:0];
      SBADDRESS1: DMIRData = P.PA_BITS > 32 ? SBAddress[63:32] : 32'b0;
      SBDATA0:    DMIRData = SBData[31:0];
      SBDATA1:    DMIRData = P.AHBW == 64 ? SBData[63:32] : 32'b0;
      default:    DMIRData = 32'b0;                   // data0, hartinfo, command and the rest
    endcase

  ///////////////////////////////////////////////////////////////
  // System Bus Access requests
  ///////////////////////////////////////////////////////////////

  // An access starts on a write of sbaddress0 with sbreadonaddr (read), a write of sbdata0
  // (write), or a read of sbdata0 with sbreadondata (read), unless the bus is busy (which sets
  // sbbusyerror) or an error is pending.
  logic SBAccessBusy, SBRequest, SBRequestWrite, SBNoErrors, SBSizeOK, SBAligned;
  logic [63:0] NewAddress;
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
  assign SBStart = SBRequest && SBSizeOK && SBAligned;
  assign SBStartWrite = SBRequestWrite;

  ///////////////////////////////////////////////////////////////
  // Register writes and state
  ///////////////////////////////////////////////////////////////

  logic [P.AHBW-1:0] LaneData;
  logic [63:0]       ReadData;
  logic [OFFSETBITS-1:0] Offset;
  assign Offset = SBAddress[OFFSETBITS-1:0];
  // Read data right-justified, from the byte lanes of the address
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
    if (reset || (Write && DMIAddr == DMCONTROL && !DMIWData[0])) begin
      // Power-on reset, or dmactive written 0: reset the module
      DMActive <= 1'b0;
      NDMReset <= 1'b0; HartReset <= 1'b0; CmdErr <= '0;
      if (reset) HaveReset <= 1'b1;
      SBBusyError <= 1'b0; SBReadOnAddr <= 1'b0; SBAccess <= 3'd2; SBAutoIncrement <= 1'b0;
      SBReadOnData <= 1'b0; SBError <= '0; SBAddress <= '0; SBData <= '0;
      SBState <= SB_IDLE; SBHWRITE <= 1'b0;
    end else begin
      // The hart is reset again whenever hartreset or ndmreset hold it
      if (Unavail) HaveReset <= 1'b1;
      if (Write && DMIAddr == DMCONTROL) begin
        DMActive  <= 1'b1;
        NDMReset  <= DMIWData[1];
        HartReset <= DMIWData[29];
        if (DMIWData[28]) HaveReset <= 1'b0;            // ackhavereset
      end
      if (DMActive) begin
        if (Write && DMIAddr == ABSTRACTCS) CmdErr <= CmdErr & ~DMIWData[10:8];
        if (Write && DMIAddr == COMMAND && CmdErr == 3'd0) CmdErr <= 3'd2;   // not supported
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
        if (SBRequest && !SBSizeOK)                  SBError <= 3'd4;
        else if (SBRequest && !SBAligned)            SBError <= 3'd3;
        if (SBStart) begin
          SBState  <= SB_ADDR;
          SBHWRITE <= SBStartWrite;
        end
        if (SBState == SB_ADDR && SBHREADY) SBState <= SB_DATA;
        if (SBDone) begin
          SBState <= SB_IDLE;
          if (SBHRESP) SBError <= 3'd2;              // bad address
          else begin
            if (!SBHWRITE) SBData <= ReadData;
            if (SBAutoIncrement) SBAddress <= SBAddress + (64'b1 << SBAccess);
          end
        end
      end
    end

  ///////////////////////////////////////////////////////////////
  // AHB-Lite master: single transfers
  ///////////////////////////////////////////////////////////////

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
