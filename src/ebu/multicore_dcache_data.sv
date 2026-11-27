// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Data arrays only: no coherence permissions, tag matching or bus sequencing.
// Each hart's data is LINE_WORDS one-word banks of true dual-port block RAM
// (ram2p2rwbe), so a whole line is read or written in one access. Reads are
// registered: callers give the address of the NEXT cycle (the address their
// request register is about to hold) and get its words one cycle later, when
// the old combinational arrays answered.
//  - Port A belongs to the hart: its local read, and its local store, which
//    commits while its request register holds the address (so the next address
//    is the store's own).
//  - Port B belongs to the controller: it reads every hart's line at the
//    controller's address (owner, snooper and supplier select afterwards) and
//    writes the owner's line: installation, then the masked global store.
// LocalReadValid is low when the controller wrote that hart's line in the
// cycle the hart's read was issued: block RAM leaves such a read undefined.
module multicore_dcache_data import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2,
  parameter int unsigned WORDS = 8192/(P.AHBW/8),
  parameter int unsigned LINE_WORDS = 1
)(
  input logic HCLK, HRESETn,
  input logic [NCORES-1:0][$clog2(WORDS)-1:0] LocalWordIndexNext,
  output logic [NCORES-1:0][P.AHBW-1:0] LocalReadData,
  output logic [NCORES-1:0] LocalReadValid,
  input logic [NCORES-1:0] LocalStore,
  input logic [NCORES-1:0][P.AHBW-1:0] LocalStoreData,
  input logic [NCORES-1:0][P.XLEN/8-1:0] LocalStoreStrb,
  input logic [$clog2(WORDS)-1:0] WordIndexNext,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] WordReadOwner, LineReadOwner,
  output logic [P.AHBW-1:0] WordReadData,
  output logic [P.AHBW-1:0] LineReadData[LINE_WORDS],
  input logic Install, Store,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] WriteOwner,
  input logic [P.AHBW-1:0] InstallLine[LINE_WORDS],
  input logic [P.AHBW-1:0] StoreData,
  input logic [P.XLEN/8-1:0] StoreStrb
);
  localparam N_LINES = WORDS / LINE_WORDS;
  localparam INDEX = $clog2(N_LINES);
  localparam LINE_BITS = $clog2(LINE_WORDS);
  localparam WORD_INDEX = $clog2(WORDS);
  localparam BYTES = P.AHBW/8;
  localparam HART_BITS = NCORES > 1 ? $clog2(NCORES) : 1;

  function automatic int unsigned word_of(input logic [WORD_INDEX-1:0] index);
    return int'(index) % LINE_WORDS;
  endfunction
  function automatic logic [INDEX-1:0] line_of(input logic [WORD_INDEX-1:0] index);
    return INDEX'(index >> LINE_BITS);
  endfunction

  logic [P.AHBW-1:0] ARead[NCORES][LINE_WORDS], BRead[NCORES][LINE_WORDS];
  logic [NCORES-1:0][WORD_INDEX-1:0] LocalWordIndex;   // the addresses of the reads now on the outputs
  logic [WORD_INDEX-1:0] WordIndex;
  logic [NCORES-1:0] BWrite, Collision;

  for (genvar h = 0; h < NCORES; h++) begin : harts
    assign BWrite[h] = (Install || Store) && WriteOwner == HART_BITS'(h);
    for (genvar w = 0; w < LINE_WORDS; w++) begin : words
      logic StoreHere;
      logic [P.AHBW-1:0] BData;
      logic [BYTES-1:0] BStrb;
      assign StoreHere = Store && word_of(WordIndexNext) == w;
      // Installation writes the whole word; the global store's bytes replace the installed ones.
      for (genvar b = 0; b < BYTES; b++) begin : merge
        assign BData[8*b +: 8] = StoreHere && StoreStrb[b] ? StoreData[8*b +: 8] : InstallLine[w][8*b +: 8];
        assign BStrb[b] = Install || (StoreHere && StoreStrb[b]);
      end
      ram2p2rwbe #(.DEPTH(N_LINES), .WIDTH(P.AHBW)) ram(.clk(HCLK),
        .ce1(1'b1), .we1(HRESETn && LocalStore[h] && word_of(LocalWordIndexNext[h]) == w),
        .a1(line_of(LocalWordIndexNext[h])), .bwe1(LocalStoreStrb[h]), .wd1(LocalStoreData[h]), .rd1(ARead[h][w]),
        .ce2(1'b1), .we2(HRESETn && BWrite[h] && (Install || StoreHere)),
        .a2(line_of(WordIndexNext)), .bwe2(BStrb), .wd2(BData), .rd2(BRead[h][w]));
    end
    assign LocalReadData[h] = ARead[h][word_of(LocalWordIndex[h])];
    assign LocalReadValid[h] = !Collision[h];
  end

  always_ff @(posedge HCLK) begin
    LocalWordIndex <= LocalWordIndexNext;
    WordIndex <= WordIndexNext;
    for (int h = 0; h < NCORES; h++)
      Collision[h] <= BWrite[h] && line_of(WordIndexNext) == line_of(LocalWordIndexNext[h]);
  end

  assign WordReadData = BRead[WordReadOwner][word_of(WordIndex)];
  for (genvar w = 0; w < LINE_WORDS; w++) begin : lineport
    assign LineReadData[w] = BRead[LineReadOwner][w];
  end

  // synopsys translate_off
  // The old flat view of the arrays, for the passive observers of tests/multicore.
  wire [P.AHBW-1:0] Lines[NCORES][WORDS];
  for (genvar h = 0; h < NCORES; h++) begin : view
    for (genvar i = 0; i < WORDS; i++) begin : word
      assign Lines[h][i] = harts[h].words[i % LINE_WORDS].ram.RAM[i / LINE_WORDS];
    end
  end
  // A local store commits only while its request register holds its address.
  always_ff @(posedge HCLK)
    if (HRESETn)
      for (int h = 0; h < NCORES; h++)
        assert (!LocalStore[h] || LocalWordIndexNext[h] == LocalWordIndex[h])
          else $fatal(1, "Local store while its hart's next address changes");
  // synopsys translate_on
endmodule
