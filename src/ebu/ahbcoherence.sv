// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
///////////////////////////////////////////
// ahbcoherence.sv
//
// Coherence controller for harts whose D-caches are the coherent L1 (COHERENT_L1, ADR 0026).
//
// One coherent transaction at a time holds the slot:
//   - a D-cache acquire (a miss, a write to an S line, an LR, a flush): every other hart's D-cache is snooped
//     (invalidate for a write, downgrade to S otherwise), a dirty line it returns is written to memory, then the
//     requester is granted and does its own AHB transfers until it releases the slot;
//   - an I-cache refill of a cacheable line: every other hart's D-cache is downgraded and its dirty data written
//     to memory before the refill's reads, held in ahbmulticore (FetchHold), may go on. A refill of the hart that
//     holds the slot is served inside its transaction, since both share that hart's AHB master.
// A hart holding the slot is never snooped. Snoops answer on a sideband with the whole line.
//
// The controller sits between ahbmulticore's downstream port (Up*) and memory, and writes snooped dirty lines
// with SINGLE transfers in the gaps between ahbmulticore's transfers.
///////////////////////////////////////////

module ahbcoherence import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2
)(
  input  logic HCLK, HRESETn,
  // Each hart's D-cache
  input  logic [NCORES-1:0] AcqReq, AcqWrite, AcqFlush,
  input  logic [NCORES-1:0][P.PA_BITS-1:0] AcqAdr,
  output logic [NCORES-1:0] Gnt, GntExcl,
  input  logic [NCORES-1:0] Rel,
  output logic [NCORES-1:0] SnpReq, SnpInv,
  output logic [NCORES-1:0][P.PA_BITS-1:0] SnpAdr,
  input  logic [NCORES-1:0] SnpAck, SnpHit, SnpDirty,
  input  logic [NCORES-1:0][P.DCACHE_LINELENINBITS-1:0] SnpData,
  // Each hart's instruction fetch waiting in ahbmulticore (a cacheable read with HPROT[0] = 0)
  input  logic [NCORES-1:0] FetchPending,
  input  logic [NCORES-1:0][P.PA_BITS-1:0] FetchAddr,
  output logic [NCORES-1:0] FetchHold,
  // ahbmulticore's downstream port
  input  logic [P.PA_BITS-1:0] UpHADDR,
  input  logic [P.AHBW-1:0] UpHWDATA,
  input  logic [P.XLEN/8-1:0] UpHWSTRB,
  input  logic UpHWRITE, UpHMASTLOCK,
  input  logic [2:0] UpHSIZE, UpHBURST,
  input  logic [3:0] UpHPROT,
  input  logic [1:0] UpHTRANS,
  output logic [P.AHBW-1:0] UpHRDATA,
  output logic UpHREADY, UpHRESP,
  // Memory and peripherals
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
  localparam LINELEN     = P.DCACHE_LINELENINBITS;
  localparam LINEBYTES   = LINELEN/8;
  localparam OFFSET      = $clog2(LINEBYTES);
  localparam BEATS       = LINELEN/P.AHBW;
  localparam BEAT_BITS   = BEATS > 1 ? $clog2(BEATS) : 1;
  localparam FETCH_BEATS = P.ICACHE_SUPPORTED ? P.ICACHE_LINELENINBITS/P.AHBW : 1;
  localparam FETCH_OFFSET = $clog2(P.ICACHE_SUPPORTED ? P.ICACHE_LINELENINBITS/8 : P.AHBW/8);
  localparam FB_BITS     = $clog2(FETCH_BEATS + 1);
  localparam HART_BITS   = NCORES > 1 ? $clog2(NCORES) : 1;

  typedef enum logic [2:0] {IDLE, SNOOP, WRITEBACK, GRANT, HELD} state_t;
  state_t State;

  logic [HART_BITS-1:0]    Cur, First;        // requester; round-robin start
  logic                    CurFetch;          // the transaction is an instruction refill's snoop
  logic                    Nested;            // a refill of the holder, inside its transaction
  logic                    HolderReleased;    // the holder released the slot during its nested refill
  logic                    CurWrite, CurFlush;
  logic [P.PA_BITS-1:0]    CurAdr;            // line being acquired (or refilled)
  logic [NCORES-1:0]       SnoopWait;         // harts still to answer
  logic                    SnoopHitAny, LineDirty;
  logic [LINELEN-1:0]      Line;              // dirty line returned by a snoop
  logic [NCORES-1:0]       FetchAllowed;      // the hart's refill of FetchLine may read memory
  logic [NCORES-1:0][P.PA_BITS-1:0] FetchLine;
  logic [NCORES-1:0][FB_BITS-1:0]   FetchLeft; // refill reads still allowed
  logic [NCORES-1:0]       FetchPendingQ, FetchMatch, FetchWant;
  logic                    Found, PickFetch;
  logic [HART_BITS-1:0]    Pick;
  logic                    WReq, WDone;       // write the snooped line to memory

  function automatic logic [P.PA_BITS-1:0] lineOf(input logic [P.PA_BITS-1:0] a, input int bits);
    return (a >> bits) << bits;
  endfunction

  // Instruction refills: allowed for one line once the other D-caches have been downgraded
  for (genvar h = 0; h < NCORES; h++) begin : fetch
    assign FetchMatch[h] = FetchAllowed[h] && lineOf(FetchAddr[h], FETCH_OFFSET) == FetchLine[h];
    assign FetchWant[h]  = FetchPending[h] && !FetchMatch[h];
    assign FetchHold[h]  = FetchWant[h];
  end

  // Round-robin over the D-caches' acquires and the refills (refill of hart h before its acquire)
  always_comb begin
    Found = 1'b0; Pick = First; PickFetch = 1'b0;
    for (int offset = 0; offset < NCORES; offset++) begin
      int c;
      c = int'(First) + offset;
      if (c >= NCORES) c = c - NCORES;
      if (!Found && FetchWant[c]) begin Found = 1'b1; Pick = HART_BITS'(c); PickFetch = 1'b1; end
      else if (!Found && AcqReq[c]) begin Found = 1'b1; Pick = HART_BITS'(c); PickFetch = 1'b0; end
    end
  end

  // Snoops go to every hart but the requester; a flush snoops nobody
  for (genvar h = 0; h < NCORES; h++) begin : snoop
    assign SnpReq[h] = State == SNOOP && SnoopWait[h];
    assign SnpInv[h] = CurWrite && !CurFetch;
    assign SnpAdr[h] = CurAdr;
    assign Gnt[h]    = State == GRANT && Cur == HART_BITS'(h) && AcqReq[h] && AcqAdr[h] == CurAdr &&
                       AcqWrite[h] == CurWrite && AcqFlush[h] == CurFlush;
    assign GntExcl[h] = CurWrite || !SnoopHitAny;
  end

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      State <= IDLE; Cur <= '0; First <= '0; CurFetch <= 1'b0; Nested <= 1'b0; HolderReleased <= 1'b0;
      CurWrite <= 1'b0; CurFlush <= 1'b0; CurAdr <= '0; SnoopWait <= '0; SnoopHitAny <= 1'b0; LineDirty <= 1'b0;
      FetchAllowed <= '0; FetchPendingQ <= '0;
    end else begin
      FetchPendingQ <= FetchPending;
      // The holder may complete its access and release the slot while its own refill is being served
      if (Nested && (State == SNOOP || State == WRITEBACK) && Rel[Cur]) HolderReleased <= 1'b1;
      // A refill read that was allowed has been served
      for (int h = 0; h < NCORES; h++)
        if (FetchAllowed[h] && FetchPendingQ[h] && !FetchPending[h]) begin
          FetchLeft[h] <= FetchLeft[h] - 1'b1;
          if (FetchLeft[h] == FB_BITS'(1)) FetchAllowed[h] <= 1'b0;
        end
      case (State)
        IDLE: if (Found) begin
          Cur <= Pick; CurFetch <= PickFetch; Nested <= 1'b0;
          CurWrite <= !PickFetch && AcqWrite[Pick];
          CurFlush <= !PickFetch && AcqFlush[Pick];
          CurAdr <= PickFetch ? lineOf(FetchAddr[Pick], FETCH_OFFSET) : lineOf(AcqAdr[Pick], OFFSET);
          SnoopWait <= (!PickFetch && AcqFlush[Pick]) ? '0 : ~(NCORES'(1) << Pick);
          SnoopHitAny <= 1'b0; LineDirty <= 1'b0;
          State <= SNOOP;
          First <= int'(Pick) == NCORES-1 ? '0 : Pick + 1'b1;
        end
        SNOOP: begin
          for (int h = 0; h < NCORES; h++)
            if (SnoopWait[h] && SnpAck[h]) begin
              SnoopWait[h] <= 1'b0;
              if (SnpHit[h]) SnoopHitAny <= 1'b1;
              if (SnpHit[h] && SnpDirty[h]) begin LineDirty <= 1'b1; Line <= SnpData[h]; end
            end
          if ((SnoopWait & ~SnpAck) == '0) begin           // every hart has answered
            if (LineDirty || (SnoopWait & SnpAck & SnpHit & SnpDirty) != '0) State <= WRITEBACK;
            else if (CurFetch) begin                       // a refill's snoop ends by allowing its reads
              FetchAllowed[Cur] <= 1'b1; FetchLine[Cur] <= CurAdr; FetchLeft[Cur] <= FB_BITS'(FETCH_BEATS);
              State <= (Nested && !HolderReleased && !Rel[Cur]) ? HELD : IDLE;
              HolderReleased <= 1'b0;
            end else State <= GRANT;
          end
        end
        WRITEBACK: if (WDone) begin
          LineDirty <= 1'b0;
          if (CurFetch) begin
            FetchAllowed[Cur] <= 1'b1; FetchLine[Cur] <= CurAdr; FetchLeft[Cur] <= FB_BITS'(FETCH_BEATS);
            State <= (Nested && !HolderReleased && !Rel[Cur]) ? HELD : IDLE;
            HolderReleased <= 1'b0;
          end else State <= GRANT;
        end
        GRANT: State <= (|Gnt && !Rel[Cur]) ? HELD : IDLE;   // a withdrawn request is dropped
        HELD: begin
          if (Rel[Cur]) begin State <= IDLE; CurFetch <= 1'b0; Nested <= 1'b0; HolderReleased <= 1'b0; end
          else if (FetchWant[Cur]) begin       // the holder's own refill: snoop the others, then let it read
            CurFetch <= 1'b1; Nested <= 1'b1;
            CurAdr <= lineOf(FetchAddr[Cur], FETCH_OFFSET);
            SnoopWait <= ~(NCORES'(1) << Cur);
            SnoopHitAny <= 1'b0; LineDirty <= 1'b0;
            State <= SNOOP;
          end
        end
        default: State <= IDLE;
      endcase
    end
  end

  //////////////////////////////////////////////////////////////////
  // Writer: the snooped dirty line, in SINGLE writes between ahbmulticore's transfers
  //////////////////////////////////////////////////////////////////
  typedef enum logic [1:0] {W_IDLE, W_ADDR, W_DATA} wstate_t;
  wstate_t WState;
  logic [BEAT_BITS-1:0] Beat;
  logic UpData, WStart, WOwn;

  assign WReq  = State == WRITEBACK;
  // ahbmulticore has a data phase in flight
  always_ff @(posedge HCLK)
    if (!HRESETn) UpData <= 1'b0;
    else if (HREADY && !WOwn) UpData <= UpHTRANS[1] && UpHREADY;
  assign WStart = WState == W_IDLE && WReq && !UpData && !WDone;
  assign WOwn   = WState != W_IDLE;

  always_ff @(posedge HCLK)
    if (!HRESETn) begin WState <= W_IDLE; Beat <= '0; WDone <= 1'b0; end
    else begin
      WDone <= 1'b0;
      case (WState)
        W_IDLE: if (WStart) begin WState <= W_ADDR; Beat <= '0; end
        W_ADDR: if (HREADY) WState <= W_DATA;
        W_DATA: if (HREADY) begin
          if (int'(Beat) == BEATS-1) begin WState <= W_IDLE; WDone <= 1'b1; end
          else begin WState <= W_ADDR; Beat <= Beat + 1'b1; end
        end
        default: WState <= W_IDLE;
      endcase
    end

  always_comb begin
    if (WOwn) begin
      HADDR = CurAdr + (P.PA_BITS'(Beat) << $clog2(P.AHBW/8));
      HWRITE = 1'b1; HSIZE = 3'($clog2(P.AHBW/8)); HBURST = 3'b000; HPROT = 4'b0011; HMASTLOCK = 1'b0;
      HTRANS = WState == W_ADDR ? 2'b10 : 2'b00;
      HWDATA = Line[Beat*P.AHBW +: P.AHBW];
      HWSTRB = '1;
    end else begin
      {HADDR, HWRITE, HSIZE, HBURST, HPROT, HMASTLOCK, HTRANS, HWDATA, HWSTRB} =
        {UpHADDR, UpHWRITE, UpHSIZE, UpHBURST, UpHPROT, UpHMASTLOCK, UpHTRANS, UpHWDATA, UpHWSTRB};
    end
    // ahbmulticore waits while the writer owns the bus or is about to take it
    UpHREADY = HREADY && !WOwn && !WStart;
    UpHRDATA = HRDATA;
    UpHRESP  = HRESP && !WOwn;
  end

  // synopsys translate_off
  always_ff @(posedge HCLK)
    if (HRESETn) begin
      if (State == SNOOP)
        assert ((SnoopWait & ~(NCORES'(1) << Cur)) == SnoopWait) else $fatal(1, "ahbcoherence: the requester was snooped");
      for (int h = 0; h < NCORES; h++)
        if (Rel[h])
          assert (Cur == HART_BITS'(h) && (State == GRANT || State == HELD || Nested))
            else $fatal(1, "ahbcoherence: hart %0d released a slot it does not hold", h);
      if (WOwn && WState == W_DATA && HREADY)
        assert (!HRESP) else $fatal(1, "ahbcoherence: write-back of a snooped line failed");
      for (int h = 0; h < NCORES; h++)
        if (SnpAck[h] && SnpHit[h] && SnpDirty[h])
          assert ($countones(SnpAck & SnpHit & SnpDirty) == 1) else $fatal(1, "ahbcoherence: two dirty copies of a line");
    end
  // synopsys translate_on
endmodule
