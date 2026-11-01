// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Buffered round-robin bridge with optional coherent private instruction banks.
// Accept each local address before stalling its data phase. This is necessary
// because busfsm gates its initial HTRANS with HREADY: grants cannot depend on
// HTRANS while HREADY is withheld. A pending hart holds write data until reply.
// Contract and reset/error/atomic lifetime: docs/engineering/interfaces/core-bus.md.
module ahbmulticore import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter bit PRIVATE_ICACHE = 0,
  parameter int unsigned ICACHE_WORDS = 8192/(P.AHBW/8),
  parameter int unsigned ICACHE_LINE_WORDS = 1,
  parameter int unsigned DCACHE_LINE_WORDS = 1,
  parameter bit LOCAL_DCACHE_READS = 0,
  parameter bit LOCAL_DCACHE_WRITES = 0
)(
  input  logic HCLK, HRESETn,
  input  logic [NCORES-1:0] ReservationClear,
  input  logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR,
  input  logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA,
  input  logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB,
  input  logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK,
  input  logic [NCORES-1:0][2:0] CoreHSIZE, CoreHBURST,
  input  logic [NCORES-1:0][3:0] CoreHPROT,
  input  logic [NCORES-1:0][1:0] CoreHTRANS,
  input  logic [NCORES-1:0][1:0] CoreHATOMIC,
  // Bank probes use buffered physical addresses. Local M stores broadcast
  // their commit to the reservation monitor and every instruction bank.
  output logic [NCORES-1:0][P.PA_BITS-1:0] CacheReadAddr,
  input  logic [NCORES-1:0] CacheReadHit, CacheWriteHit,
  output logic [NCORES-1:0] CacheWriteCommit,
  output logic [NCORES-1:0][P.AHBW-1:0] CacheWriteData,
  output logic [NCORES-1:0][P.XLEN/8-1:0] CacheWriteStrb,
  input  logic [NCORES-1:0][P.AHBW-1:0] CacheReadData,
  output logic [NCORES-1:0] InstrMiss,           // PMU: an instruction bank starts a line fill
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
  // synopsys translate_off
  corebus_contract #(.P(P), .NCORES(NCORES)) port_contract(
    .HCLK, .HRESETn, .CoreHTRANS, .CoreHATOMIC, .CoreHBURST, .CoreHWRITE, .CoreHMASTLOCK,
    .CoreHREADY, .CoreHRESP, .CoreSCFail, .CoreHWDATA, .CoreHWSTRB, .CoreHRDATA);
  // synopsys translate_on
  typedef enum logic [1:0] {AVAILABLE, PENDING, REPLY, ERROR_REPLY} localstate_t;
  localstate_t State[NCORES];
  logic [NCORES-1:0][P.PA_BITS-1:0] Addr;
  logic [NCORES-1:0][2:0] Size;
  logic [NCORES-1:0][3:0] Prot;
  logic [NCORES-1:0] Write;
  logic [OWNER_BITS-1:0] Owner, NextOwner, First, AddressOwner;
  localparam GRANULE_BITS = $clog2(P.XLEN/8);
  logic [NCORES-1:0][1:0] Op;
  logic LockActive;
  logic [OWNER_BITS-1:0] LockOwner;
  localparam I_BEAT_BITS = ICACHE_LINE_WORDS > 1 ? $clog2(ICACHE_LINE_WORDS) : 1;
  // Conservative mixed-geometry guard covers every word in either line.
  localparam CONFLICT_BITS = GRANULE_BITS + $clog2(
    ICACHE_LINE_WORDS > DCACHE_LINE_WORDS ? ICACHE_LINE_WORDS : DCACHE_LINE_WORDS);
  logic IFillActive;
  logic [I_BEAT_BITS-1:0] IBeat;
  logic [P.AHBW-1:0] IRequestedData;
  logic IFillRequest, IFillLast;
  logic DataPhase, Found, SCValid, FailedSC, BadAMOWrite;
  int Candidate;
  logic [NCORES-1:0] LocalReply, LocalBlocked, LocalStoreConflict;
  logic [NCORES-1:0][P.AHBW-1:0] LocalData;
  assign CacheReadAddr = Addr;
  assign IFillRequest = PRIVATE_ICACHE && !Write[NextOwner] && !Prot[NextOwner][0] &&
    cacheable(Addr[NextOwner]);
  assign IFillLast = !IFillActive || int'(IBeat) == ICACHE_LINE_WORDS-1;
  assign CacheWriteData = CoreHWDATA;
  assign CacheWriteStrb = CoreHWSTRB;
  always_comb begin
    LocalStoreConflict = '0;
    for (int h = 0; h < NCORES; h++)
      for (int writer = 0; writer < NCORES; writer++)
        if (CacheWriteCommit[writer] &&
            Addr[h][P.PA_BITS-1:CONFLICT_BITS] == Addr[writer][P.PA_BITS-1:CONFLICT_BITS])
          LocalStoreConflict[h] = 1'b1;
  end
  for (genvar h = 0; h < NCORES; h++) begin : readhazards
    // Compare full physical coherence/refill regions, not bank indices.
    // A write can merge/invalidate before its bus reply; matching local reads
    // must wait through commit. Independent regions have no such dependency.
    assign LocalBlocked[h] = (DataPhase || IFillActive) && (Owner == OWNER_BITS'(h) ||
      (Write[Owner] && Addr[h][P.PA_BITS-1:CONFLICT_BITS] == Addr[Owner][P.PA_BITS-1:CONFLICT_BITS]));
    // A local store must not race ANY global access to its line: a read
    // may already have captured modified data for a writeback/intervention.
    assign CacheWriteCommit[h] = HRESETn && LOCAL_DCACHE_WRITES &&
      State[h] == PENDING && Write[h] && Prot[h][0] && Op[h] == COREBUS_NORMAL &&
      CacheWriteHit[h] && !LockActive &&
      !((DataPhase || IFillActive) && (Owner == OWNER_BITS'(h) ||
        Addr[h][P.PA_BITS-1:CONFLICT_BITS] == Addr[Owner][P.PA_BITS-1:CONFLICT_BITS]));
  end

  function automatic logic cacheable(input logic [P.PA_BITS-1:0] address);
    return multicore_cacheable(P, 64'(address));
  endfunction

  logic [NCORES-1:0] ICacheHit;
  logic [NCORES-1:0][P.AHBW-1:0] ICacheData;
  if (PRIVATE_ICACHE) begin : icache
    multicore_icache_bank #(.P(P), .NCORES(NCORES), .WORDS(ICACHE_WORDS), .LINE_WORDS(ICACHE_LINE_WORDS)) banks(
      .HCLK, .HRESETn, .ProbeAddr(Addr), .ProbeHit(ICacheHit), .ProbeData(ICacheData),
      .LocalStoreCommit(CacheWriteCommit), .LocalStoreAddr(Addr),
      .GlobalWrite(DataPhase && HREADY && !HRESP && Write[Owner]), .GlobalAddr(Addr[Owner]),
      .FillInvalidate((!DataPhase && Found && HREADY && IFillRequest) ||
        (DataPhase && HREADY && HRESP && IFillActive)),
      .FillBeat(DataPhase && HREADY && !HRESP && !Write[Owner] && !Prot[Owner][0] && cacheable(Addr[Owner])),
      .FillLast(IFillLast), .FillOwner(AddressOwner), .FillAddr(Addr[AddressOwner]), .FillWordAddr(HADDR), .FillData(HRDATA));
  end else begin : noicache
    assign ICacheHit = '0;
    assign ICacheData = '0;
  end
  always_comb begin
    for (int h = 0; h < NCORES; h++) begin
      LocalData[h] = Prot[h][0] ? CacheReadData[h] : ICacheData[h];
      LocalReply[h] = State[h] == PENDING && !Write[h] && Op[h] == COREBUS_NORMAL &&
        !LocalBlocked[h] && !LocalStoreConflict[h] &&
        (Prot[h][0] ? (LOCAL_DCACHE_READS && !LockActive && CacheReadHit[h]) : ICacheHit[h]);
    end
  end

  // Misses, permission changes and atomics share one global transfer.
  // Rotate after every global reply; local commits do not consume a grant.
  always_comb begin
    Found = 1'b0;
    NextOwner = First;
    Candidate = 0;
    for (int offset = 0; offset < NCORES; offset++) begin
      Candidate = int'(First) + offset;
      if (Candidate >= NCORES) Candidate = Candidate - NCORES;
      if (!Found && State[Candidate] == PENDING && !LocalReply[Candidate] && !CacheWriteCommit[Candidate] &&
          (!LockActive || OWNER_BITS'(Candidate) == LockOwner)) begin
        NextOwner = OWNER_BITS'(Candidate);
        Found = 1'b1;
      end
    end
    if (IFillActive) begin
      NextOwner = Owner;
      Found = 1'b1;
    end
  end

  // Validate SC where all stores are ordered, never at local address issue.
  multicore_reservations #(.P(P), .NCORES(NCORES)) reservations(
    .HCLK, .HRESETn, .QueryOwner(NextOwner), .QueryAddr(Addr[NextOwner]), .QuerySize(Size[NextOwner]),
    .QueryBlocked(LocalStoreConflict[NextOwner]), .SCValid,
    .Issue(!DataPhase && Found && HREADY), .IssueOp(Op[NextOwner]),
    .Complete(DataPhase && HREADY), .CompleteOwner(Owner), .CompleteAddr(Addr[Owner]),
    .CompleteSize(Size[Owner]), .CompleteOp(Op[Owner]), .CompleteWrite(Write[Owner]), .CompleteError(HRESP),
    .ReservationClear, .LocalStoreCommit(CacheWriteCommit), .LocalStoreAddr(Addr), .SCFail(CoreSCFail));
  assign FailedSC = Op[NextOwner] == COREBUS_SC && !SCValid;
  always_comb begin
    InstrMiss = '0;
    if (!DataPhase && Found && HREADY && !IFillActive && IFillRequest) InstrMiss[NextOwner] = 1'b1;
  end
  assign BadAMOWrite = Op[NextOwner] == COREBUS_AMO && Write[NextOwner] && !LockActive;
  assign AddressOwner = DataPhase ? Owner : NextOwner;
  assign HOWNER = AddressOwner;

  always_comb begin
    HADDR = Addr[AddressOwner];
    if (IFillActive || (!DataPhase && Found && IFillRequest))
      HADDR = ((Addr[AddressOwner] >> (GRANULE_BITS + $clog2(ICACHE_LINE_WORDS))) <<
        (GRANULE_BITS + $clog2(ICACHE_LINE_WORDS))) +
        (IFillActive ? P.PA_BITS'(IBeat) << GRANULE_BITS : '0);
    HWRITE = Write[AddressOwner];
    HSIZE = IFillActive || (!DataPhase && Found && IFillRequest) ? 3'(GRANULE_BITS) : Size[AddressOwner];
    HPROT = Prot[AddressOwner];
    HTRANS = !DataPhase && Found && !FailedSC && !BadAMOWrite && HRESETn ? 2'b10 : 2'b00;
    HBURST = 3'b000;
    HMASTLOCK = LockActive || (!DataPhase && Found && Op[NextOwner] == COREBUS_AMO);
    // Write data belongs to the DATA owner, never the next address owner.
    HWDATA = CoreHWDATA[Owner];
    HWSTRB = CoreHWSTRB[Owner];
    for (int h = 0; h < NCORES; h++)
      CoreHREADY[h] = HRESETn && (State[h] == AVAILABLE || State[h] == REPLY);
  end

  // synopsys translate_off
  logic WaitingData;
  logic [OWNER_BITS-1:0] WaitingOwner;
  logic [P.PA_BITS+3+4:0] WaitingControl;
  logic [P.PA_BITS-1:0] LockedAddr;
  logic [2:0] LockedSize;
  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      WaitingData <= 0; WaitingOwner <= '0; WaitingControl <= '0;
      LockedAddr <= '0; LockedSize <= '0;
    end else begin
      if (WaitingData)
        assert (DataPhase && Owner == WaitingOwner &&
                {HADDR, HWRITE, HSIZE, HPROT} == WaitingControl)
          else $fatal(1, "corebus contract: downstream owner/control changed during wait");
      if (DataPhase) begin
        assert (State[Owner] == PENDING && HTRANS == 0)
          else $fatal(1, "corebus contract: data phase lost its pending owner");
        assert (!LockActive || Owner == LockOwner)
          else $fatal(1, "corebus contract: global transfer bypassed AMO owner");
      end
      if (LockActive)
        assert (!(|CacheWriteCommit))
          else $fatal(1, "corebus contract: local store bypassed AMO exclusion");
      if (!DataPhase && Found && HREADY) begin
        assert (!LockActive || NextOwner == LockOwner)
          else $fatal(1, "corebus contract: grant bypassed AMO owner");
        if (FailedSC || BadAMOWrite)
          assert (HTRANS == 0 && !CacheWriteCommit[NextOwner])
            else $fatal(1, "corebus contract: rejected atomic reached memory");
        if (Op[NextOwner] == COREBUS_AMO && !Write[NextOwner]) begin
          LockedAddr <= Addr[NextOwner]; LockedSize <= Size[NextOwner];
        end
        if (Op[NextOwner] == COREBUS_AMO && Write[NextOwner] && LockActive)
          assert (Addr[NextOwner] == LockedAddr && Size[NextOwner] == LockedSize)
            else $fatal(1, "corebus contract: AMO write does not match locked read");
      end
      WaitingData <= DataPhase && !HREADY;
      WaitingOwner <= Owner;
      WaitingControl <= {HADDR, HWRITE, HSIZE, HPROT};
    end
  end
  // synopsys translate_on

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      DataPhase <= 1'b0;
      IFillActive <= 1'b0;
      IBeat <= '0;
      IRequestedData <= '0;
      Owner <= '0;
      First <= '0;
      Addr <= '0;
      Size <= '0;
      Prot <= '0;
      Write <= '0;
      CoreHRDATA <= '0;
      CoreHRESP <= '0;
      Op <= '0;
      LockActive <= 1'b0;
      LockOwner <= '0;
      for (int h = 0; h < NCORES; h++) State[h] <= AVAILABLE;
    end else begin
      for (int h = 0; h < NCORES; h++) begin
        if (LocalReply[h] || CacheWriteCommit[h]) begin
          CoreHRDATA[h] <= CacheWriteCommit[h] ? '0 : LocalData[h];
          CoreHRESP[h] <= 1'b0;
          State[h] <= REPLY;
        end
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
        if (FailedSC || BadAMOWrite) begin
          // A failed conditional store never reaches RAM or a peripheral.
          CoreHRDATA[NextOwner] <= '0;
          CoreHRESP[NextOwner] <= BadAMOWrite;
          State[NextOwner] <= BadAMOWrite ? ERROR_REPLY : REPLY;
          First <= int'(NextOwner) == NCORES-1 ? '0 : NextOwner + 1'b1;
        end else begin
          Owner <= NextOwner;
          if (!IFillActive && IFillRequest) begin
            IFillActive <= 1'b1;
            IBeat <= '0;
          end
          DataPhase <= 1'b1;
          if (Op[NextOwner] == COREBUS_AMO && !Write[NextOwner]) begin
            assert (!LockActive) else $fatal(1, "Nested AMO read");
            LockActive <= 1'b1;
            LockOwner <= NextOwner;
          end
          if (Op[NextOwner] == COREBUS_AMO && Write[NextOwner])
            assert (LockActive && LockOwner == NextOwner)
              else $fatal(1, "AMO write without its locked read");
        end
      end else if (DataPhase && HREADY) begin
        DataPhase <= 1'b0;
        if (IFillActive && !HRESP && !IFillLast) begin
          IBeat <= IBeat + 1'b1;
          if (int'(IBeat) == ((int'(Addr[Owner]) >> GRANULE_BITS) & (ICACHE_LINE_WORDS-1)))
            IRequestedData <= HRDATA;
        end else begin
          CoreHRDATA[Owner] <= IFillActive && !HRESP &&
            int'(IBeat) != ((int'(Addr[Owner]) >> GRANULE_BITS) & (ICACHE_LINE_WORDS-1)) ?
            IRequestedData : HRDATA;
          CoreHRESP[Owner] <= HRESP;
          State[Owner] <= HRESP ? ERROR_REPLY : REPLY;
          IFillActive <= 1'b0;
          IBeat <= '0;
          First <= int'(Owner) == NCORES-1 ? '0 : Owner + 1'b1;
        end
        if (Op[Owner] == COREBUS_AMO && (Write[Owner] || HRESP)) LockActive <= 1'b0;
      end
    end
  end
endmodule
