// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Simulation contract for Wally's buffered SINGLE hart port, not a generic AHB VIP.
// See docs/engineering/interfaces/core-bus.md. No synthesis state or data-path changes.
module corebus_contract import cvw::*; #(parameter cvw_t P, parameter int NCORES = 2) (
  input logic HCLK, HRESETn,
  input logic [NCORES-1:0][1:0] CoreHTRANS, CoreHATOMIC,
  input logic [NCORES-1:0][2:0] CoreHBURST,
  input logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK, CoreHREADY, CoreHRESP, CoreSCFail,
  input logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA, CoreHRDATA,
  input logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB
);
  // synopsys translate_off
  for (genvar h = 0; h < NCORES; h++) begin : harts
    logic Outstanding, Write, DataSeen, ErrorWait, PreviousSCFail;
    logic [1:0] Op;
    logic [P.AHBW-1:0] Data, ErrorData;
    logic [P.XLEN/8-1:0] Strb;
    always_ff @(posedge HCLK) begin
      if (!HRESETn) begin
        Outstanding <= 0; Write <= 0; DataSeen <= 0; ErrorWait <= 0;
        PreviousSCFail <= 0; Op <= 0; Data <= '0; Strb <= '0; ErrorData <= '0;
      end else begin
        assert (!CoreHRESP[h] || Outstanding)
          else $fatal(1, "corebus contract: response without outstanding request, hart %0d", h);
        if (ErrorWait)
          assert (CoreHRESP[h] && CoreHREADY[h] && CoreHRDATA[h] === ErrorData)
            else $fatal(1, "corebus contract: missing final ERROR phase, hart %0d", h);
        if (CoreHRESP[h] && CoreHREADY[h])
          assert (ErrorWait)
            else $fatal(1, "corebus contract: missing first ERROR phase, hart %0d", h);
        ErrorWait <= CoreHRESP[h] && !CoreHREADY[h];
        ErrorData <= CoreHRDATA[h];
        // The SC result can become visible in the first ERROR phase. Only the
        // completing SC may replace it; an intervening IFU/ordinary reply cannot.
        if (!(Outstanding && Op == 2'b10 && (CoreHREADY[h] || CoreHRESP[h])))
          assert (CoreSCFail[h] == PreviousSCFail)
            else $fatal(1, "corebus contract: SC result changed outside SC completion, hart %0d", h);
        PreviousSCFail <= CoreSCFail[h];
        // Case equality checks stability without requiring unused lanes or
        // failed-read data to have defined values in four-state simulation.
        if (Outstanding && Write) begin
          if (DataSeen) begin
            assert (CoreHWDATA[h] === Data)
              else $fatal(1, "corebus contract: write data changed before reply, hart %0d", h);
            assert (CoreHWSTRB[h] === Strb)
              else $fatal(1, "corebus contract: write strobes changed before reply, hart %0d", h);
          end
          Data <= CoreHWDATA[h]; Strb <= CoreHWSTRB[h]; DataSeen <= 1;
        end
        if (CoreHREADY[h]) begin
          // A reply may retire the previous request and accept its successor
          // at this same edge. Do not compare successor metadata with old data.
          Outstanding <= CoreHTRANS[h][1];
          DataSeen <= 0;
          if (CoreHTRANS[h][1]) begin
            Write <= CoreHWRITE[h]; Op <= CoreHATOMIC[h];
            assert (CoreHTRANS[h] == 2'b10 && CoreHBURST[h] == 0 && !CoreHMASTLOCK[h])
              else $fatal(1, "corebus contract: unsupported address phase, hart %0d", h);
            assert ((CoreHATOMIC[h] != 2'b01 || !CoreHWRITE[h]) &&
                    (CoreHATOMIC[h] != 2'b10 || CoreHWRITE[h]))
              else $fatal(1, "corebus contract: LR/SC direction mismatch, hart %0d", h);
          end
        end
      end
    end
  end
  // synopsys translate_on
endmodule
