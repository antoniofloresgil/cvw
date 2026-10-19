// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Buffered round-robin bridge for Wally's uncached, SINGLE-transfer masters.
// Accept each local address before stalling its data phase. This is necessary
// because busfsm gates its initial HTRANS with HREADY: grants cannot depend on
// HTRANS while HREADY is withheld. A pending hart holds write data until reply.
module ahbmulticore import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2
)(
  input  logic HCLK, HRESETn,
  input  logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR,
  input  logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA,
  input  logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB,
  input  logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK,
  input  logic [NCORES-1:0][2:0] CoreHSIZE, CoreHBURST,
  input  logic [NCORES-1:0][3:0] CoreHPROT,
  input  logic [NCORES-1:0][1:0] CoreHTRANS,
  input  logic [NCORES-1:0][1:0] CoreHATOMIC,
  output logic [NCORES-1:0] CoreSCFail,
  output logic [NCORES-1:0][P.AHBW-1:0] CoreHRDATA,
  output logic [NCORES-1:0] CoreHREADY, CoreHRESP,
  output logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] HOWNER,
  output logic [P.PA_BITS-1:0] HADDR,
  output logic [P.AHBW-1:0] HWDATA,
  output logic [P.XLEN/8-1:0] HWSTRB,
  output logic HWRITE, HMASTLOCK,
  output logic [2:0] HSIZE, HBURST,
  output logic [3:0] HPROT,
  output logic [1:0] HTRANS,
  input  logic [P.AHBW-1:0] HRDATA,
  input  logic HREADY, HRESP
);
  localparam OWNER_BITS = NCORES > 1 ? $clog2(NCORES) : 1;
  typedef enum logic [1:0] {AVAILABLE, PENDING, REPLY, ERROR_REPLY} localstate_t;
  localstate_t State[NCORES];
  logic [NCORES-1:0][P.PA_BITS-1:0] Addr;
  logic [NCORES-1:0][2:0] Size;
  logic [NCORES-1:0][3:0] Prot;
  logic [NCORES-1:0] Write;
  logic [OWNER_BITS-1:0] Owner, NextOwner, First, AddressOwner;
  localparam logic [1:0] LR = 2'b01, SC = 2'b10, AMO = 2'b11;
  localparam GRANULE_BITS = $clog2(P.XLEN/8);
  logic [NCORES-1:0][1:0] Op;
  logic [NCORES-1:0] ReservationValid;
  logic [NCORES-1:0][P.PA_BITS-1:0] ReservationAddr;
  logic [NCORES-1:0][2:0] ReservationSize;
  logic LockActive;
  logic [OWNER_BITS-1:0] LockOwner;
  logic DataPhase, Found, SCValid, FailedSC, BadAMOWrite;
  int Candidate;

  // One complete transfer at a time on the shared bus. Rotate after every
  // reply, even when a master continuously presents back-to-back transfers.
  always_comb begin
    Found = 1'b0;
    NextOwner = First;
    Candidate = 0;
    for (int offset = 0; offset < NCORES; offset++) begin
      Candidate = int'(First) + offset;
      if (Candidate >= NCORES) Candidate = Candidate - NCORES;
      if (!Found && State[Candidate] == PENDING &&
          (!LockActive || OWNER_BITS'(Candidate) == LockOwner)) begin
        NextOwner = OWNER_BITS'(Candidate);
        Found = 1'b1;
      end
    end
  end

  // Validate SC where all stores are ordered, never at local address issue.
  assign SCValid = ReservationValid[NextOwner] && ReservationAddr[NextOwner] == Addr[NextOwner] &&
                   ReservationSize[NextOwner] == Size[NextOwner];
  assign FailedSC = Op[NextOwner] == SC && !SCValid;
  assign BadAMOWrite = Op[NextOwner] == AMO && Write[NextOwner] && !LockActive;
  assign AddressOwner = DataPhase ? Owner : NextOwner;
  assign HOWNER = AddressOwner;

  always_comb begin
    HADDR = Addr[AddressOwner];
    HWRITE = Write[AddressOwner];
    HSIZE = Size[AddressOwner];
    HPROT = Prot[AddressOwner];
    HTRANS = !DataPhase && Found && !FailedSC && !BadAMOWrite && HRESETn ? 2'b10 : 2'b00;
    HBURST = 3'b000;
    HMASTLOCK = LockActive || (!DataPhase && Found && Op[NextOwner] == AMO);
    // Write data belongs to the DATA owner, never the next address owner.
    HWDATA = CoreHWDATA[Owner];
    HWSTRB = CoreHWSTRB[Owner];
    for (int h = 0; h < NCORES; h++)
      CoreHREADY[h] = HRESETn && (State[h] == AVAILABLE || State[h] == REPLY);
  end

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      DataPhase <= 1'b0;
      Owner <= '0;
      First <= '0;
      Addr <= '0;
      Size <= '0;
      Prot <= '0;
      Write <= '0;
      CoreHRDATA <= '0;
      CoreHRESP <= '0;
      CoreSCFail <= '0;
      Op <= '0;
      ReservationValid <= '0;
      ReservationAddr <= '0;
      ReservationSize <= '0;
      LockActive <= 1'b0;
      LockOwner <= '0;
      for (int h = 0; h < NCORES; h++) State[h] <= AVAILABLE;
    end else begin
      for (int h = 0; h < NCORES; h++) begin
        // Preserve AHB's two-cycle ERROR response on the local interface too.
        if (State[h] == ERROR_REPLY) State[h] <= REPLY;
        if (CoreHREADY[h]) begin
          CoreHRESP[h] <= 1'b0;
          if (CoreHTRANS[h][1]) begin
            Addr[h] <= CoreHADDR[h];
            Size[h] <= CoreHSIZE[h];
            Prot[h] <= CoreHPROT[h];
            Write[h] <= CoreHWRITE[h];
            Op[h] <= CoreHATOMIC[h];
            State[h] <= PENDING;
            assert (CoreHTRANS[h] == 2'b10 && CoreHBURST[h] == 3'b000 && !CoreHMASTLOCK[h])
              else $fatal(1, "ahbmulticore requires SINGLE transfers; atomic metadata uses HATOMIC");
          end else State[h] <= AVAILABLE;
        end
      end
      if (!DataPhase && Found && HREADY) begin
        if (Op[NextOwner] == LR || Op[NextOwner] == SC)
          ReservationValid[NextOwner] <= 1'b0;
        if (FailedSC || BadAMOWrite) begin
          // A failed conditional store never reaches RAM or a peripheral.
          if (FailedSC) CoreSCFail[NextOwner] <= 1'b1;
          CoreHRDATA[NextOwner] <= '0;
          CoreHRESP[NextOwner] <= BadAMOWrite;
          State[NextOwner] <= BadAMOWrite ? ERROR_REPLY : REPLY;
          First <= int'(NextOwner) == NCORES-1 ? '0 : NextOwner + 1'b1;
        end else begin
          Owner <= NextOwner;
          DataPhase <= 1'b1;
          if (Op[NextOwner] == AMO && !Write[NextOwner]) begin
            assert (!LockActive) else $fatal(1, "Nested AMO read");
            LockActive <= 1'b1;
            LockOwner <= NextOwner;
          end
          if (Op[NextOwner] == AMO && Write[NextOwner])
            assert (LockActive && LockOwner == NextOwner)
              else $fatal(1, "AMO write without its locked read");
        end
      end else if (DataPhase && HREADY) begin
        CoreHRDATA[Owner] <= HRDATA;
        CoreHRESP[Owner] <= HRESP;
        State[Owner] <= HRESP ? ERROR_REPLY : REPLY;
        DataPhase <= 1'b0;
        First <= int'(Owner) == NCORES-1 ? '0 : Owner + 1'b1;
        if (Op[Owner] == SC) CoreSCFail[Owner] <= HRESP;
        // Results remain sticky across IFU replies until the next SC finishes;
        // the memory stage may be waiting for an instruction fetch to retire.
        if (Op[Owner] == LR && !HRESP) begin
          ReservationValid[Owner] <= 1'b1;
          ReservationAddr[Owner] <= Addr[Owner];
          ReservationSize[Owner] <= Size[Owner];
        end
        if (Write[Owner] && !HRESP)
          for (int h = 0; h < NCORES; h++)
            if (ReservationAddr[h][P.PA_BITS-1:GRANULE_BITS] == Addr[Owner][P.PA_BITS-1:GRANULE_BITS])
              ReservationValid[h] <= 1'b0;
        if (Op[Owner] == AMO && (Write[Owner] || HRESP)) LockActive <= 1'b0;
      end
    end
  end
endmodule
