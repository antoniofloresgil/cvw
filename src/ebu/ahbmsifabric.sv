// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent address-home MSI engines sharing one physical AHB port.
// One blocking request per hart; distinct banks may have active coherence
// transactions concurrently. A home owns all I/D aliases of its region.
module ahbmsifabric import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned BANKS = 2,
  parameter int unsigned DCACHE_WORDS = 256,
  parameter int unsigned DCACHE_LINE_WORDS = 1,
  parameter bit PRIVATE_ICACHE = 0,
  parameter int unsigned ICACHE_WORDS = 256,
  parameter int unsigned ICACHE_LINE_WORDS = 1,
  parameter bit CACHE_TO_CACHE = 0,
  parameter bit LOCAL_DCACHE_READS = 0,
  parameter bit LOCAL_DCACHE_WRITES = 0
)(
  input logic HCLK, HRESETn,
  input logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR,
  input logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA,
  input logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB,
  input logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK,
  input logic [NCORES-1:0][2:0] CoreHSIZE, CoreHBURST,
  input logic [NCORES-1:0][3:0] CoreHPROT,
  input logic [NCORES-1:0][1:0] CoreHTRANS, CoreHATOMIC,
  output logic [NCORES-1:0] CoreSCFail, CoreHREADY, CoreHRESP,
  output logic [NCORES-1:0][P.AHBW-1:0] CoreHRDATA,
  output logic [P.PA_BITS-1:0] HADDR,
  output logic [P.AHBW-1:0] HWDATA,
  output logic [P.XLEN/8-1:0] HWSTRB,
  output logic HWRITE, HMASTLOCK,
  output logic [2:0] HSIZE, HBURST,
  output logic [3:0] HPROT,
  output logic [1:0] HTRANS,
  input logic [P.AHBW-1:0] HRDATA,
  input logic HREADY, HRESP
);
  localparam BB = BANKS > 1 ? $clog2(BANKS) : 1;
  localparam HB = NCORES > 1 ? $clog2(NCORES) : 1;
  localparam DW = DCACHE_WORDS/BANKS;
  localparam IW = ICACHE_WORDS/BANKS;
  localparam HOME_OFFSET = $clog2(P.AHBW/8) + $clog2(DW > IW ? DW : IW);
  typedef enum logic [2:0] {AVAILABLE, ISSUE, WAIT_REPLY, REPLY, ERROR_REPLY} state_t;
  state_t State[NCORES];
  logic [NCORES-1:0][BB-1:0] Home;
  logic [NCORES-1:0][P.PA_BITS-1:0] Addr;
  logic [NCORES-1:0][2:0] Size;
  logic [NCORES-1:0][3:0] Prot;
  logic [NCORES-1:0][1:0] Op;
  logic [NCORES-1:0] Write, Dispatch;
  logic [BANKS-1:0][NCORES-1:0][1:0] BTrans;
  logic [BANKS-1:0][NCORES-1:0] BReady, BResp, BSCFail, Clear;
  logic [BANKS-1:0][NCORES-1:0][P.AHBW-1:0] BData;
  logic [BANKS-1:0][P.PA_BITS-1:0] MemAddr;
  logic [BANKS-1:0][P.AHBW-1:0] MemWData, MemRData;
  logic [BANKS-1:0][P.XLEN/8-1:0] MemStrb;
  logic [BANKS-1:0] MemWrite, MemReady, MemResp;
  logic [BANKS-1:0][2:0] MemSize, MemBurst;
  logic [BANKS-1:0][3:0] MemProt;
  logic [BANKS-1:0][1:0] MemTrans;
  logic AtomicLock, AnyActive, AtomicPending, AtomicFound;
  logic [HB-1:0] AtomicOwner, AtomicCandidate, AtomicFirst;
  int Candidate;

  function automatic logic [BB-1:0] home(input logic [P.PA_BITS-1:0] a);
    // Keep every complete line within one bank; peripherals have one home.
    if ((P.UNCORE_RAM_SUPPORTED && ((64'(a) & ~P.UNCORE_RAM_RANGE) == P.UNCORE_RAM_BASE)) ||
        (P.EXT_MEM_SUPPORTED && ((64'(a) & ~P.EXT_MEM_RANGE) == P.EXT_MEM_BASE)))
      return BB'(a >> HOME_OFFSET);
    return '0;
  endfunction

  always_comb begin
    AnyActive = 1'b0;
    AtomicPending = 1'b0;
    AtomicFound = 1'b0;
    AtomicCandidate = AtomicFirst;
    Candidate = 0;
    for (int h = 0; h < NCORES; h++) begin
      if (State[h] == WAIT_REPLY) AnyActive = 1'b1;
      if (State[h] == ISSUE && Op[h] == 3 && !Write[h]) AtomicPending = 1'b1;
    end
    for (int offset = 0; offset < NCORES; offset++) begin
      Candidate = int'(AtomicFirst) + offset;
      if (Candidate >= NCORES) Candidate -= NCORES;
      if (!AtomicFound && State[Candidate] == ISSUE && Op[Candidate] == 3 && !Write[Candidate]) begin
        AtomicCandidate = HB'(Candidate);
        AtomicFound = 1'b1;
      end
    end
    BTrans = '0;
    Dispatch = '0;
    Clear = '0;
    for (int h = 0; h < NCORES; h++) begin
      CoreHREADY[h] = HRESETn && (State[h] == AVAILABLE || State[h] == REPLY);
      Dispatch[h] = HRESETn && State[h] == ISSUE &&
        (AtomicLock ? HB'(h) == AtomicOwner :
         (!AtomicPending || (!AnyActive && HB'(h) == AtomicCandidate)));
      if (Dispatch[h]) BTrans[Home[h]][h] = 2'b10;
      if (State[h] == WAIT_REPLY && BReady[Home[h]][h] && (Op[h] == 1 || Op[h] == 2))
        for (int b = 0; b < BANKS; b++)
          if (BB'(b) != Home[h]) Clear[b][h] = 1'b1;
    end
  end

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      Home <= '0; Addr <= '0; Size <= '0; Prot <= '0; Op <= '0; Write <= '0;
      CoreHRDATA <= '0; CoreHRESP <= '0; CoreSCFail <= '0;
      AtomicLock <= 1'b0; AtomicOwner <= '0; AtomicFirst <= '0;
      for (int h = 0; h < NCORES; h++) State[h] <= AVAILABLE;
    end else begin
      for (int h = 0; h < NCORES; h++) begin
        if (State[h] == ERROR_REPLY) State[h] <= REPLY;
        if (CoreHREADY[h]) begin
          CoreHRESP[h] <= 1'b0;
          if (CoreHTRANS[h][1]) begin
            Home[h] <= home(CoreHADDR[h]); Addr[h] <= CoreHADDR[h]; Size[h] <= CoreHSIZE[h];
            Prot[h] <= CoreHPROT[h]; Op[h] <= CoreHATOMIC[h]; Write[h] <= CoreHWRITE[h];
            State[h] <= ISSUE;
            assert (CoreHTRANS[h] == 2'b10 && CoreHBURST[h] == 0 && !CoreHMASTLOCK[h])
              else $fatal(1, "Banked fabric requires SINGLE core transfers");
          end else State[h] <= AVAILABLE;
        end
        if (Dispatch[h] && BReady[Home[h]][h]) begin
          State[h] <= WAIT_REPLY;
          if (Op[h] == 3 && !Write[h]) begin
            assert (!AtomicLock && !AnyActive) else $fatal(1, "AMO admitted before fabric drained");
            AtomicLock <= 1'b1; AtomicOwner <= HB'(h);
          end
        end
        if (State[h] == WAIT_REPLY && BReady[Home[h]][h]) begin
          CoreHRDATA[h] <= BData[Home[h]][h]; CoreHRESP[h] <= BResp[Home[h]][h];
          if (Op[h] == 2) CoreSCFail[h] <= BSCFail[Home[h]][h];
          State[h] <= BResp[Home[h]][h] ? ERROR_REPLY : REPLY;
          if (Op[h] == 3 && (Write[h] || BResp[Home[h]][h]) && AtomicLock && AtomicOwner == HB'(h)) begin
            AtomicLock <= 1'b0;
            AtomicFirst <= h == NCORES-1 ? '0 : HB'(h+1);
          end
        end
      end
    end
  end

  for (genvar b = 0; b < BANKS; b++) begin : banks
    logic [NCORES-1:0][P.PA_BITS-1:0] CacheReadAddr;
    logic [NCORES-1:0][P.AHBW-1:0] CacheReadData, CacheWriteData;
    logic [NCORES-1:0][P.XLEN/8-1:0] CacheWriteStrb;
    logic [NCORES-1:0] CacheReadHit, CacheWriteHit, CacheWriteCommit;
    logic [HB-1:0] Owner;
    logic [P.PA_BITS-1:0] A;
    logic [P.AHBW-1:0] WD, RD;
    logic [P.XLEN/8-1:0] WS;
    logic Wr, Lock, Ready, Resp;
    logic [2:0] Sz, Burst;
    logic [3:0] Pr;
    logic [1:0] Tr;
    ahbmulticore #(.P(P), .NCORES(NCORES), .PRIVATE_ICACHE(PRIVATE_ICACHE),
      .ICACHE_WORDS(IW), .ICACHE_LINE_WORDS(ICACHE_LINE_WORDS), .DCACHE_LINE_WORDS(DCACHE_LINE_WORDS),
      .LOCAL_DCACHE_READS(LOCAL_DCACHE_READS), .LOCAL_DCACHE_WRITES(LOCAL_DCACHE_WRITES)) bus(
      .HCLK, .HRESETn, .ReservationClear(Clear[b]),
      .CoreHADDR(Addr), .CoreHWDATA, .CoreHWSTRB, .CoreHWRITE(Write), .CoreHMASTLOCK('0),
      .CoreHSIZE(Size), .CoreHBURST('0), .CoreHPROT(Prot), .CoreHTRANS(BTrans[b]), .CoreHATOMIC(Op),
      .CoreHRDATA(BData[b]), .CoreHREADY(BReady[b]), .CoreHRESP(BResp[b]), .CoreSCFail(BSCFail[b]),
      .CacheReadAddr, .CacheReadHit, .CacheReadData, .CacheWriteHit, .CacheWriteCommit, .CacheWriteData, .CacheWriteStrb,
      .HOWNER(Owner), .HADDR(A), .HWDATA(WD), .HWSTRB(WS), .HWRITE(Wr), .HMASTLOCK(Lock),
      .HSIZE(Sz), .HBURST(Burst), .HPROT(Pr), .HTRANS(Tr), .HRDATA(RD), .HREADY(Ready), .HRESP(Resp));
    ahbmsicache #(.P(P), .NCORES(NCORES), .WORDS(DW), .LINE_WORDS(DCACHE_LINE_WORDS),
      .CACHE_TO_CACHE(CACHE_TO_CACHE), .LOCAL_READS(LOCAL_DCACHE_READS), .LOCAL_WRITES(LOCAL_DCACHE_WRITES)) cache(
      .HCLK, .HRESETn, .CacheReadAddr, .CacheReadHit, .CacheReadData,
      .CacheWriteHit, .CacheWriteCommit, .CacheWriteData, .CacheWriteStrb,
      .UpHOWNER(Owner), .UpHADDR(A), .UpHWDATA(WD), .UpHWSTRB(WS), .UpHWRITE(Wr), .UpHMASTLOCK(Lock),
      .UpHSIZE(Sz), .UpHBURST(Burst), .UpHPROT(Pr), .UpHTRANS(Tr), .UpHRDATA(RD), .UpHREADY(Ready), .UpHRESP(Resp),
      .HADDR(MemAddr[b]), .HWDATA(MemWData[b]), .HWSTRB(MemStrb[b]), .HWRITE(MemWrite[b]), .HMASTLOCK(),
      .HSIZE(MemSize[b]), .HBURST(MemBurst[b]), .HPROT(MemProt[b]), .HTRANS(MemTrans[b]),
      .HRDATA(MemRData[b]), .HREADY(MemReady[b]), .HRESP(MemResp[b]));
  end
  // Only the physical port serializes. A bank retains its state while another
  // bank uses RAM; cache-to-cache completion need not wait for this arbiter.
  ahbmulticore #(.P(P), .NCORES(BANKS)) memorybus(
    .HCLK, .HRESETn, .ReservationClear('0), .CoreHADDR(MemAddr), .CoreHWDATA(MemWData),
    .CoreHWSTRB(MemStrb), .CoreHWRITE(MemWrite), .CoreHMASTLOCK('0), .CoreHSIZE(MemSize),
    .CoreHBURST(MemBurst), .CoreHPROT(MemProt), .CoreHTRANS(MemTrans), .CoreHATOMIC('0),
    .CoreHRDATA(MemRData), .CoreHREADY(MemReady), .CoreHRESP(MemResp), .CoreSCFail(),
    .CacheReadAddr(), .CacheReadHit('0), .CacheReadData('0), .CacheWriteHit('0), .CacheWriteCommit(), .CacheWriteData(), .CacheWriteStrb(),
    .HOWNER(), .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HMASTLOCK(), .HSIZE, .HBURST, .HPROT, .HTRANS, .HRDATA, .HREADY, .HRESP);
  assign HMASTLOCK = AtomicLock;
  initial begin
    assert (BANKS >= 2 && (BANKS & (BANKS-1)) == 0 && NCORES >= 2)
      else $fatal(1, "Banked MSI requires >=2 harts and power-of-two banks >=2");
    assert (DW >= 2*DCACHE_LINE_WORDS && IW >= 2*ICACHE_LINE_WORDS &&
      DCACHE_WORDS % BANKS == 0 && ICACHE_WORDS % BANKS == 0)
      else $fatal(1, "Each home requires at least two complete I/D lines");
  end
endmodule
