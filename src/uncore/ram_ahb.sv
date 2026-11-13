///////////////////////////////////////////
// ram_ahb.sv
//
// Written:  David Harris David_Harris@hmc.edu 9 January 2021
// Modified: Rose Thompson, Ben Bracker, Noah Boorstin
//
// Purpose: On-chip RAM on AHB.
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

module ram_ahb import cvw::*; #(parameter cvw_t P,
                                parameter RANGE = 65535, PRELOAD = 0, TRACE_SHARED = 0) (
  input  logic                 HCLK, HRESETn,
  input  logic                 HSELRam,
  input  logic [P.PA_BITS-1:0] HADDR,
  input  logic                 HWRITE,
  input  logic                 HREADY,
  input  logic [1:0]           HTRANS,
  input  logic [P.XLEN-1:0]    HWDATA,
  input  logic [P.XLEN/8-1:0]  HWSTRB,
  output logic [P.XLEN-1:0]    HREADRam,
  output logic                 HRESPRam, HREADYRam,
  // TRACE_SHARED (P.TRACE_IN_RAM of the uncore's RAM): the trace sink's port to the last TRACE_RAM_WORDS words of this RAM (src/debug/etracesink.sv)
  input  logic                 TrReq, TrWe,                  // the sink wants the port
  input  logic [3:0]           TrBwe,
  input  logic [$clog2(P.TRACE_RAM_WORDS)-1:0] TrAddr,
  input  logic [31:0]          TrDin,
  output logic                 TrGrant,                      // the port is the sink's this cycle
  output logic [31:0]          TrDout,
  // P.AI_SUPPORTED: the AI unit's port to the last part of the RAM before the trace RAM (src/uncore/ai/ai_unit.sv), 2^M words, M = log2 TRACE_RAM_WORDS.
  // The unit owns that part's macro in the cycles in which XpReq is high: the core is held off the bus while it asks (uncore.sv, Own), and the unit's
  // own transfers keep out of the part (its Valid check), so the port is never contended
  input  logic                 XpReq, XpWe,
  input  logic [$clog2(P.TRACE_RAM_WORDS)-1:0] XpAddr,
  input  logic [31:0]          XpDin,
  output logic [31:0]          XpDout
);

  localparam                   DEPTH = (RANGE+1)/64'(64'(P.XLEN)/8);  // RANGE is a mask (size-1), DEPTH is in XLEN-bit words
  localparam                   ADDR_WIDTH = $clog2(DEPTH);
  localparam OFFSET     = $clog2(P.XLEN/8);

  logic [P.PA_BITS-1:0]        HADDRD, RamAddr;
  logic                        initTrans;
  logic                        memwrite, memwriteD, memread;
  logic                        nextHREADYRam;
  logic                        DelayReady;

  // a new AHB transaction starts when HTRANS requests a transaction,
  // the peripheral is selected, and the previous transaction is completing
  assign initTrans = HREADY & HSELRam & HTRANS[1];
  assign memwrite  = initTrans & HWRITE;
  assign memread   = initTrans & ~HWRITE;

  flopenr #(1)        memwritereg(HCLK, ~HRESETn, HREADY, memwrite, memwriteD);
  flopenr #(P.PA_BITS) haddrreg(HCLK, ~HRESETn, HREADY, HADDR, HADDRD);

  // Stall on a read after a write because the RAM can't take both addresses on the same cycle
  assign nextHREADYRam = (~(memwriteD & memread)) & ~DelayReady;
  flopr #(1) readyreg(HCLK, ~HRESETn, nextHREADYRam, HREADYRam);

  assign HRESPRam = 1'b0; // OK

  // On writes or during a wait state, use address delayed by one cycle to sync RamAddr with HWDATA or hold stalled address
  mux2 #(P.PA_BITS) adrmux(HADDR, HADDRD, memwriteD | ~HREADY, RamAddr);

  // single-ported RAM.  With TRACE_SHARED it is a lower part `memory`, of half the words, and more parts below;
  // the last TRACE_RAM_WORDS words are a RAM of their own, which the trace sink writes (see `shared`)
  localparam MEMDEPTH = TRACE_SHARED ? DEPTH/2 : DEPTH;
  logic [P.XLEN-1:0] MemDout;
  logic              MemCe;
  ram1p1rwbe #(P.USE_SRAM, MEMDEPTH, P.XLEN, PRELOAD) memory(.clk(HCLK), .ce(MemCe),
    .addr(RamAddr[$clog2(MEMDEPTH)+OFFSET-1:OFFSET]), .we(memwriteD), .din(HWDATA), .bwe(HWSTRB), .dout(MemDout));

  if (!TRACE_SHARED) begin : plain
    assign MemCe    = 1'b1;
    assign HREADRam = MemDout;
    assign TrGrant  = 1'b0;
    assign TrDout   = '0;
    assign XpDout   = '0;
  end else begin : shared
    // The RAM of DEPTH = 2^N words is split in parts of 2^(N-1), 2^(N-2) ... 2^M words (j = 0, 1 ...),
    // each a power of two that ram1p1rwbe can bank, and the trace RAM of 2^M words (M = log2 TRACE_RAM_WORDS):
    //   part j     word bits N-1:N-j all 1, bit N-1-j 0     (offset 2^N - 2^(N-j))
    //   trace RAM  word bits N-1:M all 1                    (the last TRACE_RAM_WORDS words)
    // A hart owns the port of a part in a cycle that it uses the RAM; the trace RAM's port goes to the sink
    // in every other cycle, and in the cycles in which a hart does not address the trace RAM.
    localparam N = ADDR_WIDTH, M = $clog2(P.TRACE_RAM_WORDS), NP = N - M;
    if (P.XLEN != 32 | 2**M != P.TRACE_RAM_WORDS | M >= N | PRELOAD != 0 | P.RAM_LATENCY != 0)
      $error("TRACE_IN_RAM (TRACE_SHARED) needs XLEN 32, a power-of-two TRACE_RAM_WORDS smaller than the RAM, no preload, and RAM_LATENCY 0");

    logic [N-1:0] Word;
    assign Word = RamAddr[N+OFFSET-1:OFFSET];

    // A hart needs the RAM port: the address phase of a transfer, the data phase of a write, or the
    // data phase of a read that waits (the held address is read again, to keep the data)
    logic RamXferD, CpuNeeds;
    flopenr #(1) xferreg(HCLK, ~HRESETn, HREADY, HSELRam & HTRANS[1], RamXferD);
    assign CpuNeeds = initTrans | memwriteD | (RamXferD & ~HREADY);

    logic [NP:0]            Sel;                  // which part the address is in; bit NP is the trace RAM
    logic [NP:0]            SelD;                 // the part that the data out belongs to
    logic [NP-1:0][P.XLEN-1:0] PartDout;
    logic [P.XLEN-1:0]      TDout;
    for (genvar j = 0; j < NP; j++) begin : sel
      if (j == 0) begin : first
        assign Sel[j] = ~Word[N-1];
      end else begin : more
        assign Sel[j] = (&Word[N-1:N-j]) & ~Word[N-1-j];
      end
    end
    assign Sel[NP] = &Word[N-1:M];

    assign MemCe       = CpuNeeds & Sel[0];
    assign PartDout[0] = MemDout;
    // With P.AI_SUPPORTED the AI unit has a port to the last part before the trace RAM (j = NP-1, 2^M words): its request wins, as the core
    // is held off the bus then.  The name of the instance (part[j].memory) is the same, as gen_config.py names the macros by it.
    if (P.AI_SUPPORTED & NP < 2) $error("AI_SUPPORTED needs a RAM of at least two parts besides the trace RAM (ram_ahb.sv)");
    for (genvar j = 1; j < NP; j++) begin : part
      localparam XUSE = P.AI_SUPPORTED & (j == NP-1);
      logic XOn;
      assign XOn = XUSE & XpReq;
      ram1p1rwbe #(P.USE_SRAM, 2**(N-1-j), P.XLEN, 0) memory(.clk(HCLK), .ce((CpuNeeds & Sel[j]) | XOn),
        .addr(XOn ? (N-1-j)'(XpAddr) : Word[N-2-j:0]), .we(XOn ? XpWe : memwriteD), .din(XOn ? XpDin : HWDATA),
        .bwe(XOn ? 4'hF : HWSTRB), .dout(PartDout[j]));
    end
    assign XpDout = P.AI_SUPPORTED ? PartDout[NP-1] : '0;

    logic TCpu;
    assign TCpu    = CpuNeeds & Sel[NP];
    assign TrGrant = ~TCpu;
    ram1p1rwbe #(P.USE_SRAM, P.TRACE_RAM_WORDS, P.XLEN, 0) tmem(.clk(HCLK), .ce(TCpu | TrReq),
      .addr(TCpu ? Word[M-1:0] : TrAddr), .we(TCpu ? memwriteD : TrWe), .din(TCpu ? HWDATA : TrDin),
      .bwe(TCpu ? HWSTRB : TrBwe), .dout(TDout));
    assign TrDout = TDout;

    always_ff @(posedge HCLK)
      if (~HRESETn)      SelD <= '0;
      else if (CpuNeeds) SelD <= Sel;
    always_comb begin
      HREADRam = SelD[NP] ? TDout : '0;
      for (int j = 0; j < NP; j++) if (SelD[j]) HREADRam = PartDout[j];
    end
  end

  // use this to add arbitrary latency to ram. Helps test AHB controller correctness
  if (P.RAM_LATENCY > 0) begin
    logic [7:0]       NextCycle, Cycle;
    logic             CntEn, CntRst;
    logic             CycleFlag;

    flopenr #(8) counter (HCLK, ~HRESETn | CntRst, CntEn, NextCycle, Cycle);
    assign NextCycle = Cycle + 1'b1;

    typedef enum logic {READY, DELAY} statetype;
    statetype CurrState, NextState;

    always_ff @(posedge HCLK)
      if (~HRESETn)    CurrState <= READY;
      else             CurrState <= NextState;

    always_comb begin
      case (CurrState)
        READY:   if (initTrans & ~CycleFlag) NextState = DELAY;
                 else                        NextState = READY;
        DELAY:   if (CycleFlag)              NextState = READY;
                 else                        NextState = DELAY;
        default:                             NextState = READY;
      endcase
    end

    assign CycleFlag = Cycle == P.RAM_LATENCY[7:0];
    assign CntEn = NextState == DELAY;
    assign DelayReady = NextState == DELAY;
    assign CntRst = NextState == READY;
  end else begin
    assign DelayReady = 1'b0;
  end

endmodule
