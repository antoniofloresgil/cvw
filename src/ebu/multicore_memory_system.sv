// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Optional multicore memory topology between hart ports and the uncore AHB bus.
// The single-hart default is a combinational bypass; no protocol or latency is added.

module multicore_memory_system import cvw::*; #(parameter cvw_t P, `CVW_MULTICORE_PARAMS(P.AHBW))  (
  input  logic HCLK, HRESETn,
  // Hart-side AHB requests and shared-atomic sideband.
  input  logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR,
  input  logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA,
  input  logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB,
  input  logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK,
  input  logic [NCORES-1:0][2:0] CoreHSIZE, CoreHBURST,
  input  logic [NCORES-1:0][3:0] CoreHPROT,
  input  logic [NCORES-1:0][1:0] CoreHTRANS, CoreHATOMIC,
  output logic [NCORES-1:0] CoreSCFail, CoreHREADY, CoreHRESP,
  output logic [NCORES-1:0][P.AHBW-1:0] CoreHRDATA,
  // Uncore-side AHB master; clock/reset ownership remains with the SoC.
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

  localparam bit MSI_ENABLED = NCORES > 1 && PRIVATE_DCACHE;

  logic [NCORES-1:0][P.PA_BITS-1:0] CacheReadAddr;
  logic [NCORES-1:0][P.AHBW-1:0] CacheReadData;
  logic [NCORES-1:0] CacheReadHit, CacheWriteHit, CacheWriteCommit;
  logic [NCORES-1:0][P.AHBW-1:0] CacheWriteData;
  logic [NCORES-1:0][P.XLEN/8-1:0] CacheWriteStrb;
  logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] BusHOWNER;
  logic [P.PA_BITS-1:0] BusHADDR;
  logic [P.AHBW-1:0] BusHWDATA, BusHRDATA;
  logic [P.XLEN/8-1:0] BusHWSTRB;
  logic BusHWRITE, BusHMASTLOCK, BusHREADY, BusHRESP;
  logic [2:0] BusHSIZE, BusHBURST;
  logic [3:0] BusHPROT;
  logic [1:0] BusHTRANS;

  if (NCORES == 1 && !SHARED_CACHE) begin : singlecore
    // Preserve the original bus latency and allow all existing configurations.
    assign {BusHADDR, BusHWDATA, BusHWSTRB, BusHWRITE, BusHSIZE, BusHBURST, BusHPROT, BusHTRANS, BusHMASTLOCK} =
      {CoreHADDR[0], CoreHWDATA[0], CoreHWSTRB[0], CoreHWRITE[0], CoreHSIZE[0],
       CoreHBURST[0], CoreHPROT[0], CoreHTRANS[0], CoreHMASTLOCK[0]};
    assign CoreHRDATA[0] = BusHRDATA;
    assign CoreHREADY[0] = BusHREADY;
    assign CoreHRESP[0] = BusHRESP;
    assign CoreSCFail[0] = 1'b0;
    assign BusHOWNER = '0;
    assign CacheReadAddr = '0;
    assign CacheWriteCommit = '0;
    assign CacheWriteData = '0;
    assign CacheWriteStrb = '0;
  end else if (MSI_ENABLED && COHERENCE_BANKS > 1) begin : banked
    ahbmsifabric #(.P(P), .NCORES(NCORES), .BANKS(COHERENCE_BANKS),
      .DCACHE_WORDS(PRIVATE_DCACHE_WORDS), .DCACHE_LINE_WORDS(PRIVATE_DCACHE_LINE_WORDS),
      .PRIVATE_ICACHE(PRIVATE_ICACHE), .ICACHE_WORDS(PRIVATE_ICACHE_WORDS),
      .ICACHE_LINE_WORDS(PRIVATE_ICACHE_LINE_WORDS), .CACHE_TO_CACHE(CACHE_TO_CACHE), .CACHE_BURSTS(CACHE_BURSTS), .MESI(MESI),
      .LOCAL_DCACHE_READS(LOCAL_DCACHE_READS), .LOCAL_DCACHE_WRITES(LOCAL_DCACHE_WRITES)) fabric(
      .HCLK, .HRESETn, .CoreHADDR, .CoreHWDATA, .CoreHWSTRB, .CoreHWRITE, .CoreHMASTLOCK,
      .CoreHSIZE, .CoreHBURST, .CoreHPROT, .CoreHTRANS, .CoreHATOMIC,
      .CoreSCFail, .CoreHRDATA, .CoreHREADY, .CoreHRESP,
      .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK, .HRDATA, .HREADY, .HRESP);
    assign {BusHADDR, BusHWDATA, BusHWSTRB, BusHWRITE, BusHSIZE, BusHBURST, BusHPROT, BusHTRANS, BusHMASTLOCK, BusHOWNER} = '0;
    assign CacheReadAddr = '0;
    assign CacheWriteCommit = '0;
    assign CacheWriteData = '0;
    assign CacheWriteStrb = '0;
  end else begin : multicore
    ahbmulticore #(.P(P), .NCORES(NCORES),
      .PRIVATE_ICACHE(MSI_ENABLED && PRIVATE_ICACHE), .ICACHE_WORDS(PRIVATE_ICACHE_WORDS),
      .ICACHE_LINE_WORDS(PRIVATE_ICACHE_LINE_WORDS), .DCACHE_LINE_WORDS(PRIVATE_DCACHE_LINE_WORDS),
      .LOCAL_DCACHE_READS(MSI_ENABLED && LOCAL_DCACHE_READS),
      .LOCAL_DCACHE_WRITES(MSI_ENABLED && LOCAL_DCACHE_WRITES)) bus(
      .ReservationClear('0), .CacheReadAddr, .CacheReadHit, .CacheReadData,
      .CacheWriteHit, .CacheWriteCommit, .CacheWriteData, .CacheWriteStrb,
      .HCLK, .HRESETn, .CoreHADDR, .CoreHWDATA, .CoreHWSTRB, .CoreHWRITE, .CoreHSIZE,
      .CoreHBURST, .CoreHPROT, .CoreHTRANS, .CoreHMASTLOCK, .CoreHATOMIC, .CoreSCFail, .CoreHRDATA, .CoreHREADY, .CoreHRESP,
      .HOWNER(BusHOWNER), .HADDR(BusHADDR), .HWDATA(BusHWDATA), .HWSTRB(BusHWSTRB), .HWRITE(BusHWRITE), .HSIZE(BusHSIZE), .HBURST(BusHBURST), .HPROT(BusHPROT), .HTRANS(BusHTRANS), .HMASTLOCK(BusHMASTLOCK),
      .HRDATA(BusHRDATA), .HREADY(BusHREADY), .HRESP(BusHRESP));
  end

  if (MSI_ENABLED && COHERENCE_BANKS > 1) begin : bankedresponse
    assign {BusHRDATA, BusHREADY, BusHRESP} = '0;
  end else if (MSI_ENABLED) begin : msicache
    ahbmsicache #(.P(P), .NCORES(NCORES), .WORDS(PRIVATE_DCACHE_WORDS), .LINE_WORDS(PRIVATE_DCACHE_LINE_WORDS),
      .IFILL_WORDS(PRIVATE_ICACHE ? PRIVATE_ICACHE_LINE_WORDS : 1),
      .CACHE_TO_CACHE(CACHE_TO_CACHE), .CACHE_BURSTS(CACHE_BURSTS), .MESI(MESI), .LOCAL_READS(LOCAL_DCACHE_READS), .LOCAL_WRITES(LOCAL_DCACHE_WRITES)) cache(
      .CacheReadAddr, .CacheReadHit, .CacheReadData,
      .CacheWriteHit, .CacheWriteCommit, .CacheWriteData, .CacheWriteStrb,
      .HCLK, .HRESETn, .UpHOWNER(BusHOWNER),
      .UpHADDR(BusHADDR), .UpHWDATA(BusHWDATA), .UpHWSTRB(BusHWSTRB),
      .UpHWRITE(BusHWRITE), .UpHSIZE(BusHSIZE), .UpHBURST(BusHBURST),
      .UpHPROT(BusHPROT), .UpHTRANS(BusHTRANS), .UpHMASTLOCK(BusHMASTLOCK),
      .UpHRDATA(BusHRDATA), .UpHREADY(BusHREADY), .UpHRESP(BusHRESP),
      .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK,
      .HRDATA, .HREADY, .HRESP);
  end else if (SHARED_CACHE) begin : sharedcache
    ahbsharedcache #(.P(P), .WORDS(SHARED_CACHE_WORDS)) cache(
      .HCLK, .HRESETn, .UpHADDR(BusHADDR), .UpHWDATA(BusHWDATA), .UpHWSTRB(BusHWSTRB),
      .UpHWRITE(BusHWRITE), .UpHSIZE(BusHSIZE), .UpHBURST(BusHBURST), .UpHPROT(BusHPROT),
      .UpHTRANS(BusHTRANS), .UpHMASTLOCK(BusHMASTLOCK),
      .UpHRDATA(BusHRDATA), .UpHREADY(BusHREADY), .UpHRESP(BusHRESP),
      .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK,
      .HRDATA, .HREADY, .HRESP);
  end else begin : nocache
    assign {HADDR, HWDATA, HWSTRB, HWRITE, HSIZE, HBURST, HPROT, HTRANS, HMASTLOCK} =
      {BusHADDR, BusHWDATA, BusHWSTRB, BusHWRITE, BusHSIZE, BusHBURST, BusHPROT, BusHTRANS, BusHMASTLOCK};
    assign {BusHRDATA, BusHREADY, BusHRESP} = {HRDATA, HREADY, HRESP};
  end

  if (!MSI_ENABLED || COHERENCE_BANKS > 1) begin : nolocalreads
    assign CacheReadHit = '0;
    assign CacheWriteHit = '0;
    assign CacheReadData = '0;
  end

  localparam multicore_t M = `CVW_MULTICORE_VALUE;
  initial begin
    assert (multicore_config_error(P, M) == 0)
      else $fatal(1, "%s", multicore_config_message(multicore_config_error(P, M)));
  end

endmodule
