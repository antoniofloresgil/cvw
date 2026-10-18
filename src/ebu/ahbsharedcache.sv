// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Unified physical cache after the multicore serialization/reservation point.
// One AHB word per line, direct mapped, read allocate, write through/invalidate.
// All memory writers must pass through this bridge; MMIO is never allocated.
module ahbsharedcache import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned WORDS = 256
)(
  input  logic HCLK, HRESETn,
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
  localparam TAG = P.PA_BITS - INDEX - OFFSET;
  typedef enum logic [2:0] {IDLE, ADDRESS, DATA, REPLY, ERROR_REPLY} state_t;
  state_t State;
  logic [WORDS-1:0] Valid;
  logic [TAG-1:0] Tags [WORDS];
  logic [P.AHBW-1:0] Lines [WORDS];
  logic [P.PA_BITS-1:0] Addr;
  logic [2:0] Size;
  logic [3:0] Prot;
  logic Write, Allocate, Cacheable, Hit;
  logic [INDEX-1:0] LookupIndex, FillIndex;
  logic [TAG-1:0] LookupTag;

  assign LookupIndex = UpHADDR[OFFSET +: INDEX];
  assign LookupTag = UpHADDR[P.PA_BITS-1:OFFSET+INDEX];
  assign FillIndex = Addr[OFFSET +: INDEX];
  // Cache only ordinary RAM. ROM and peripheral accesses retain their size,
  // address, byte strobes and completion ordering on the downstream bus.
  assign Cacheable = (P.UNCORE_RAM_SUPPORTED &&
    ((64'(UpHADDR) & ~P.UNCORE_RAM_RANGE) == P.UNCORE_RAM_BASE)) ||
    (P.EXT_MEM_SUPPORTED && ((64'(UpHADDR) & ~P.EXT_MEM_RANGE) == P.EXT_MEM_BASE));
  assign Hit = Cacheable && Valid[LookupIndex] && Tags[LookupIndex] == LookupTag;
  assign UpHREADY = HRESETn && (State == IDLE || State == REPLY);
  assign HADDR = Addr;
  assign HSIZE = Size;
  assign HWRITE = Write;
  assign HPROT = Prot;
  assign HBURST = 3'b000;
  assign HTRANS = State == ADDRESS && HRESETn ? 2'b10 : 2'b00;
  assign HWDATA = UpHWDATA;
  assign HWSTRB = UpHWSTRB;
  assign HMASTLOCK = UpHMASTLOCK;

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      State <= IDLE;
      Valid <= '0;
      Addr <= '0;
      Size <= '0;
      Prot <= '0;
      Write <= 1'b0;
      Allocate <= 1'b0;
      UpHRDATA <= '0;
      UpHRESP <= 1'b0;
    end else begin
      case (State)
        IDLE, REPLY: begin
          UpHRESP <= 1'b0;
          if (UpHTRANS[1]) begin
            assert (UpHTRANS == 2'b10 && UpHBURST == 0)
              else $fatal(1, "Shared cache requires serialized SINGLE transfers");
            Write <= UpHWRITE;
            Prot <= UpHPROT;
            Allocate <= Cacheable && !UpHWRITE;
            // An allocated line always contains a complete bus word, including
            // when the initiating load or instruction fetch reads fewer bytes.
            Addr <= Cacheable && !UpHWRITE ? {UpHADDR[P.PA_BITS-1:OFFSET], {OFFSET{1'b0}}} : UpHADDR;
            Size <= Cacheable && !UpHWRITE ? 3'(OFFSET) : UpHSIZE;
            if (Hit && !UpHWRITE) begin
              UpHRDATA <= Lines[LookupIndex];
              State <= REPLY;
            end else State <= ADDRESS;
            if (Hit && UpHWRITE) Valid[LookupIndex] <= 1'b0;
          end else State <= IDLE;
        end
        ADDRESS: if (HREADY) State <= DATA;
        DATA: if (HREADY) begin
          UpHRDATA <= HRDATA;
          UpHRESP <= HRESP;
          State <= HRESP ? ERROR_REPLY : REPLY;
          if (Allocate && !HRESP) begin
            Lines[FillIndex] <= HRDATA;
            Tags[FillIndex] <= Addr[P.PA_BITS-1:OFFSET+INDEX];
            Valid[FillIndex] <= 1'b1;
          end
        end
        ERROR_REPLY: State <= REPLY;
        default: State <= IDLE;
      endcase
    end
  end
  initial begin
    assert (WORDS >= 2 && (WORDS & (WORDS-1)) == 0 && TAG > 0 && P.AHBW == P.XLEN)
      else $fatal(1, "Shared cache requires power-of-two WORDS >= 2 and AHBW == XLEN");
  end
endmodule
