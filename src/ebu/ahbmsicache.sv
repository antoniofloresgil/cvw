// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Private, direct-mapped write-back data-cache banks; parameterizable multiword lines.
// The arbiter orders atomics, misses and permission acquisition. Optional local
// read/exclusive-write ports overlap independent traffic; each M write broadcasts a
// commit through the arbiter for reservation and instruction invalidation.
// BusRd: flush M, downgrade a data peer to S; MESI grants E without a peer.
// BusRdX/BusUpgr: flush a modified snooper if any, invalidate peers, take M.
// IFU reads do not allocate, but snoop all banks (including their own hart).
module ahbmsicache import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned WORDS = 8192/(P.AHBW/8),
  parameter int unsigned LINE_WORDS = 1,
  parameter bit CACHE_TO_CACHE = 0,
  parameter bit CACHE_BURSTS = 0,
  parameter bit MESI = 0,
  parameter int unsigned IFILL_WORDS = 1,
  parameter bit LOCAL_READS = 0,
  parameter bit LOCAL_WRITES = 0
)(
  input  logic HCLK, HRESETn,
  input  logic [NCORES-1:0][P.PA_BITS-1:0] CacheReadAddr,
  output logic [NCORES-1:0] CacheReadHit, CacheWriteHit,
  input  logic [NCORES-1:0] CacheWriteCommit,
  input  logic [NCORES-1:0][P.AHBW-1:0] CacheWriteData,
  input  logic [NCORES-1:0][P.XLEN/8-1:0] CacheWriteStrb,
  output logic [NCORES-1:0][P.AHBW-1:0] CacheReadData,
  output logic [NCORES-1:0] DataMiss,            // PMU: a cacheable data request found no line in its owner's bank
  input  logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] UpHOWNER,
  input  logic [P.PA_BITS-1:0] UpHADDR,
  input  logic [P.AHBW-1:0] UpHWDATA,
  input  logic [P.XLEN/8-1:0] UpHWSTRB,
  input  logic UpHWRITE, UpHMASTLOCK,
  input  logic [2:0] UpHSIZE, UpHBURST,
  input  logic [3:0] UpHPROT,
  input  logic [1:0] UpHTRANS,
  output logic [P.AHBW-1:0] UpHRDATA,
  output logic UpHREADY, UpHRESP,
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
  localparam OFFSET = $clog2(P.AHBW/8);
  localparam LINE_BITS = $clog2(LINE_WORDS);
  localparam LINE_OFFSET = OFFSET + LINE_BITS;
  localparam N_LINES = WORDS / LINE_WORDS;
  localparam INDEX = $clog2(N_LINES);
  localparam WORD_INDEX = $clog2(WORDS);
  localparam BEAT_BITS = LINE_BITS > 0 ? LINE_BITS : 1;
  localparam TAG = P.PA_BITS - LINE_OFFSET - INDEX;
  localparam HART_BITS = NCORES > 1 ? $clog2(NCORES) : 1;
  typedef enum logic [1:0] {I, S, M, E} msi_t;
  typedef enum logic [3:0] {IDLE, LOOKUP, SNOOP, ADDRESS, DATA, COMPLETE, REPLY, ERROR_REPLY} state_t;
  typedef enum logic [2:0] {EVICT, FLUSH, FILL, BYPASS, IFILL} transfer_t;
  // One independently tagged/stateful data bank per hart, not a shared cache.
  msi_t [NCORES-1:0][N_LINES-1:0] States;
  logic [TAG-1:0] Tags[NCORES][N_LINES];
  state_t State;
  transfer_t Transfer;
  logic [HART_BITS-1:0] Owner, Snooper, FlushOwner, Supplier;
  logic AnyHit, PeerHit;
  logic [P.PA_BITS-1:0] Addr;
  logic [INDEX-1:0] Index;
  logic [TAG-1:0] Tag;
  logic [P.AHBW-1:0] WriteData, FillData;
  logic [P.AHBW-1:0] FillLine[LINE_WORDS];
  logic [BEAT_BITS-1:0] Beat;
  logic [WORD_INDEX-1:0] WordIndex;
  logic [P.XLEN/8-1:0] Strobes;
  logic Write, Filled, Cacheable, DirtyPeer;
  logic [2:0] Size;
  logic [3:0] Prot;
  logic [NCORES-1:0] Hit;

  logic [NCORES-1:0][WORD_INDEX-1:0] LocalWordIndex;
  logic [NCORES-1:0][P.AHBW-1:0] LocalReadData;
  logic [HART_BITS-1:0] WordReadOwner, LineReadOwner;
  logic [P.AHBW-1:0] WordReadData, LineReadData[LINE_WORDS];
  assign WordReadOwner = State == COMPLETE ? Owner : Supplier;
  assign LineReadOwner = State == LOOKUP ? Owner : State == SNOOP ? Snooper :
    Transfer == EVICT ? Owner : FlushOwner;
  for (genvar h = 0; h < NCORES; h++) begin : dataindices
    assign LocalWordIndex[h] = CacheReadAddr[h][OFFSET +: WORD_INDEX];
  end
  multicore_dcache_data #(.P(P), .NCORES(NCORES), .WORDS(WORDS), .LINE_WORDS(LINE_WORDS)) data_bank(
    .HCLK, .HRESETn, .LocalWordIndex, .LocalReadData,
    .WordReadOwner, .WordReadIndex(WordIndex), .WordReadData, .LineReadOwner, .LineReadIndex(Index), .LineReadData,
    .Install(State == COMPLETE && Prot[0] && Filled), .Store(State == COMPLETE && Prot[0] && Write),
    .WriteOwner(Owner), .InstallIndex(Index), .InstallLine(FillLine),
    .StoreIndex(WordIndex), .StoreData(WriteData), .StoreStrb(Strobes),
    .LocalStore(CacheWriteCommit), .LocalStoreData(CacheWriteData), .LocalStoreStrb(CacheWriteStrb));
  // synopsys translate_off
  // Preserve existing passive test probes without exporting arrays as hardware
  // ports. Functional datapaths use only the explicit storage ports above.
  wire [P.AHBW-1:0] Lines[NCORES][WORDS];
  assign Lines = data_bank.Lines;
  // synopsys translate_on

  localparam MAX_WORDS = LINE_WORDS > IFILL_WORDS ? LINE_WORDS : IFILL_WORDS;
  localparam BC = $clog2(MAX_WORDS+1);
  localparam IO = OFFSET+$clog2(IFILL_WORDS);
  logic [P.PA_BITS-1:0] SAddr, BAddr;
  logic [P.AHBW-1:0] SWData, BWData;
  logic [P.XLEN/8-1:0] SStrb, BStrb;
  logic SWrite, BWrite, BurstDone, BurstError, UseBurst;
  logic [2:0] SSize, BSize, BBurst;
  logic [3:0] SProt, BProt;
  logic [1:0] STrans, BTrans;
  logic [P.AHBW-1:0] BurstReadLine[MAX_WORDS], BurstWriteLine[MAX_WORDS];
  logic IBufferValid, IFillClean;
  logic [P.PA_BITS-1:0] IBufferBase;
  logic [P.AHBW-1:0] IBuffer[IFILL_WORDS];
  logic [P.PA_BITS-1:0] ProbeIAddr;
  always_comb begin
    IFillClean = 1'b1;
    ProbeIAddr = '0;
    // Prefetch IFU words only when the ENTIRE I line is current in RAM.
    // Other D lines in a larger I region may have different dirty owners.
    for (int w = 0; w < IFILL_WORDS; w++) begin
      ProbeIAddr = ((Addr >> IO) << IO) + (P.PA_BITS'(w) << OFFSET);
      for (int h = 0; h < NCORES; h++)
        if (States[h][ProbeIAddr[LINE_OFFSET +: INDEX]] == M &&
            Tags[h][ProbeIAddr[LINE_OFFSET +: INDEX]] == ProbeIAddr[P.PA_BITS-1:LINE_OFFSET+INDEX])
          IFillClean = 1'b0;
    end
  end
  assign UseBurst = CACHE_BURSTS &&
    (Transfer == IFILL || (LINE_WORDS > 1 &&
     (Transfer == EVICT || Transfer == FLUSH || (Transfer == FILL && Prot[0]))));
  for (genvar w = 0; w < MAX_WORDS; w++) begin : writebuffer
    if (w < LINE_WORDS)
      assign BurstWriteLine[w] = LineReadData[w];
    else assign BurstWriteLine[w] = '0;
  end
  if (CACHE_BURSTS && MAX_WORDS > 1) begin : burst
    ahblineburst #(.P(P), .MAX_WORDS(MAX_WORDS)) engine(
      .HCLK, .HRESETn, .Start(UseBurst && State == ADDRESS), .Write(SWrite), .Base(SAddr),
      .WordCount(BC'(Transfer == IFILL ? IFILL_WORDS : LINE_WORDS)), .Prot(SProt),
      .WriteLine(BurstWriteLine), .ReadLine(BurstReadLine), .Done(BurstDone), .Error(BurstError),
      .HADDR(BAddr), .HWDATA(BWData), .HWSTRB(BStrb), .HWRITE(BWrite), .HSIZE(BSize),
      .HBURST(BBurst), .HPROT(BProt), .HTRANS(BTrans), .HRDATA, .HREADY, .HRESP);
    assign {HADDR, HWDATA, HWSTRB, HWRITE, HSIZE, HBURST, HPROT, HTRANS} = UseBurst ?
      {BAddr, BWData, BStrb, BWrite, BSize, BBurst, BProt, BTrans} :
      {SAddr, SWData, SStrb, SWrite, SSize, 3'b000, SProt, STrans};
  end else begin : scalar
    assign {HADDR, HWDATA, HWSTRB, HWRITE, HSIZE, HBURST, HPROT, HTRANS} =
      {SAddr, SWData, SStrb, SWrite, SSize, 3'b000, SProt, STrans};
    assign {BAddr, BWData, BStrb, BWrite, BSize, BBurst, BProt, BTrans, BurstDone, BurstError} = '0;
    for (genvar w = 0; w < MAX_WORDS; w++) assign BurstReadLine[w] = '0;
  end

  if (LOCAL_READS || LOCAL_WRITES) begin : readprobes
    logic [NCORES-1:0] ProbeHit;
    always_comb begin
      for (int h = 0; h < NCORES; h++) begin
        ProbeHit[h] = HRESETn &&
          multicore_cacheable(P, 64'(CacheReadAddr[h])) &&
          States[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] != I &&
          Tags[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] == CacheReadAddr[h][P.PA_BITS-1:LINE_OFFSET+INDEX];
        CacheReadHit[h] = LOCAL_READS && ProbeHit[h];
        CacheReadData[h] = LOCAL_READS ? LocalReadData[h] : '0;
        CacheWriteHit[h] = LOCAL_WRITES && ProbeHit[h] &&
          (States[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] == M ||
           (MESI && States[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] == E));
      end
    end
  end else begin : noreadprobes
    assign CacheReadHit = '0;
    assign CacheWriteHit = '0;
    assign CacheReadData = '0;
  end

  assign Index = Addr[LINE_OFFSET +: INDEX];
  assign WordIndex = Addr[OFFSET +: WORD_INDEX];
  assign Tag = Addr[P.PA_BITS-1:LINE_OFFSET+INDEX];
  assign Cacheable = multicore_cacheable(P, 64'(Addr));
  always_comb begin
    DirtyPeer = 1'b0;
    AnyHit = 1'b0;
    PeerHit = 1'b0;
    Supplier = '0;
    Snooper = '0;
    for (int h = 0; h < NCORES; h++) begin
      Hit[h] = States[h][Index] != I && Tags[h][Index] == Tag;
      if (Hit[h] && HART_BITS'(h) != Owner) PeerHit = 1'b1;
      if (Hit[h] && !AnyHit) begin
        AnyHit = 1'b1;
        Supplier = HART_BITS'(h);
      end
      // An uncached instruction fetch must also snoop its own D-cache.
      if (Hit[h] && States[h][Index] == M && (HART_BITS'(h) != Owner || !Prot[0])) begin
        DirtyPeer = 1'b1;
        Snooper = HART_BITS'(h);
      end
    end
  end
  // Count the miss once, at lookup; a permission upgrade of a present line is a hit.
  always_comb begin
    DataMiss = '0;
    if (State == LOOKUP && Cacheable && Prot[0] && !Hit[Owner]) DataMiss[Owner] = 1'b1;
  end

  assign UpHREADY = HRESETn && (State == IDLE || State == REPLY);
  assign STrans = HRESETn && State == ADDRESS ? 2'b10 : 2'b00;

  assign HMASTLOCK = UpHMASTLOCK;

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      IBufferValid <= 1'b0;
      IBufferBase <= '0;
      State <= IDLE;
      Beat <= '0;
      Transfer <= BYPASS;
      Owner <= '0;
      FlushOwner <= '0;
      Addr <= '0;
      WriteData <= '0;
      FillData <= '0;
      Strobes <= '0;
      Write <= 1'b0;
      Filled <= 1'b0;
      Size <= '0;
      Prot <= '0;
      UpHRDATA <= '0;
      UpHRESP <= 1'b0;
      SAddr <= '0;
      SWData <= '0;
      SStrb <= '0;
      SWrite <= 1'b0;
      SSize <= '0;
      SProt <= '0;
      States <= '0;
    end else begin
      case (State)
        IDLE, REPLY: begin
          UpHRESP <= 1'b0;
          if (UpHTRANS[1]) begin
            assert (UpHTRANS == 2'b10 && UpHBURST == 0 && int'(UpHOWNER) < NCORES)
              else $fatal(1, "MSI requires serialized SINGLE transfers and a valid owner");
            if (UpHWRITE || UpHPROT[0] ||
                UpHADDR[P.PA_BITS-1:IO] != IBufferBase[P.PA_BITS-1:IO]) IBufferValid <= 1'b0;
            Addr <= UpHADDR;
            Owner <= UpHOWNER;
            Size <= UpHSIZE;
            Prot <= UpHPROT;
            Write <= UpHWRITE;
            Filled <= 1'b0;
            Beat <= '0;
            State <= LOOKUP;
          end else State <= IDLE;
        end
        LOOKUP: begin
          // AHB data/strobes arrive one cycle after the accepted address.
          WriteData <= UpHWDATA;
          Strobes <= UpHWSTRB;
          if (Cacheable && Prot[0] && !Hit[Owner] && States[Owner][Index] == M) begin
            SAddr <= {Tags[Owner][Index], Index, {LINE_OFFSET{1'b0}}};
            SWData <= LineReadData[0];
            SStrb <= '1;
            SWrite <= 1'b1;
            SSize <= 3'(OFFSET);
            SProt <= 4'b0011;
            Transfer <= EVICT;
            State <= ADDRESS;
          end else State <= SNOOP;
        end
        SNOOP: begin
          if (CACHE_TO_CACHE && Cacheable && DirtyPeer && Write && Prot[0]) begin
            // Move dirty responsibility directly M->M. Keep the supplier M
            // until COMPLETE atomically installs the requester and invalidates
            // every peer. No target-line RAM write/read is needed.
            for (int beat = 0; beat < LINE_WORDS; beat++)
              FillLine[beat] <= LineReadData[beat];
            Filled <= 1'b1;
            State <= COMPLETE;
          end else if (Cacheable && DirtyPeer) begin
            SAddr <= {Addr[P.PA_BITS-1:LINE_OFFSET], {LINE_OFFSET{1'b0}}};
            SWData <= LineReadData[0];
            Beat <= '0;
            SStrb <= '1;
            SWrite <= 1'b1;
            SSize <= 3'(OFFSET);
            SProt <= 4'b0011;
            FlushOwner <= Snooper;
            Transfer <= FLUSH;
            State <= ADDRESS;
          end else if (CACHE_BURSTS && Cacheable && !Write && !Prot[0] && IBufferValid &&
              Addr[P.PA_BITS-1:IO] == IBufferBase[P.PA_BITS-1:IO]) begin
            FillData <= IBuffer[(int'(Addr) >> OFFSET) & (IFILL_WORDS-1)];
            if (((int'(Addr) >> OFFSET) & (IFILL_WORDS-1)) == IFILL_WORDS-1) IBufferValid <= 1'b0;
            Filled <= 1'b1;
            State <= COMPLETE;
          end else if (CACHE_TO_CACHE && Cacheable && !Write && !Prot[0] && AnyHit) begin
            // After an M->S intervention, subsequent IFU words can use the
            // clean supplier directly. IFU never allocates a D line.
            FillData <= WordReadData;
            Filled <= 1'b1;
            State <= COMPLETE;
          end else if (!Cacheable) begin
            SAddr <= Addr;
            SWData <= WriteData;
            SStrb <= Strobes;
            SWrite <= Write;
            SSize <= Size;
            SProt <= Prot;
            Transfer <= BYPASS;
            State <= ADDRESS;
          end else if (CACHE_BURSTS && IFILL_WORDS > 1 && !Write && !Prot[0] && IFillClean) begin
            SAddr <= (Addr >> IO) << IO;
            SWrite <= 1'b0; SWData <= '0; SStrb <= '0;
            SSize <= 3'(OFFSET); SProt <= Prot;
            IBufferValid <= 1'b0;
            Transfer <= IFILL;
            State <= ADDRESS;
          end else if (!Hit[Owner] || !Prot[0]) begin
            SAddr <= Prot[0] ? {Addr[P.PA_BITS-1:LINE_OFFSET], {LINE_OFFSET{1'b0}}} :
              {Addr[P.PA_BITS-1:OFFSET], {OFFSET{1'b0}}};
            Beat <= '0;
            SWrite <= 1'b0;
            SWData <= '0;
            SStrb <= '0;
            SSize <= 3'(OFFSET);
            SProt <= Prot;
            Transfer <= FILL;
            State <= ADDRESS;
          end else State <= COMPLETE;
        end
        ADDRESS: if (UseBurst || HREADY) State <= DATA;
        DATA: if (UseBurst ? BurstDone : HREADY) begin
          if (UseBurst ? BurstError : HRESP) begin
            // Preserve dirty ownership on a failed writeback. Never install
            // a failed fill or grant M before its required operations succeed.
            UpHRESP <= 1'b1;
            UpHRDATA <= '0;
            State <= ERROR_REPLY;
          end else case (Transfer)
            EVICT, FLUSH: if (UseBurst) begin
              if (Transfer == EVICT) States[Owner][Index] <= I;
              else States[FlushOwner][Index] <= S;
              if (CACHE_TO_CACHE && Transfer == FLUSH) begin
                for (int w = 0; w < LINE_WORDS; w++) FillLine[w] <= BurstWriteLine[w];
                FillData <= BurstWriteLine[(int'(Addr) >> OFFSET) & (LINE_WORDS-1)];
                Filled <= 1'b1;
                State <= COMPLETE;
              end else State <= SNOOP;
            end else begin
              if (CACHE_TO_CACHE && Transfer == FLUSH) begin
                // MSI shared copies must be clean: acknowledge every RAM
                // writeback beat, but forward those same words without reread.
                FillLine[Beat] <= SWData;
                if (int'(Beat) == ((int'(Addr) >> OFFSET) & (LINE_WORDS-1)))
                  FillData <= SWData;
              end
              if (int'(Beat) == LINE_WORDS-1) begin
                if (Transfer == EVICT) States[Owner][Index] <= I;
                else States[FlushOwner][Index] <= S;
                Beat <= '0;
                if (CACHE_TO_CACHE && Transfer == FLUSH) begin
                  Filled <= 1'b1;
                  State <= COMPLETE;
                end else State <= SNOOP;
              end else begin
                Beat <= Beat + 1'b1;
                SAddr <= SAddr + (P.PA_BITS'(1) << OFFSET);
                SWData <= LineReadData[int'(Beat)+1];
                State <= ADDRESS;
              end
            end
            IFILL: begin
              for (int w = 0; w < IFILL_WORDS; w++) IBuffer[w] <= BurstReadLine[w];
              IBufferBase <= (Addr >> IO) << IO;
              // This buffer serves the current ordered I-line refill only.
              IBufferValid <= ((int'(Addr) >> OFFSET) & (IFILL_WORDS-1)) != IFILL_WORDS-1;
              FillData <= BurstReadLine[(int'(Addr) >> OFFSET) & (IFILL_WORDS-1)];
              Filled <= 1'b1;
              State <= COMPLETE;
            end
            FILL: if (UseBurst) begin
              for (int w = 0; w < LINE_WORDS; w++) FillLine[w] <= BurstReadLine[w];
              Filled <= 1'b1;
              State <= COMPLETE;
            end else begin
              FillData <= HRDATA;
              FillLine[Beat] <= HRDATA;
              if (!Prot[0] || int'(Beat) == LINE_WORDS-1) begin
                Filled <= 1'b1;
                State <= COMPLETE;
              end else begin
                Beat <= Beat + 1'b1;
                SAddr <= SAddr + (P.PA_BITS'(1) << OFFSET);
                State <= ADDRESS;
              end
            end
            BYPASS: begin
              UpHRDATA <= HRDATA;
              State <= REPLY;
            end
            default: State <= IDLE;
          endcase
        end
        COMPLETE: begin
          UpHRDATA <= Filled ? (Prot[0] ? FillLine[(int'(Addr) >> OFFSET) & (LINE_WORDS-1)] : FillData) :
            WordReadData;
          if (Prot[0]) begin
            Tags[Owner][Index] <= Tag;
            if (Write) begin
              States[Owner][Index] <= M;
              for (int h = 0; h < NCORES; h++)
                if (HART_BITS'(h) != Owner && Hit[h]) States[h][Index] <= I;
            end else if (Filled) begin
              States[Owner][Index] <= MESI && !PeerHit ? E : S;
            end
            // A successful data read shares a clean exclusive peer. IFU
            // reads do not allocate D copies; stores still invalidate I banks.
            if (MESI && !Write)
              for (int h = 0; h < NCORES; h++)
                if (HART_BITS'(h) != Owner && Hit[h] && States[h][Index] == E)
                  States[h][Index] <= S;
          end
          State <= REPLY;
        end
        ERROR_REPLY: State <= REPLY; // AHB ERROR: low-ready then high-ready.
        default: State <= IDLE;
      endcase
      // An M/E-hit local commit promotes E to M and changes its owner's bytes. Ownership is
      // already exclusive; the arbiter broadcasts reservation/I invalidation.
      for (int h = 0; h < NCORES; h++)
        if (CacheWriteCommit[h]) begin
          IBufferValid <= 1'b0;
          assert (LOCAL_WRITES && CacheWriteHit[h])
            else $fatal(1, "Local store without exclusive permission");
          assert ((State == IDLE || State == REPLY) ||
            (Owner != HART_BITS'(h) &&
             Addr[P.PA_BITS-1:LINE_OFFSET] != CacheReadAddr[h][P.PA_BITS-1:LINE_OFFSET]))
            else $fatal(1, "Local M store raced a global owner or snoop");
          States[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] <= M;
        end
      // Snooping is a broadcast lookup to every bank. At most one dirty owner
      // exists and it cannot coexist with any other valid copy of that word.
      for (int h = 0; h < NCORES; h++)
        for (int peer = h+1; peer < NCORES; peer++)
          if (Hit[h] && Hit[peer])
            assert (States[h][Index] == S && States[peer][Index] == S)
              else $fatal(1, "MSI ownership invariant violated");
    end
  end
  initial begin
    assert (IFILL_WORDS >= 1 && (IFILL_WORDS & (IFILL_WORDS-1)) == 0)
      else $fatal(1, "IFU burst line must be a power of two");
    assert (NCORES >= 2 && P.AHBW == P.XLEN && (P.XLEN == 32 || P.XLEN == 64))
      else $fatal(1, "MSI requires at least two harts and XLEN-wide AHB");
    assert (LINE_WORDS >= 1 && (LINE_WORDS & (LINE_WORDS-1)) == 0 &&
      WORDS >= 2*LINE_WORDS && (WORDS & (WORDS-1)) == 0 && TAG > 0)
      else $fatal(1, "Private cache capacity must be a power of two with at least two power-of-two lines");
  end
endmodule
