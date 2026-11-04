///////////////////////////////////////////
// ahbdebugarb.sv
//
// Purpose: Lets the Debug Module's System Bus Access share the AHB with the core, without
//          adding latency to the core, and routes the core's accesses to the Debug Module's
//          memory (0x0-0xFFF, see dm.sv) to the Debug Module instead of the uncore.  The core
//          owns the bus; when the DM requests it, the arbiter waits for a cycle in which the bus is free (no data phase still waiting and
//          no new address phase from the core), takes the address phase for the DM and holds
//          the core's HREADY low until the DM's transfer completes.
//
//          This relies on the core's bus masters (busfsm, buscachefsm, ahbmulticore): they hold
//          their address phase while HREADY is low (busfsm and buscachefsm only start one with
//          HREADY high), leave an idle cycle between accesses, and issue an atomic's write
//          right after its read (HMASTLOCK), so a grant never splits a locked sequence or a
//          burst.  DM accesses are single transfers.
//
//          A core held in reset by the DM's hartreset still presents its first fetch (busfsm sits
//          in its address phase with the request up), which would keep the DM from the bus:
//          wallypipelinedsoc silences the held core's HTRANS, so that the DM can load the program
//          it is to fetch.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module ahbdebugarb import cvw::*; #(parameter cvw_t P) (
  input  logic                  HCLK, HRESETn,
  // Core
  input  logic [P.PA_BITS-1:0]  CoreHADDR,
  input  logic [P.AHBW-1:0]     CoreHWDATA,
  input  logic [P.XLEN/8-1:0]   CoreHWSTRB,
  input  logic                  CoreHWRITE,
  input  logic [2:0]            CoreHSIZE, CoreHBURST,
  input  logic [3:0]            CoreHPROT,
  input  logic [1:0]            CoreHTRANS,
  input  logic                  CoreHMASTLOCK,
  output logic                  CoreHREADY,
  output logic [P.AHBW-1:0]     CoreHRDATA,
  // Debug Module
  input  logic [P.PA_BITS-1:0]  DbgHADDR,
  input  logic [P.AHBW-1:0]     DbgHWDATA,
  input  logic [P.XLEN/8-1:0]   DbgHWSTRB,
  input  logic                  DbgHWRITE,
  input  logic [2:0]            DbgHSIZE,
  input  logic [1:0]            DbgHTRANS,
  output logic                  DbgHREADY,
  // Debug Module memory: the core's transfers to 0x0-0xFFF, served with no wait states
  output logic                  DMHSEL,
  input  logic [P.AHBW-1:0]     DMHRDATA,
  // To the uncore
  output logic [P.PA_BITS-1:0]  HADDR,
  output logic [P.AHBW-1:0]     HWDATA,
  output logic [P.XLEN/8-1:0]   HWSTRB,
  output logic                  HWRITE,
  output logic [2:0]            HSIZE, HBURST,
  output logic [3:0]            HPROT,
  output logic [1:0]            HTRANS,
  output logic                  HMASTLOCK,
  input  logic                  HREADY,
  input  logic [P.AHBW-1:0]     HRDATA
);

  logic DbgGrant;      // the DM owns the address phase, and the core waits
  logic DbgData;       // the data phase on the bus is the DM's
  logic CoreLocked;    // inside a locked (atomic) sequence of the core
  logic [1:0] CoreTrans;
  logic       DMData;          // the data phase on the bus is the core's, from the Debug Module memory
  assign CoreTrans = CoreHTRANS;
  assign DMHSEL = ~DbgGrant & CoreTrans[1] & CoreHADDR < P.PA_BITS'(12'hFFF) + 1;

  // Grant at an edge where the bus is free: the previous data phase completes (HREADY), the
  // core starts no address phase and holds no lock
  always_ff @(posedge HCLK)
    if (~HRESETn) begin
      DbgGrant <= 1'b0; DbgData <= 1'b0; CoreLocked <= 1'b0; DMData <= 1'b0;
    end else begin
      if (!DbgGrant && HREADY && DbgHTRANS[1] && !CoreTrans[1] && !CoreHMASTLOCK && !CoreLocked)
        DbgGrant <= 1'b1;
      else if (DbgData && HREADY)
        DbgGrant <= 1'b0;
      if (HREADY) begin
        DbgData <= DbgGrant && DbgHTRANS[1] && !DbgData;
        DMData <= DMHSEL;
        // A master keeps HMASTLOCK through every cycle of a locked sequence, idle ones too
        if (!DbgGrant) CoreLocked <= CoreHMASTLOCK;
      end
    end

  assign CoreHREADY = DbgGrant ? 1'b0 : HREADY;
  assign DbgHREADY  = DbgGrant ? HREADY : 1'b0;

  always_comb
    if (DbgGrant) begin
      HADDR = DbgHADDR; HWRITE = DbgHWRITE; HSIZE = DbgHSIZE; HBURST = 3'b000;
      HPROT = 4'b0011; HTRANS = DbgData ? 2'b00 : DbgHTRANS; HMASTLOCK = 1'b0;
    end else begin
      HADDR = CoreHADDR; HWRITE = CoreHWRITE; HSIZE = CoreHSIZE; HBURST = CoreHBURST;
      HPROT = CoreHPROT; HTRANS = DMHSEL ? 2'b00 : CoreTrans; HMASTLOCK = CoreHMASTLOCK;
    end
  assign HWDATA = DbgData ? DbgHWDATA : CoreHWDATA;
  assign HWSTRB = DbgData ? DbgHWSTRB : CoreHWSTRB;
  assign CoreHRDATA = DMData ? DMHRDATA : HRDATA;
endmodule
