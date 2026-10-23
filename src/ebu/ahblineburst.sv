// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Full-line AHB-Lite master. Address and data beat indices are independent:
// the next address overlaps the preceding data, including through wait states.
module ahblineburst import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned MAX_WORDS = 4,
  parameter int unsigned COUNT_BITS = $clog2(MAX_WORDS+1)
)(
  input logic HCLK, HRESETn, Start, Write,
  input logic [P.PA_BITS-1:0] Base,
  input logic [COUNT_BITS-1:0] WordCount,
  input logic [3:0] Prot,
  input logic [P.AHBW-1:0] WriteLine[MAX_WORDS],
  output logic [P.AHBW-1:0] ReadLine[MAX_WORDS],
  output logic Done, Error,
  output logic [P.PA_BITS-1:0] HADDR,
  output logic [P.AHBW-1:0] HWDATA,
  output logic [P.XLEN/8-1:0] HWSTRB,
  output logic HWRITE,
  output logic [2:0] HSIZE, HBURST,
  output logic [3:0] HPROT,
  output logic [1:0] HTRANS,
  input logic [P.AHBW-1:0] HRDATA,
  input logic HREADY, HRESP
);
  localparam OFFSET = $clog2(P.AHBW/8);
  logic Active, DataValid;
  logic [COUNT_BITS-1:0] AddressBeat, DataBeat, Count;
  logic [P.PA_BITS-1:0] AddressBase;
  assign HADDR = AddressBase + (P.PA_BITS'(AddressBeat) << OFFSET);
  assign HWDATA = WriteLine[int'(DataBeat) < MAX_WORDS ? int'(DataBeat) : 0];
  assign HWSTRB = '1;
  assign HSIZE = 3'(OFFSET);
  // Restart after each 16-beat chunk; aligned chunks cannot cross 1 KiB.
  assign HBURST = int'(Count) >= 16 ? 3'b111 : int'(Count) == 8 ? 3'b101 :
    int'(Count) == 4 ? 3'b011 : int'(Count) == 2 ? 3'b001 : 3'b000;
  assign HTRANS = HRESETn && Active && AddressBeat < Count && !HRESP ?
    (int'(AddressBeat) % 16 == 0 ? 2'b10 : 2'b11) : 2'b00;
  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      Active <= 0; DataValid <= 0; AddressBeat <= '0; DataBeat <= '0; Count <= '0;
      AddressBase <= '0; HWRITE <= 0; HPROT <= '0; Done <= 0; Error <= 0;
    end else begin
      Done <= 0;
      if (Start) begin
        assert (!Active && WordCount > 0 && int'(WordCount) <= MAX_WORDS &&
          (int'(WordCount) & (int'(WordCount)-1)) == 0 &&
          (Base & ((P.PA_BITS'(WordCount) << OFFSET)-P.PA_BITS'(1))) == 0)
          else $fatal(1, "Invalid or overlapping AHB line request");
        Active <= 1; DataValid <= 0; AddressBeat <= '0; DataBeat <= '0;
        AddressBase <= Base; Count <= WordCount; HWRITE <= Write; HPROT <= Prot; Error <= 0;
      end else if (Active && HREADY) begin
        DataValid <= HTRANS[1];
        if (HTRANS[1]) AddressBeat <= AddressBeat + 1'b1;
        if (DataValid) begin
          if (HRESP) begin
            // Cancel the following address on the first ERROR cycle; retire
            // the failed data phase only when ERROR's high-ready cycle arrives.
            Active <= 0; DataValid <= 0; Done <= 1; Error <= 1;
          end else begin
            if (!HWRITE) ReadLine[int'(DataBeat)] <= HRDATA;
            DataBeat <= DataBeat + 1'b1;
            if (DataBeat == Count-1'b1) begin
              Active <= 0; DataValid <= 0; Done <= 1;
            end
          end
        end
      end
    end
  end
endmodule
