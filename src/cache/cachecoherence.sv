// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
///////////////////////////////////////////
// cachecoherence.sv
//
// Coherence of a D-cache that is the hart's L1 (COHERENT_DCACHE, ADR 0026): the writable bit of every line,
// the acquire/grant/release handshake with the SoC's coherence controller, the answer to its snoops, and the
// reservation kill for LR/SC. Instantiated by cache.sv only with COHERENT; cachefsm.sv sequences it.
//
// Line states: I (not valid), S (valid, not writable), E (valid, writable, clean), M (valid, writable, dirty).
// Valid and dirty bits stay in cacheway.sv; the writable bits are here, read and written like the dirty bits.
///////////////////////////////////////////

module cachecoherence #(parameter PA_BITS, LINELEN, NUMWAYS, NUMSETS, SETLEN, OFFSETLEN) (
  input  logic                 clk,
  input  logic                 reset,
  input  logic                 FlushStage,      // pipeline flush of the M stage
  // The cache's arrays and lookup
  input  logic                 CacheEn,         // arrays read this cycle
  input  logic [SETLEN-1:0]    CacheSetData,    // set written this cycle
  input  logic [SETLEN-1:0]    CacheSetTag,     // set read this cycle
  input  logic [NUMWAYS-1:0]   HitWay,          // ways hitting the address being compared
  input  logic [NUMWAYS-1:0]   VictimWay,       // way a refill replaces
  input  logic [NUMWAYS-1:0]   ValidWay,        // ways valid in the set read last cycle
  input  logic                 Hit,             // the compared address hits
  input  logic                 HitLineDirty,    // the hit line is dirty
  input  logic                 SetValid,        // a refill writes the victim way
  input  logic [PA_BITS-1:0]   PAdr,            // address of the M-stage access
  input  logic [PA_BITS-OFFSETLEN-SETLEN-1:0] Tag, // tag of the selected way (the victim during a refill), TAGLEN bits
  input  logic [LINELEN-1:0]   ReadDataLine,    // line of the selected way (the hit way while snooping)
  input  logic [1:0]           CacheRW,         // [1] read, [0] write
  input  logic                 CohWritePerm,    // the read needs a writable line (LR)
  input  logic                 FlushCache,      // write the whole cache back
  // From cachefsm
  input  logic                 CohInAccess,     // STATE_ACCESS
  input  logic                 CohInAcquire,    // STATE_ACQUIRE: waiting for the slot
  input  logic                 CohInSnoop,      // STATE_SNOOP: the snooped set has been read
  input  logic                 CohOpDone,       // the access of the M stage completes this cycle
  // To cachefsm
  output logic                 CohGranted,      // the slot is held
  output logic                 CohNoPerm,       // a write (or LR) hits a line that is not writable
  output logic                 CohSnoopDefer,   // snoops wait: an LR has just reserved a line, let its SC complete
  // Controller
  output logic                 CohAcqReq, CohAcqWrite, CohAcqFlush,
  output logic [PA_BITS-1:0]   CohAcqAdr,
  input  logic                 CohGnt, CohGntExcl,
  output logic                 CohRel,
  input  logic                 CohSnpInv,
  input  logic [PA_BITS-1:0]   CohSnpAdr,
  output logic                 CohSnpAck, CohSnpHit, CohSnpDirty,
  output logic [LINELEN-1:0]   CohSnpData,
  // LR/SC: a line this cache no longer holds
  output logic                 CohKill,
  output logic [PA_BITS-1:0]   CohKillAdr
);

  logic [NUMWAYS-1:0][NUMSETS-1:0] WritableBits;
  logic [NUMWAYS-1:0]  WritableWay, WriteW, WData;
  logic                HitWritable, NeedWrite, GntTake, GrantWritable;

  // Writable bits, read with the set the arrays read (like the dirty bits) and bypassed on a write to that set
  assign HitWritable = |(HitWay & WritableWay);
  assign NeedWrite   = CacheRW[0] | (CacheRW[1] & CohWritePerm);
  // Snoops and refills write the set the arrays address (CacheSetData); the upgrade of an S line, a hit while the
  // slot is held, writes the set of the M-stage address, which a load does not put on the arrays' address.
  logic [SETLEN-1:0] WSet;
  logic              Upgrade;
  assign Upgrade = CohInAccess & CohGranted & Hit & NeedWrite & ~FlushStage;
  assign WSet = (Upgrade & ~CohInSnoop & ~SetValid) ? PAdr[OFFSETLEN+SETLEN-1:OFFSETLEN] : CacheSetData;
  for (genvar w = 0; w < NUMWAYS; w++) begin : ways
    always_comb begin
      WriteW[w] = 1'b0; WData[w] = 1'b0;
      if (CohInSnoop & HitWay[w]) WriteW[w] = 1'b1;                       // snoop: S or I
      else if (SetValid & VictimWay[w]) begin WriteW[w] = 1'b1; WData[w] = GrantWritable; end  // refill
      else if (Upgrade & HitWay[w]) begin WriteW[w] = 1'b1; WData[w] = 1'b1; end            // upgrade of an S line
    end
    always_ff @(posedge clk) begin
      if (WriteW[w]) WritableBits[w][WSet] <= WData[w];
      if (CacheEn) WritableWay[w] <= (WriteW[w] & WSet == CacheSetTag) ? WData[w] : WritableBits[w][CacheSetTag];
    end
  end

  // Acquire, grant, release. The slot is asked for from STATE_ACQUIRE and held until the access completes.
  assign CohNoPerm   = Hit & ~HitWritable & NeedWrite & ~CohGranted;
  assign CohAcqReq   = CohInAcquire;
  assign CohAcqWrite = NeedWrite;
  assign CohAcqFlush = FlushCache;
  assign CohAcqAdr   = {PAdr[PA_BITS-1:OFFSETLEN], {OFFSETLEN{1'b0}}};
  assign GntTake     = CohInAcquire & CohGnt;
  assign CohRel      = (CohGranted & (CohOpDone | FlushStage)) | (GntTake & FlushStage);
  always_ff @(posedge clk)
    if (reset) CohGranted <= 1'b0;
    else       CohGranted <= (CohGranted & ~CohRel) | (GntTake & ~FlushStage);
  always_ff @(posedge clk)
    if (GntTake) GrantWritable <= NeedWrite | CohGntExcl;   // a refill under this grant is E (or M), else S

  // Forward progress of LR/SC: once an LR has performed (with its line writable), snoops wait until the SC, a
  // pipeline flush, or LRSC_CYCLES cycles, so that two harts cannot take a reserved line from each other forever.
  // Bounded, so a hart that stalls between LR and SC (on a refill that needs this snoop) cannot deadlock.
  localparam LRSC_CYCLES = 32;
  logic [$clog2(LRSC_CYCLES+1)-1:0] LRSCCount;
  logic LRPerformed, SCPresented;
  assign LRPerformed = CohOpDone & CacheRW == 2'b10 & CohWritePerm & (CohGranted | (Hit & HitWritable)) & ~FlushStage;
  assign SCPresented = CacheRW[0] & CohWritePerm;
  always_ff @(posedge clk)
    if (reset | FlushStage | SCPresented) LRSCCount <= '0;
    else if (LRPerformed)                 LRSCCount <= ($clog2(LRSC_CYCLES+1))'(LRSC_CYCLES);
    else if (LRSCCount != 0)              LRSCCount <= LRSCCount - 1'b1;
  assign CohSnoopDefer = LRSCCount != 0;

  // Snoop answer: the snooped set was read in the previous cycle and compared with CohSnpAdr
  assign CohSnpAck   = CohInSnoop;
  assign CohSnpHit   = Hit;
  assign CohSnpDirty = HitLineDirty;
  assign CohSnpData  = ReadDataLine;

  // The reservation of LR/SC is lost with its line: invalidated by a snoop, or replaced by a refill
  assign CohKill    = (CohInSnoop & CohSnpInv & Hit) | (SetValid & |(VictimWay & ValidWay));
  assign CohKillAdr = CohInSnoop ? {CohSnpAdr[PA_BITS-1:OFFSETLEN], {OFFSETLEN{1'b0}}}
                                 : {Tag, PAdr[OFFSETLEN+SETLEN-1:OFFSETLEN], {OFFSETLEN{1'b0}}};
endmodule
