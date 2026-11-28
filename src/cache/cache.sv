///////////////////////////////////////////
// cache.sv
//
// Written:  Rose Thompson rose@rosethompson.net 7 July 2021
// Modified: David Harris, Alec Vercruysse, Katherine Parry, Limnanthes Serafini
//
// Purpose: Configurable set-associative cache for the I$ and D$.
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

module cache import cvw::*; #(parameter cvw_t P,
                              parameter PA_BITS, LINELEN, NUMSETS, OFFSETLEN, SETLEN, NUMWAYS, LOGBWPL, WORDLEN, MUXINTERVAL, READ_ONLY_CACHE,
                              parameter bit COHERENT = 0) (
  input  logic                   clk,
  input  logic                   reset,
  input  logic                   Stall,             // Stall the cache, preventing new accesses. In-flight access finished but does not return to READY
  input  logic                   FlushStage,        // Pipeline flush of second stage (prevent writes and bus operations)
  input  logic                   InvalidateFlushStage, // Flush of the stage issuing InvalidateCache (suppresses the invalidate)
  // cpu side
  input  logic [1:0]             CacheRW,           // [1] Read, [0] Write
  input  logic                   FlushCache,        // Flush all dirty lines back to memory
  input  logic                   InvalidateCache,   // Clear all valid bits
  input  logic [3:0]             CMOpM,             // 1: cbo.inval; 2: cbo.clean; 4: cbo.flush; 8: cbo.zero
  input  logic [OFFSETLEN+SETLEN-1:0] NextSet,      // Set and offset bits of the virtual address
  input  logic [PA_BITS-1:0]     PAdr,              // Physical address
  input  logic [(WORDLEN-1)/8:0] ByteMask,          // Which bytes to write (D$ only)
  input  logic [WORDLEN-1:0]     WriteData,         // Data to write to cache (D$ only)
  output logic                   CacheCommitted,    // Cache has started bus operation that shouldn't be interrupted
  output logic                   CacheStall,        // Cache stalls pipeline during multicycle operation
  output logic [WORDLEN-1:0]     ReadDataWord,      // Word read from cache (goes to CPU and bus)
  // to performance counters to cpu
  output logic                   CacheMiss,         // Cache miss
  output logic                   CacheAccess,       // Cache access
  // lsu control
  input  logic                   SelHPTW,           // Use PAdr from Hardware Page Table Walker rather than NextSet
  // Bus fsm interface
  input  logic                   CacheBusAck,       // Bus operation completed
  input  logic                   SelBusBeat,        // Word in cache line comes from BeatCount
  input  logic [LOGBWPL-1:0]     BeatCount,         // Beat in burst
  input  logic [LINELEN-1:0]     FetchBuffer,       // Buffer long enough to hold entire cache line arriving from bus
  output logic [1:0]             CacheBusRW,        // [1] Read (cache line fetch) or [0] write bus (cache line writeback)
  output logic [PA_BITS-1:0]     CacheBusAdr,       // Address for bus access
  // Coherence with the SoC's controller (COHERENT, ADR 0026); inputs tied to 0 and outputs unused otherwise
  input  logic                   CohWritePerm,      // the read needs a writable line (LR)
  output logic                   CohAcqReq, CohAcqWrite, CohAcqFlush, // acquire the slot (for a write, for a flush)
  output logic [PA_BITS-1:0]     CohAcqAdr,         // line to acquire
  input  logic                   CohGnt, CohGntExcl, // slot granted; no other cache holds the line
  output logic                   CohRel,            // release the slot
  input  logic                   CohSnpReq, CohSnpInv, // snoop: invalidate, else downgrade to S
  input  logic [PA_BITS-1:0]     CohSnpAdr,         // snooped line
  output logic                   CohSnpAck, CohSnpHit, CohSnpDirty, // snoop answer
  output logic [LINELEN-1:0]     CohSnpData,        // the snooped line when it was dirty
  output logic                   CohKill,           // this cache lost the line at CohKillAdr (LR/SC)
  output logic [PA_BITS-1:0]     CohKillAdr
);

  // Cache parameters
  localparam                     SETTOP = SETLEN+OFFSETLEN;          // Number of set plus offset bits
  localparam                     TAGLEN = PA_BITS - SETTOP;          // Number of tag bits
  localparam                     FLUSHADRTHRESHOLD = NUMSETS - 1;    // Used to determine when flush is complete

  logic                          SelAdrData;
  logic                          SelAdrTag;
  logic [1:0]                    AdrSelMuxSelData;
  logic [1:0]                    AdrSelMuxSelTag, AdrSelMuxSelLRU;
  logic [SETLEN-1:0]             CacheSetData;
  logic [SETLEN-1:0]             CacheSetTag, CacheSetLRU;
  logic [LINELEN-1:0]            LineWriteData;
  logic                          ClearDirty, SetDirty, SetValid, ClearValid;
  logic [LINELEN-1:0]            ReadDataLineWay [NUMWAYS-1:0];
  logic [NUMWAYS-1:0]            HitWay, ValidWay;
  logic                          Hit;
  logic [NUMWAYS-1:0]            VictimWay, DirtyWay, HitDirtyWay;
  logic                          LineDirty, HitLineDirty;
  logic [TAGLEN-1:0]             TagWay [NUMWAYS-1:0];
  logic [TAGLEN-1:0]             Tag;
  logic [SETLEN-1:0]             FlushAdr;
  logic                          FlushAdrCntEn, FlushCntRst;
  logic                          FlushAdrFlag, FlushWayFlag;
  logic [NUMWAYS-1:0]            FlushWay, NextFlushWay;
  logic                          FlushWayCntEn;
  logic                          SelWriteback;
  logic                          LRUWriteEn;
  logic [LINELEN-1:0]            ReadDataLine, ReadDataLineCache;
  logic                          SelFetchBuffer;
  logic                          CacheEn;
  logic [PA_BITS-1:0]            PAdrC;             // PAdr, or the snooped address while a snoop reads the arrays
  logic                          CohSelSnoop, CohInAccess, CohInAcquire, CohInSnoop, CohOpDone, CohGranted, CohNoPerm, CohSnoopDefer;
  logic                          SelVictim;
  logic                          FlushCacheC;
  logic [LINELEN/8-1:0]          LineByteMask;
  logic [$clog2(LINELEN/8) - $clog2(MUXINTERVAL/8) - 1:0] WordOffsetAddr;
  genvar                         index;

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Read Path
  /////////////////////////////////////////////////////////////////////////////////////////////

  // Choose read address (CacheSet).  Normally use NextSet, but use PAdr during stalls
  // and FlushAdr when handling D$ flushes
  // The icache must update to the newest PCNextF on flush as it is probably a trap.  Trap
  // sets PCNextF to XTVEC and the icache must start reading the instruction.
  // A snoop taken while a flush waits for the slot reads and updates the snooped line, not the flush counter's
  assign FlushCacheC = FlushCache & ~(COHERENT & CohSelSnoop);
  assign AdrSelMuxSelData = {FlushCacheC, ((SelAdrData | SelHPTW) & ~((READ_ONLY_CACHE == 1) & FlushStage))};
  assign PAdrC = (COHERENT & CohSelSnoop) ? CohSnpAdr : PAdr;
  mux3 #(SETLEN) AdrSelMuxData(NextSet[SETTOP-1:OFFSETLEN], PAdrC[SETTOP-1:OFFSETLEN], FlushAdr,
    AdrSelMuxSelData, CacheSetData);
  assign AdrSelMuxSelTag = {FlushCacheC, ((SelAdrTag | SelHPTW) & ~((READ_ONLY_CACHE == 1) & FlushStage))};
  mux3 #(SETLEN) AdrSelMuxTag(NextSet[SETTOP-1:OFFSETLEN], PAdrC[SETTOP-1:OFFSETLEN], FlushAdr,
    AdrSelMuxSelTag, CacheSetTag);

  assign AdrSelMuxSelLRU = {FlushCacheC, ((SelAdrTag | SelHPTW | Stall) & ~((READ_ONLY_CACHE == 1) & FlushStage))};
  mux3 #(SETLEN) AdrSelMuxLRU(NextSet[SETTOP-1:OFFSETLEN], PAdr[SETTOP-1:OFFSETLEN], FlushAdr,
    AdrSelMuxSelLRU, CacheSetLRU);

  // Array of cache ways, along with victim, hit, dirty, and read merging logic
  cacheway #(P, PA_BITS, NUMSETS, LINELEN, TAGLEN, OFFSETLEN, SETLEN, READ_ONLY_CACHE) CacheWays[NUMWAYS-1:0](
    .clk, .reset, .CacheEn, .CacheSetData, .CacheSetTag, .PAdr(PAdrC), .LineWriteData, .LineByteMask, .SelVictim,
    .SetValid, .ClearValid, .SetDirty, .ClearDirty, .VictimWay,
    .FlushWay, .FlushCache(FlushCacheC), .ReadDataLineWay, .HitWay, .ValidWay, .DirtyWay, .HitDirtyWay, .TagWay, .FlushStage(FlushStage & ~CohInSnoop), // a snoop's update is never cancelled
    .InvalidateCache, .InvalidateFlushStage);

  // Select victim way for associative caches
  if (NUMWAYS > 1) begin : vict
    cacheLRU #(NUMWAYS, SETLEN, NUMSETS) cacheLRU(
      .clk, .reset, .CacheEn, .HitWay, .ValidWay, .VictimWay, .CacheSetLRU, .LRUWriteEn,
      .SetValid, .PAdr(PAdr[SETTOP-1:OFFSETLEN]), .InvalidateCache, .InvalidateFlushStage);
  end else
    assign VictimWay = 1'b1; // one hot.

  assign Hit = |HitWay;
  assign LineDirty = |DirtyWay;
  assign HitLineDirty = |(HitDirtyWay & HitWay);

  // ReadDataLineWay is a 2d array of cache line len by number of ways.
  // Need to OR together each way in a bitwise manner.
  // Final part of the AO Mux.  First is the AND in the cacheway.
  or_rows #(NUMWAYS, LINELEN) ReadDataAOMux(.a(ReadDataLineWay), .y(ReadDataLineCache));
  or_rows #(NUMWAYS, TAGLEN) TagAOMux(.a(TagWay), .y(Tag));

  // Data cache needs to choose word offset from PAdr or BeatCount to writeback dirty lines
  if (!READ_ONLY_CACHE)
    mux2 #(LOGBWPL) WordAdrMux(.d0(PAdr[$clog2(LINELEN/8) - 1 : $clog2(MUXINTERVAL/8)]),
      .d1(BeatCount), .s(SelBusBeat),
      .y(WordOffsetAddr));
  else
    assign WordOffsetAddr = PAdr[$clog2(LINELEN/8) - 1 : $clog2(MUXINTERVAL/8)];

  // Bypass cache array to save a cycle when finishing a load miss
  mux2 #(LINELEN) EarlyReturnMux(ReadDataLineCache, FetchBuffer, SelFetchBuffer, ReadDataLine);

  // Select word from cache line
  subcachelineread #(LINELEN, WORDLEN, MUXINTERVAL) subcachelineread(
    .PAdr(WordOffsetAddr), .ReadDataLine, .ReadDataWord);

  // Bus address for fetch, writeback, or flush writeback
  mux3 #(PA_BITS) CacheBusAdrMux(.d0({PAdr[PA_BITS-1:OFFSETLEN], {OFFSETLEN{1'b0}}}),
    .d1({Tag, PAdr[SETTOP-1:OFFSETLEN], {OFFSETLEN{1'b0}}}),
    .d2({Tag, FlushAdr, {OFFSETLEN{1'b0}}}),
    .s({FlushCache, SelWriteback}), .y(CacheBusAdr));

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Write Path
  /////////////////////////////////////////////////////////////////////////////////////////////
  if (!READ_ONLY_CACHE) begin : WriteSelLogic
    logic [LINELEN/8-1:0]          DemuxedByteMask, FetchBufferByteSel;

    // Adjust byte mask from word to cache line
    logic [LINELEN/8-1:0]          BlankByteMask;
    assign BlankByteMask[WORDLEN/8-1:0] = ByteMask;
    assign BlankByteMask[LINELEN/8-1:WORDLEN/8] = 0;

    assign DemuxedByteMask = BlankByteMask << ((MUXINTERVAL/8) * WordOffsetAddr);

    assign FetchBufferByteSel = SetDirty ? ~DemuxedByteMask : '1;  // If load miss set all muxes to 1.

    // Merge write data into fetched cache line for store miss
    // cbo.zero takes every byte from WriteData, which the LSU forces to zero
    for (index = 0; index < LINELEN/8; index++) begin
      mux2 #(8) WriteDataMux(.d0(WriteData[(8*index)%WORDLEN+7:(8*index)%WORDLEN]),
        .d1(FetchBuffer[8*index+7:8*index]), .s(FetchBufferByteSel[index] & ~CMOpM[CMO_ZERO]), .y(LineWriteData[8*index+7:8*index]));
    end
    assign LineByteMask = SetDirty ? DemuxedByteMask : '1;
  end else begin : WriteSelLogic
    // No need for this mux if the cache does not handle writes.
    assign LineWriteData = FetchBuffer;
    assign LineByteMask = '1;
  end

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Flush logic
  /////////////////////////////////////////////////////////////////////////////////////////////

  if (!READ_ONLY_CACHE) begin : flushlogic // D$ can be flushed
    logic                          ResetOrFlushCntRst;
    logic [SETLEN-1:0]             NextFlushAdr, FlushAdrP1;

    // Flush address (line number)
    assign ResetOrFlushCntRst = reset | FlushCntRst;
    flopenr #(SETLEN) FlushAdrReg(clk, ResetOrFlushCntRst, FlushAdrCntEn, FlushAdrP1, NextFlushAdr);
    mux2    #(SETLEN) FlushAdrMux(NextFlushAdr, FlushAdrP1, FlushAdrCntEn, FlushAdr);
    assign FlushAdrP1 = NextFlushAdr + 1'b1;
    assign FlushAdrFlag = (NextFlushAdr == FLUSHADRTHRESHOLD[SETLEN-1:0]);

    // Flush way
    flopenl #(NUMWAYS) FlushWayReg(clk, FlushWayCntEn, ResetOrFlushCntRst, {{NUMWAYS-1{1'b0}}, 1'b1}, NextFlushWay, FlushWay);
    if (NUMWAYS > 1) assign NextFlushWay = {FlushWay[NUMWAYS-2:0], FlushWay[NUMWAYS-1]};
    else             assign NextFlushWay = FlushWay[NUMWAYS-1];
    assign FlushWayFlag = FlushWay[NUMWAYS-1];
  end else begin : flushlogic // I$ is never flushed because it is never dirty
    assign FlushWay = '0;
    assign FlushWayFlag = 1'b0;
    assign FlushAdrFlag = 1'b0;
    assign FlushAdr = '0;
  end

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Cache FSM
  /////////////////////////////////////////////////////////////////////////////////////////////

  cachefsm #(READ_ONLY_CACHE, COHERENT) cachefsm(.clk, .reset, .CacheBusRW, .CacheBusAck,
    .FlushStage, .InvalidateFlushStage, .CacheRW, .Stall,
    .Hit, .LineDirty, .HitLineDirty, .CacheStall, .CacheCommitted,
    .CacheMiss, .CacheAccess, .SelAdrData, .SelAdrTag, .SelVictim,
    .ClearDirty, .SetDirty, .SetValid, .ClearValid, .SelWriteback,
    .FlushAdrCntEn, .FlushWayCntEn, .FlushCntRst,
    .FlushAdrFlag, .FlushWayFlag, .FlushCache, .SelFetchBuffer,
    .InvalidateCache, .CMOpM, .CacheEn, .LRUWriteEn,
    .CohSnpReq, .CohSnpInv, .CohGnt, .CohGranted, .CohNoPerm, .CohSnoopDefer,
    .CohSelSnoop, .CohInAccess, .CohInAcquire, .CohInSnoop, .CohOpDone);

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Coherence (ADR 0026)
  /////////////////////////////////////////////////////////////////////////////////////////////

  if (COHERENT & !READ_ONLY_CACHE) begin : coherence
    cachecoherence #(PA_BITS, LINELEN, NUMWAYS, NUMSETS, SETLEN, OFFSETLEN) cachecoherence(.clk, .reset, .FlushStage,
      .CacheEn, .CacheSetData, .CacheSetTag, .HitWay, .VictimWay, .ValidWay, .Hit, .HitLineDirty, .SetValid,
      .PAdr, .Tag, .ReadDataLine(ReadDataLineCache), .CacheRW, .CohWritePerm, .FlushCache,
      .CohInAccess, .CohInAcquire, .CohInSnoop, .CohOpDone, .CohGranted, .CohNoPerm, .CohSnoopDefer,
      .CohAcqReq, .CohAcqWrite, .CohAcqFlush, .CohAcqAdr, .CohGnt, .CohGntExcl, .CohRel,
      .CohSnpInv, .CohSnpAdr, .CohSnpAck, .CohSnpHit, .CohSnpDirty, .CohSnpData, .CohKill, .CohKillAdr);
  end else begin : nocoherence
    assign {CohGranted, CohNoPerm, CohSnoopDefer, CohAcqReq, CohAcqWrite, CohAcqFlush, CohAcqAdr, CohRel} = '0;
    assign {CohSnpAck, CohSnpHit, CohSnpDirty, CohSnpData, CohKill, CohKillAdr} = '0;
  end
endmodule
