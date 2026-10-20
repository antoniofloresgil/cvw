// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Round-robin AHB-Lite port arbitration for autonomous masters. Retain the
// grant across SEQ beats and stalls, until the final data phase drains.
module ahbburstmux import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned MASTERS = 2
)(
  input logic HCLK, HRESETn,
  input logic [MASTERS-1:0][P.PA_BITS-1:0] MAddr,
  input logic [MASTERS-1:0][P.AHBW-1:0] MWData,
  input logic [MASTERS-1:0][P.XLEN/8-1:0] MStrb,
  input logic [MASTERS-1:0] MWrite,
  input logic [MASTERS-1:0][2:0] MSize, MBurst,
  input logic [MASTERS-1:0][3:0] MProt,
  input logic [MASTERS-1:0][1:0] MTrans,
  output logic [MASTERS-1:0][P.AHBW-1:0] MRData,
  output logic [MASTERS-1:0] MReady, MResp,
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
  localparam OB = MASTERS > 1 ? $clog2(MASTERS) : 1;
  logic Granted, DataValid, Found;
  logic [OB-1:0] Owner, DataOwner, First, Selected;
  int Candidate;
  always_comb begin
    Found = 0; Selected = First; Candidate = 0;
    for (int offset = 0; offset < MASTERS; offset++) begin
      Candidate = int'(First)+offset;
      if (Candidate >= MASTERS) Candidate -= MASTERS;
      if (!Found && MTrans[Candidate][1]) begin
        Found = 1; Selected = OB'(Candidate);
      end
    end
    HADDR = MAddr[Owner]; HWRITE = MWrite[Owner]; HSIZE = MSize[Owner];
    HBURST = MBurst[Owner]; HPROT = MProt[Owner];
    HTRANS = HRESETn && Granted ? MTrans[Owner] : 2'b00;
    HWDATA = MWData[DataOwner]; HWSTRB = MStrb[DataOwner];
    MRData = '0; MReady = '0; MResp = '0;
    if (HRESETn && Granted) MReady[Owner] = HREADY;
    if (DataValid) begin
      MRData[DataOwner] = HRDATA;
      MResp[DataOwner] = HRESP;
    end
  end
  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      Granted <= 0; DataValid <= 0; Owner <= '0; DataOwner <= '0; First <= '0;
    end else begin
      if (!Granted && Found) begin
        Granted <= 1; Owner <= Selected;
      end
      if (HREADY) begin
        DataValid <= HTRANS[1];
        if (HTRANS[1]) DataOwner <= Owner;
        if (Granted && MTrans[Owner] == 0) begin
          Granted <= 0;
          First <= int'(Owner) == MASTERS-1 ? '0 : Owner+1'b1;
        end
      end
    end
  end
endmodule
