// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Instruction storage of every hart. The caller owns refill sequencing.
// Reset/invalidation clears validity only; tags/data are deliberately unreset.
// Each hart's words are one block RAM with a read port and a write port
// (ram2p1r1wbe). The read is registered: ProbeAddrNext is the address the
// hart's request register is about to hold, ProbeAddr the one it holds, whose
// word ProbeData returns. Tags and valid bits stay in flip-flops, read
// combinationally as before. A probe whose word was refilled in the cycle its
// read was issued misses for that cycle (block RAM leaves the read undefined).
module multicore_icache_bank import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned WORDS = 8192/(P.AHBW/8),
  parameter int unsigned LINE_WORDS = 1
)(
  input logic HCLK, HRESETn,
  input logic [NCORES-1:0][P.PA_BITS-1:0] ProbeAddr, ProbeAddrNext,
  output logic [NCORES-1:0] ProbeHit,
  output logic [NCORES-1:0][P.AHBW-1:0] ProbeData,
  input logic [NCORES-1:0] LocalStoreCommit,
  input logic [NCORES-1:0][P.PA_BITS-1:0] LocalStoreAddr,
  input logic GlobalWrite,
  input logic [P.PA_BITS-1:0] GlobalAddr,
  input logic FillInvalidate, FillBeat, FillLast,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] FillOwner,
  input logic [P.PA_BITS-1:0] FillAddr, FillWordAddr,
  input logic [P.AHBW-1:0] FillData
);
  localparam OFFSET = $clog2(P.AHBW/8);
  localparam LINE_OFFSET = OFFSET + $clog2(LINE_WORDS);
  localparam N_LINES = WORDS / LINE_WORDS;
  localparam INDEX = $clog2(N_LINES);
  localparam WORD_INDEX = $clog2(WORDS);
  localparam TAG = P.PA_BITS - LINE_OFFSET - INDEX;
  localparam HART_BITS = NCORES > 1 ? $clog2(NCORES) : 1;
  logic [NCORES-1:0][N_LINES-1:0] Valid;
  logic [TAG-1:0] Tags[NCORES][N_LINES];
  logic [NCORES-1:0] WriteWord, Collision;

  for (genvar h = 0; h < NCORES; h++) begin : probes
    assign WriteWord[h] = FillBeat && !GlobalWrite && FillOwner == HART_BITS'(h);
    ram2p1r1wbe #(.DEPTH(WORDS), .WIDTH(P.AHBW)) ram(.clk(HCLK),
      .ce1(1'b1), .ra1(ProbeAddrNext[h][OFFSET +: WORD_INDEX]), .rd1(ProbeData[h]),
      .ce2(1'b1), .we2(HRESETn && WriteWord[h]), .wa2(FillWordAddr[OFFSET +: WORD_INDEX]), .bwe2('1), .wd2(FillData));
    assign ProbeHit[h] = multicore_cacheable(P, 64'(ProbeAddr[h])) && !Collision[h] &&
      Valid[h][ProbeAddr[h][LINE_OFFSET +: INDEX]] &&
      Tags[h][ProbeAddr[h][LINE_OFFSET +: INDEX]] == ProbeAddr[h][P.PA_BITS-1:LINE_OFFSET+INDEX];
  end
  always_ff @(posedge HCLK)
    for (int h = 0; h < NCORES; h++)
      Collision[h] <= WriteWord[h] &&
        FillWordAddr[OFFSET +: WORD_INDEX] == ProbeAddrNext[h][OFFSET +: WORD_INDEX];

  always_ff @(posedge HCLK) begin
    if (!HRESETn) Valid <= '0;
    else begin
      // Local invalidations precede refill updates. An unrelated refill must
      // survive invalidation of its victim's old tag on the same edge.
      for (int writer = 0; writer < NCORES; writer++)
        if (LocalStoreCommit[writer])
          for (int h = 0; h < NCORES; h++)
            if (Tags[h][LocalStoreAddr[writer][LINE_OFFSET +: INDEX]] == LocalStoreAddr[writer][P.PA_BITS-1:LINE_OFFSET+INDEX])
              Valid[h][LocalStoreAddr[writer][LINE_OFFSET +: INDEX]] <= 1'b0;
      if (FillInvalidate) Valid[FillOwner][FillAddr[LINE_OFFSET +: INDEX]] <= 1'b0;
      if (GlobalWrite) begin
        for (int h = 0; h < NCORES; h++)
          if (Tags[h][GlobalAddr[LINE_OFFSET +: INDEX]] == GlobalAddr[P.PA_BITS-1:LINE_OFFSET+INDEX])
            Valid[h][GlobalAddr[LINE_OFFSET +: INDEX]] <= 1'b0;
      end else if (FillBeat) begin
        Valid[FillOwner][FillAddr[LINE_OFFSET +: INDEX]] <= FillLast;
        Tags[FillOwner][FillAddr[LINE_OFFSET +: INDEX]] <= FillAddr[P.PA_BITS-1:LINE_OFFSET+INDEX];
      end
    end
  end
  initial begin
    assert (LINE_WORDS >= 1 && (LINE_WORDS & (LINE_WORDS-1)) == 0 &&
      WORDS >= 2*LINE_WORDS && (WORDS & (WORDS-1)) == 0 && TAG > 0)
      else $fatal(1, "Private I-cache words must be a power of two >= 2 and fit PA_BITS");
  end
endmodule
