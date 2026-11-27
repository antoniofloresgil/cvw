// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Buffered round-robin bridge with optional coherent private instruction banks.
// Accept each local address before stalling its data phase. This is necessary
// because busfsm gates its initial HTRANS with HREADY: grants cannot depend on
// HTRANS while HREADY is withheld. A pending hart holds write data until reply.
// Contract and reset/error/atomic lifetime: docs/engineering/interfaces/core-bus.md.
// With CORE_BURSTS a hart's fixed-length INCR burst (a cache line) goes to memory as one burst: a read is issued
// at once, pipelined into a line buffer, and each of the hart's beats is answered as its data arrives; a write's
// beats are collected and the burst is issued with the last one, which the hart sees end only when memory has
// taken the whole line. The bus stays with that hart until the burst ends; a hart that leaves its burst early
// (IDLE or NONSEQ instead of SEQ) lets the memory burst finish without it.
module ahbmulticore import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter bit PRIVATE_ICACHE = 0,
  parameter int unsigned ICACHE_WORDS = 8192/(P.AHBW/8),
  parameter int unsigned ICACHE_LINE_WORDS = 1,
  parameter int unsigned DCACHE_LINE_WORDS = 1,
  parameter bit LOCAL_DCACHE_READS = 0,
  parameter bit LOCAL_DCACHE_WRITES = 0,
  parameter bit CORE_BURSTS = 0       // the harts' caches issue INCR4/8/16 bursts (BURST_EN); not with local banks
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
  output logic [NCORES-1:0][P.PA_BITS-1:0] CacheReadAddrNext,  // what CacheReadAddr holds next cycle (block-RAM reads)
  input  logic [NCORES-1:0] CacheReadHit, CacheWriteHit,
  output logic [NCORES-1:0] CacheWriteCommit,
  output logic [NCORES-1:0][P.AHBW-1:0] CacheWriteData,
  output logic [NCORES-1:0][P.XLEN/8-1:0] CacheWriteStrb,
  input  logic [NCORES-1:0][P.AHBW-1:0] CacheReadData,
  output logic [NCORES-1:0] InstrMiss,           // PMU: an instruction bank starts a line fill
  // Coherent L1 D-caches (ADR 0026): a hart's waiting instruction fetch, held until the controller lets it go
  output logic [NCORES-1:0] FetchPending,
  input  logic [NCORES-1:0] CohHold,
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
  corebus_contract #(.P(P), .NCORES(NCORES), .BURSTS(CORE_BURSTS)) port_contract(
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

  // Burst engine (CORE_BURSTS): one burst at a time, for the hart in Owner
  localparam BEAT_OFF = $clog2(P.AHBW/8);
  localparam int unsigned DLINE_BEATS = P.DCACHE_SUPPORTED ? P.DCACHE_LINELENINBITS/P.AHBW : 1;
  localparam int unsigned ILINE_BEATS = P.ICACHE_SUPPORTED ? P.ICACHE_LINELENINBITS/P.AHBW : 1;
  localparam int unsigned MAXB = DLINE_BEATS > ILINE_BEATS ? DLINE_BEATS : ILINE_BEATS;
  localparam BB_BITS = $clog2(MAXB + 1);
  logic [NCORES-1:0][2:0] Burst;              // HBURST of the hart's accepted address phase
  logic [NCORES-1:0] Seq;                     // it was a SEQ beat
  logic BActive, BWrite, BIssue, BDataPhase, BErr, BAbandon, StartBurst, BHartBeat, BDDone, BHDone;
  logic [BB_BITS-1:0] BBeats, BAdr, BDat, BHart, BErrBeat;
  logic [2:0] BBurst;
  logic [P.PA_BITS-1:0] BBase;
  logic [P.AHBW-1:0] BBuf[MAXB];
  logic [P.XLEN/8-1:0] BStrb[MAXB];
  logic [1:0] BHTRANS;
  function automatic int unsigned burstBeats(input logic [2:0] b);
    case (b) 3'b011: return 4; 3'b101: return 8; 3'b111: return 16; default: return 0; endcase
  endfunction
  if (CORE_BURSTS && (PRIVATE_ICACHE || LOCAL_DCACHE_READS || LOCAL_DCACHE_WRITES)) begin : burstcheck
    $error("ahbmulticore: CORE_BURSTS cannot be combined with private instruction banks or local D-cache accesses");
  end

  assign CacheReadAddr = Addr;
  // Addr takes a hart's address when its request is accepted (below).
  for (genvar h = 0; h < NCORES; h++) begin : nextaddr
    assign CacheReadAddrNext[h] = CoreHREADY[h] && CoreHTRANS[h][1] ? CoreHADDR[h] : Addr[h];
  end
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
  for (genvar h = 0; h < NCORES; h++) begin : fetches
    assign FetchPending[h] = State[h] == PENDING && !Write[h] && !Prot[h][0] && Op[h] == COREBUS_NORMAL &&
      cacheable(Addr[h]);
  end

  logic [NCORES-1:0] ICacheHit;
  logic [NCORES-1:0][P.AHBW-1:0] ICacheData;
  if (PRIVATE_ICACHE) begin : icache
    multicore_icache_bank #(.P(P), .NCORES(NCORES), .WORDS(ICACHE_WORDS), .LINE_WORDS(ICACHE_LINE_WORDS)) banks(
      .HCLK, .HRESETn, .ProbeAddr(Addr), .ProbeAddrNext(CacheReadAddrNext), .ProbeHit(ICacheHit), .ProbeData(ICacheData),
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
          !CohHold[Candidate] &&
          (!LockActive || OWNER_BITS'(Candidate) == LockOwner)) begin
        NextOwner = OWNER_BITS'(Candidate);
        Found = 1'b1;
      end
    end
    if (IFillActive) begin
      NextOwner = Owner;
      Found = 1'b1;
    end
    if (CORE_BURSTS && BActive) Found = 1'b0;   // the burst keeps the bus
  end
  // A granted hart's NONSEQ of a fixed-length burst that fits the buffer starts the burst engine
  assign StartBurst = CORE_BURSTS && !DataPhase && Found && !Seq[NextOwner] && Op[NextOwner] == COREBUS_NORMAL &&
    burstBeats(Burst[NextOwner]) != 0 && burstBeats(Burst[NextOwner]) <= MAXB;

  // Validate SC where all stores are ordered, never at local address issue.
  multicore_reservations #(.P(P), .NCORES(NCORES)) reservations(
    .HCLK, .HRESETn, .QueryOwner(NextOwner), .QueryAddr(Addr[NextOwner]), .QuerySize(Size[NextOwner]),
    .QueryBlocked(LocalStoreConflict[NextOwner]), .SCValid,
    .Issue(!DataPhase && Found && HREADY), .IssueOp(Op[NextOwner]),
    .Complete((DataPhase || (BActive && BDataPhase)) && HREADY), .CompleteOwner(Owner),
    .CompleteAddr(BActive ? BBase + (P.PA_BITS'(BDat) << BEAT_OFF) : Addr[Owner]),
    .CompleteSize(Size[Owner]), .CompleteOp(BActive ? COREBUS_NORMAL : Op[Owner]),
    .CompleteWrite(BActive ? BWrite : Write[Owner]), .CompleteError(HRESP),
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
    // A write burst first collects the hart's beats: its grant issues nothing
    HTRANS = !DataPhase && Found && !FailedSC && !BadAMOWrite && HRESETn && !(StartBurst && Write[NextOwner]) ?
      2'b10 : 2'b00;
    HBURST = StartBurst ? Burst[NextOwner] : 3'b000;
    HMASTLOCK = LockActive || (!DataPhase && Found && Op[NextOwner] == COREBUS_AMO);
    // Write data belongs to the DATA owner, never the next address owner.
    HWDATA = CoreHWDATA[Owner];
    HWSTRB = CoreHWSTRB[Owner];
    if (CORE_BURSTS && BActive) begin
      HADDR = BBase + (P.PA_BITS'(BAdr) << BEAT_OFF);
      HWRITE = BWrite;
      HSIZE = 3'(BEAT_OFF);
      HPROT = Prot[Owner];
      HTRANS = BHTRANS;
      HBURST = BBurst;
      HMASTLOCK = 1'b0;
      // the last beat's data is the hart's, held in its data phase until the reply
      HWDATA = int'(BDat) >= int'(BBeats) - 1 ? CoreHWDATA[Owner] : BBuf[int'(BDat) < MAXB ? int'(BDat) : 0];
      HWSTRB = int'(BDat) >= int'(BBeats) - 1 ? CoreHWSTRB[Owner] : BStrb[int'(BDat) < MAXB ? int'(BDat) : 0];
    end
    for (int h = 0; h < NCORES; h++)
      CoreHREADY[h] = HRESETn && (State[h] == AVAILABLE || State[h] == REPLY);
  end

  // Burst engine. The address beats run ahead of the data; an ERROR response drops the rest (allowed in its first
  // cycle). The hart's beat k is answered once data beat k is in the buffer (read) or, for a write, collected at
  // once except the last, which waits for the whole burst.
  assign BHTRANS = BIssue && int'(BAdr) < int'(BBeats) && !BErr && !HRESP ? (BAdr == '0 ? 2'b10 : 2'b11) : 2'b00;
  assign BHartBeat = BActive && State[Owner] == PENDING && !BAbandon && int'(BHart) < int'(BBeats) &&
    (BHart == '0 || Seq[Owner]);
  assign BDDone = !BIssue || (!BDataPhase && (BErr || BDat == BBeats));
  assign BHDone = BAbandon || BHart == BBeats;

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
      Burst <= '0; Seq <= '0;
      BActive <= 1'b0; BWrite <= 1'b0; BIssue <= 1'b0; BDataPhase <= 1'b0; BErr <= 1'b0; BAbandon <= 1'b0;
      BBeats <= '0; BAdr <= '0; BDat <= '0; BHart <= '0; BErrBeat <= '0; BBurst <= '0; BBase <= '0;
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
            Burst[h] <= CoreHBURST[h];
            Seq[h] <= CoreHTRANS[h] == 2'b11;
            State[h] <= PENDING;
            assert (CORE_BURSTS ? !CoreHMASTLOCK[h] :
                    (CoreHTRANS[h] == 2'b10 && CoreHBURST[h] == 3'b000 && !CoreHMASTLOCK[h]))
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
        end else if (StartBurst) begin
          Owner <= NextOwner;
          BActive <= 1'b1; BWrite <= Write[NextOwner]; BBurst <= Burst[NextOwner];
          BBeats <= BB_BITS'(burstBeats(Burst[NextOwner])); BBase <= Addr[NextOwner];
          BHart <= '0; BDat <= '0; BErr <= 1'b0; BAbandon <= 1'b0;
          // a read's first address beat goes out now; a write's waits for its last beat
          BAdr <= Write[NextOwner] ? '0 : BB_BITS'(1);
          BIssue <= !Write[NextOwner];
          BDataPhase <= !Write[NextOwner];
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
      if (CORE_BURSTS && BActive) begin
        // memory side
        if (HREADY) begin
          if (BDataPhase) begin
            if (!BWrite && int'(BDat) < MAXB) BBuf[int'(BDat)] <= HRDATA;
            if (HRESP && !BErr) begin BErr <= 1'b1; BErrBeat <= BDat; end
            BDat <= BDat + 1'b1;
          end
          BDataPhase <= BHTRANS[1];
          if (BHTRANS[1]) BAdr <= BAdr + 1'b1;
        end
        // hart side
        if (BHartBeat) begin
          if (!BWrite) begin
            if (BDat > BHart || (BErr && BHart >= BErrBeat)) begin
              CoreHRDATA[Owner] <= BBuf[int'(BHart) < MAXB ? int'(BHart) : 0];
              CoreHRESP[Owner] <= BErr && BHart >= BErrBeat;
              State[Owner] <= BErr && BHart >= BErrBeat ? ERROR_REPLY : REPLY;
              BHart <= BHart + 1'b1;
            end
          end else if (int'(BHart) < int'(BBeats) - 1) begin
            if (int'(BHart) < MAXB) begin
              BBuf[int'(BHart)] <= CoreHWDATA[Owner]; BStrb[int'(BHart)] <= CoreHWSTRB[Owner];
            end
            CoreHRDATA[Owner] <= '0; CoreHRESP[Owner] <= 1'b0;
            State[Owner] <= REPLY;
            BHart <= BHart + 1'b1;
          end else if (!BIssue) BIssue <= 1'b1;   // last beat: issue the burst
          else if (BDDone) begin
            CoreHRDATA[Owner] <= '0; CoreHRESP[Owner] <= BErr;
            State[Owner] <= BErr ? ERROR_REPLY : REPLY;
            BHart <= BHart + 1'b1;
          end
        end
        // the hart left its burst: it took a reply and gave no SEQ
        if (CoreHREADY[Owner] && !BAbandon && BHart != '0 && int'(BHart) < int'(BBeats) && CoreHTRANS[Owner] != 2'b11)
          BAbandon <= 1'b1;
        if (BHDone && BDDone) begin
          BActive <= 1'b0; BIssue <= 1'b0;
          First <= int'(Owner) == NCORES-1 ? '0 : Owner + 1'b1;
        end
      end
    end
  end
endmodule
