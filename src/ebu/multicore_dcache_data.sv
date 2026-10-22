// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Data arrays only: no coherence permissions, tag matching or bus sequencing.
// Read ports are combinational. Writes commit at the rising edge, with line
// installation followed by masked global store, then per-hart local stores.
module multicore_dcache_data import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned WORDS = 8192/(P.AHBW/8),
  parameter int unsigned LINE_WORDS = 1
)(
  input logic HCLK, HRESETn,
  input logic [NCORES-1:0][$clog2(WORDS)-1:0] LocalWordIndex,
  output logic [NCORES-1:0][P.AHBW-1:0] LocalReadData,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] WordReadOwner, LineReadOwner,
  input logic [$clog2(WORDS)-1:0] WordReadIndex,
  input logic [$clog2(WORDS/LINE_WORDS)-1:0] LineReadIndex,
  output logic [P.AHBW-1:0] WordReadData,
  output logic [P.AHBW-1:0] LineReadData[LINE_WORDS],
  input logic Install, Store,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] WriteOwner,
  input logic [$clog2(WORDS/LINE_WORDS)-1:0] InstallIndex,
  input logic [P.AHBW-1:0] InstallLine[LINE_WORDS],
  input logic [$clog2(WORDS)-1:0] StoreIndex,
  input logic [P.AHBW-1:0] StoreData,
  input logic [P.XLEN/8-1:0] StoreStrb,
  input logic [NCORES-1:0] LocalStore,
  input logic [NCORES-1:0][P.AHBW-1:0] LocalStoreData,
  input logic [NCORES-1:0][P.XLEN/8-1:0] LocalStoreStrb
);
  logic [P.AHBW-1:0] Lines[NCORES][WORDS];
  for (genvar h = 0; h < NCORES; h++) begin : probes
    assign LocalReadData[h] = Lines[h][LocalWordIndex[h]];
  end
  assign WordReadData = Lines[WordReadOwner][WordReadIndex];
  for (genvar w = 0; w < LINE_WORDS; w++) begin : lineport
    assign LineReadData[w] = Lines[LineReadOwner][int'(LineReadIndex)*LINE_WORDS+w];
  end
  // There is no data reset. The controller owns invalidation/visibility.
  always_ff @(posedge HCLK) begin
    if (HRESETn) begin
      if (Install)
        for (int w = 0; w < LINE_WORDS; w++)
          Lines[WriteOwner][int'(InstallIndex)*LINE_WORDS+w] <= InstallLine[w];
      if (Store)
        for (int b = 0; b < P.XLEN/8; b++)
          if (StoreStrb[b]) Lines[WriteOwner][StoreIndex][8*b +: 8] <= StoreData[8*b +: 8];
      for (int h = 0; h < NCORES; h++)
        if (LocalStore[h])
          for (int b = 0; b < P.XLEN/8; b++)
            if (LocalStoreStrb[h][b]) Lines[h][LocalWordIndex[h]][8*b +: 8] <= LocalStoreData[h][8*b +: 8];
    end
  end
endmodule
