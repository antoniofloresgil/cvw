// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Private, direct-mapped write-back data-cache banks; parameterizable multiword lines.
// The arbiter orders atomics, misses and permission acquisition. Optional local
// read/M-write ports overlap independent traffic; each M write broadcasts a
// commit through the arbiter for reservation and instruction invalidation.
// BusRd: flush a modified snooper, downgrade to S, then fill requester in S.
// BusRdX/BusUpgr: flush a modified snooper if any, invalidate peers, take M.
// IFU reads do not allocate, but snoop all banks (including their own hart).
module ahbmsicache import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned WORDS = 256,
  parameter int unsigned LINE_WORDS = 1,
  parameter bit CACHE_TO_CACHE = 0,
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
  typedef enum logic [1:0] {I, S, M} msi_t;
  typedef enum logic [3:0] {IDLE, LOOKUP, SNOOP, ADDRESS, DATA, COMPLETE, REPLY, ERROR_REPLY} state_t;
  typedef enum logic [1:0] {EVICT, FLUSH, FILL, BYPASS} transfer_t;
  // One independently tagged/stateful data bank per hart, not a shared cache.
  msi_t [NCORES-1:0][N_LINES-1:0] States;
  logic [TAG-1:0] Tags[NCORES][N_LINES];
  logic [P.AHBW-1:0] Lines[NCORES][WORDS];
  state_t State;
  transfer_t Transfer;
  logic [HART_BITS-1:0] Owner, Snooper, FlushOwner, Supplier;
  logic AnyHit;
  logic [P.PA_BITS-1:0] Addr;
  logic [INDEX-1:0] Index;
  logic [TAG-1:0] Tag;
  logic [P.AHBW-1:0] WriteData, FillData;
  logic [P.AHBW-1:0] FillLine[LINE_WORDS];
  logic [BEAT_BITS-1:0] Beat;
  logic [WORD_INDEX-1:0] WordIndex;
  // Flat data storage keeps total capacity independent of line size.
  function automatic int data_index(input logic [INDEX-1:0] idx, input int beat);
    return int'(idx) * LINE_WORDS + beat;
  endfunction
  logic [P.XLEN/8-1:0] Strobes;
  logic Write, Filled, Cacheable, DirtyPeer;
  logic [2:0] Size;
  logic [3:0] Prot;
  logic [NCORES-1:0] Hit;

  if (LOCAL_READS || LOCAL_WRITES) begin : readprobes
    logic [NCORES-1:0] ProbeHit;
    always_comb begin
      for (int h = 0; h < NCORES; h++) begin
        ProbeHit[h] = HRESETn &&
          ((P.UNCORE_RAM_SUPPORTED && ((64'(CacheReadAddr[h]) & ~P.UNCORE_RAM_RANGE) == P.UNCORE_RAM_BASE)) ||
           (P.EXT_MEM_SUPPORTED && ((64'(CacheReadAddr[h]) & ~P.EXT_MEM_RANGE) == P.EXT_MEM_BASE))) &&
          States[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] != I &&
          Tags[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] == CacheReadAddr[h][P.PA_BITS-1:LINE_OFFSET+INDEX];
        CacheReadHit[h] = LOCAL_READS && ProbeHit[h];
        CacheReadData[h] = LOCAL_READS ? Lines[h][CacheReadAddr[h][OFFSET +: WORD_INDEX]] : '0;
        CacheWriteHit[h] = LOCAL_WRITES && ProbeHit[h] &&
          States[h][CacheReadAddr[h][LINE_OFFSET +: INDEX]] == M;
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
  assign Cacheable = (P.UNCORE_RAM_SUPPORTED &&
    ((64'(Addr) & ~P.UNCORE_RAM_RANGE) == P.UNCORE_RAM_BASE)) ||
    (P.EXT_MEM_SUPPORTED && ((64'(Addr) & ~P.EXT_MEM_RANGE) == P.EXT_MEM_BASE));
  always_comb begin
    DirtyPeer = 1'b0;
    AnyHit = 1'b0;
    Supplier = '0;
    Snooper = '0;
    for (int h = 0; h < NCORES; h++) begin
      Hit[h] = States[h][Index] != I && Tags[h][Index] == Tag;
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
  assign UpHREADY = HRESETn && (State == IDLE || State == REPLY);
  assign HTRANS = HRESETn && State == ADDRESS ? 2'b10 : 2'b00;
  assign HBURST = 3'b000;
  assign HMASTLOCK = UpHMASTLOCK;

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
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
      HADDR <= '0;
      HWDATA <= '0;
      HWSTRB <= '0;
      HWRITE <= 1'b0;
      HSIZE <= '0;
      HPROT <= '0;
      States <= '0;
    end else begin
      case (State)
        IDLE, REPLY: begin
          UpHRESP <= 1'b0;
          if (UpHTRANS[1]) begin
            assert (UpHTRANS == 2'b10 && UpHBURST == 0 && int'(UpHOWNER) < NCORES)
              else $fatal(1, "MSI requires serialized SINGLE transfers and a valid owner");
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
            HADDR <= {Tags[Owner][Index], Index, {LINE_OFFSET{1'b0}}};
            HWDATA <= Lines[Owner][data_index(Index, 0)];
            HWSTRB <= '1;
            HWRITE <= 1'b1;
            HSIZE <= 3'(OFFSET);
            HPROT <= 4'b0011;
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
              FillLine[beat] <= Lines[Snooper][data_index(Index, beat)];
            Filled <= 1'b1;
            State <= COMPLETE;
          end else if (Cacheable && DirtyPeer) begin
            HADDR <= {Addr[P.PA_BITS-1:LINE_OFFSET], {LINE_OFFSET{1'b0}}};
            HWDATA <= Lines[Snooper][data_index(Index, 0)];
            Beat <= '0;
            HWSTRB <= '1;
            HWRITE <= 1'b1;
            HSIZE <= 3'(OFFSET);
            HPROT <= 4'b0011;
            FlushOwner <= Snooper;
            Transfer <= FLUSH;
            State <= ADDRESS;
          end else if (CACHE_TO_CACHE && Cacheable && !Write && !Prot[0] && AnyHit) begin
            // After an M->S intervention, subsequent IFU words can use the
            // clean supplier directly. IFU never allocates a D line.
            FillData <= Lines[Supplier][WordIndex];
            Filled <= 1'b1;
            State <= COMPLETE;
          end else if (!Cacheable) begin
            HADDR <= Addr;
            HWDATA <= WriteData;
            HWSTRB <= Strobes;
            HWRITE <= Write;
            HSIZE <= Size;
            HPROT <= Prot;
            Transfer <= BYPASS;
            State <= ADDRESS;
          end else if (!Hit[Owner] || !Prot[0]) begin
            HADDR <= Prot[0] ? {Addr[P.PA_BITS-1:LINE_OFFSET], {LINE_OFFSET{1'b0}}} :
              {Addr[P.PA_BITS-1:OFFSET], {OFFSET{1'b0}}};
            Beat <= '0;
            HWRITE <= 1'b0;
            HWDATA <= '0;
            HWSTRB <= '0;
            HSIZE <= 3'(OFFSET);
            HPROT <= Prot;
            Transfer <= FILL;
            State <= ADDRESS;
          end else State <= COMPLETE;
        end
        ADDRESS: if (HREADY) State <= DATA;
        DATA: if (HREADY) begin
          if (HRESP) begin
            // Preserve dirty ownership on a failed writeback. Never install
            // a failed fill or grant M before its required operations succeed.
            UpHRESP <= 1'b1;
            UpHRDATA <= '0;
            State <= ERROR_REPLY;
          end else case (Transfer)
            EVICT, FLUSH: begin
              if (CACHE_TO_CACHE && Transfer == FLUSH) begin
                // MSI shared copies must be clean: acknowledge every RAM
                // writeback beat, but forward those same words without reread.
                FillLine[Beat] <= HWDATA;
                if (int'(Beat) == ((int'(Addr) >> OFFSET) & (LINE_WORDS-1)))
                  FillData <= HWDATA;
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
                HADDR <= HADDR + (P.PA_BITS'(1) << OFFSET);
                HWDATA <= Lines[Transfer == EVICT ? Owner : FlushOwner][data_index(Index, int'(Beat)+1)];
                State <= ADDRESS;
              end
            end
            FILL: begin
              FillData <= HRDATA;
              FillLine[Beat] <= HRDATA;
              if (!Prot[0] || int'(Beat) == LINE_WORDS-1) begin
                Filled <= 1'b1;
                State <= COMPLETE;
              end else begin
                Beat <= Beat + 1'b1;
                HADDR <= HADDR + (P.PA_BITS'(1) << OFFSET);
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
            Lines[Owner][WordIndex];
          if (Prot[0]) begin
            Tags[Owner][Index] <= Tag;
            if (Filled)
              for (int beat = 0; beat < LINE_WORDS; beat++)
                Lines[Owner][data_index(Index, beat)] <= FillLine[beat];
            if (Write) begin
              for (int b = 0; b < P.XLEN/8; b++)
                if (Strobes[b]) Lines[Owner][WordIndex][8*b +: 8] <= WriteData[8*b +: 8];
              States[Owner][Index] <= M;
              for (int h = 0; h < NCORES; h++)
                if (HART_BITS'(h) != Owner && Hit[h]) States[h][Index] <= I;
            end else if (Filled) begin
              States[Owner][Index] <= S;
            end
          end
          State <= REPLY;
        end
        ERROR_REPLY: State <= REPLY; // AHB ERROR: low-ready then high-ready.
        default: State <= IDLE;
      endcase
      // An M-hit local commit only changes its owner's bytes. Ownership is
      // already exclusive; the arbiter broadcasts reservation/I invalidation.
      for (int h = 0; h < NCORES; h++)
        if (CacheWriteCommit[h]) begin
          assert (LOCAL_WRITES && CacheWriteHit[h])
            else $fatal(1, "Local store without matching M permission");
          assert ((State == IDLE || State == REPLY) ||
            (Owner != HART_BITS'(h) &&
             Addr[P.PA_BITS-1:LINE_OFFSET] != CacheReadAddr[h][P.PA_BITS-1:LINE_OFFSET]))
            else $fatal(1, "Local M store raced a global owner or snoop");
          for (int b = 0; b < P.XLEN/8; b++)
            if (CacheWriteStrb[h][b])
              Lines[h][CacheReadAddr[h][OFFSET +: WORD_INDEX]][8*b +: 8] <= CacheWriteData[h][8*b +: 8];
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
    assert (NCORES >= 2 && P.AHBW == P.XLEN && (P.XLEN == 32 || P.XLEN == 64))
      else $fatal(1, "MSI requires at least two harts and XLEN-wide AHB");
    assert (LINE_WORDS >= 1 && (LINE_WORDS & (LINE_WORDS-1)) == 0 &&
      WORDS >= 2*LINE_WORDS && (WORDS & (WORDS-1)) == 0 && TAG > 0)
      else $fatal(1, "Private cache capacity must be a power of two with at least two power-of-two lines");
  end
endmodule
