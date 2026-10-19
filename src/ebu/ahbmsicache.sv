// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Private, direct-mapped write-back data-cache banks; one AHB word per line.
// The upstream ahbmulticore arbiter orders ALL accesses, including hits, and
// supplies the requesting hart. This blocking baseline admits one operation
// at a time; no independent local-hit completion or outstanding snoops.
// BusRd: flush a modified snooper, downgrade to S, then fill requester in S.
// BusRdX/BusUpgr: flush a modified snooper if any, invalidate peers, take M.
// IFU reads do not allocate, but snoop all banks (including their own hart).
module ahbmsicache import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned WORDS = 256
)(
  input  logic HCLK, HRESETn,
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
  localparam INDEX = $clog2(WORDS);
  localparam TAG = P.PA_BITS - OFFSET - INDEX;
  localparam HART_BITS = NCORES > 1 ? $clog2(NCORES) : 1;
  typedef enum logic [1:0] {I, S, M} msi_t;
  typedef enum logic [3:0] {IDLE, LOOKUP, SNOOP, ADDRESS, DATA, COMPLETE, REPLY, ERROR_REPLY} state_t;
  typedef enum logic [1:0] {EVICT, FLUSH, FILL, BYPASS} transfer_t;
  // One independently tagged/stateful data bank per hart, not a shared cache.
  msi_t [NCORES-1:0][WORDS-1:0] States;
  logic [TAG-1:0] Tags[NCORES][WORDS];
  logic [P.AHBW-1:0] Lines[NCORES][WORDS];
  state_t State;
  transfer_t Transfer;
  logic [HART_BITS-1:0] Owner, Snooper, FlushOwner;
  logic [P.PA_BITS-1:0] Addr;
  logic [INDEX-1:0] Index;
  logic [TAG-1:0] Tag;
  logic [P.AHBW-1:0] WriteData, FillData;
  logic [P.XLEN/8-1:0] Strobes;
  logic Write, Filled, Cacheable, DirtyPeer;
  logic [2:0] Size;
  logic [3:0] Prot;
  logic [NCORES-1:0] Hit;

  assign Index = Addr[OFFSET +: INDEX];
  assign Tag = Addr[P.PA_BITS-1:OFFSET+INDEX];
  assign Cacheable = (P.UNCORE_RAM_SUPPORTED &&
    ((64'(Addr) & ~P.UNCORE_RAM_RANGE) == P.UNCORE_RAM_BASE)) ||
    (P.EXT_MEM_SUPPORTED && ((64'(Addr) & ~P.EXT_MEM_RANGE) == P.EXT_MEM_BASE));
  always_comb begin
    DirtyPeer = 1'b0;
    Snooper = '0;
    for (int h = 0; h < NCORES; h++) begin
      Hit[h] = States[h][Index] != I && Tags[h][Index] == Tag;
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
            State <= LOOKUP;
          end else State <= IDLE;
        end
        LOOKUP: begin
          // AHB data/strobes arrive one cycle after the accepted address.
          WriteData <= UpHWDATA;
          Strobes <= UpHWSTRB;
          if (Cacheable && Prot[0] && !Hit[Owner] && States[Owner][Index] == M) begin
            HADDR <= {Tags[Owner][Index], Index, {OFFSET{1'b0}}};
            HWDATA <= Lines[Owner][Index];
            HWSTRB <= '1;
            HWRITE <= 1'b1;
            HSIZE <= 3'(OFFSET);
            HPROT <= 4'b0011;
            Transfer <= EVICT;
            State <= ADDRESS;
          end else State <= SNOOP;
        end
        SNOOP: begin
          if (Cacheable && DirtyPeer) begin
            HADDR <= {Addr[P.PA_BITS-1:OFFSET], {OFFSET{1'b0}}};
            HWDATA <= Lines[Snooper][Index];
            HWSTRB <= '1;
            HWRITE <= 1'b1;
            HSIZE <= 3'(OFFSET);
            HPROT <= 4'b0011;
            FlushOwner <= Snooper;
            Transfer <= FLUSH;
            State <= ADDRESS;
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
            HADDR <= {Addr[P.PA_BITS-1:OFFSET], {OFFSET{1'b0}}};
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
            EVICT: begin
              States[Owner][Index] <= I;
              State <= SNOOP;
            end
            FLUSH: begin
              States[FlushOwner][Index] <= S;
              State <= SNOOP;
            end
            FILL: begin
              FillData <= HRDATA;
              Filled <= 1'b1;
              State <= COMPLETE;
            end
            BYPASS: begin
              UpHRDATA <= HRDATA;
              State <= REPLY;
            end
            default: State <= IDLE;
          endcase
        end
        COMPLETE: begin
          UpHRDATA <= Filled ? FillData : Lines[Owner][Index];
          if (Prot[0]) begin
            Tags[Owner][Index] <= Tag;
            if (Write) begin
              Lines[Owner][Index] <= Filled ? FillData : Lines[Owner][Index];
              for (int b = 0; b < P.XLEN/8; b++)
                if (Strobes[b]) Lines[Owner][Index][8*b +: 8] <= WriteData[8*b +: 8];
              States[Owner][Index] <= M;
              for (int h = 0; h < NCORES; h++)
                if (HART_BITS'(h) != Owner && Hit[h]) States[h][Index] <= I;
            end else if (Filled) begin
              Lines[Owner][Index] <= FillData;
              States[Owner][Index] <= S;
            end
          end
          State <= REPLY;
        end
        ERROR_REPLY: State <= REPLY; // AHB ERROR: low-ready then high-ready.
        default: State <= IDLE;
      endcase
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
    assert (WORDS >= 2 && (WORDS & (WORDS-1)) == 0 && TAG > 0)
      else $fatal(1, "Private cache words must be a power of two >= 2 and fit PA_BITS");
  end
endmodule
