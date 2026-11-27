// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// One hart's cache tags: one write port, READS combinational read ports.
// Written so that Vivado maps it to distributed RAM (LUTRAM), one copy per
// read port, instead of flip-flops and wide multiplexers: with 56-bit
// physical addresses a tag is over 40 bits. The reads see the contents before
// the clock edge of a write, as the flip-flop arrays they replace did. There
// is no reset: the callers' state and valid bits say which tags mean anything.
module multicore_tag_ram #(
  parameter int unsigned DEPTH = 256,
  parameter int unsigned WIDTH = 20,
  parameter int unsigned READS = 2
)(
  input  logic HCLK,
  input  logic we,
  input  logic [$clog2(DEPTH)-1:0] wa,
  input  logic [WIDTH-1:0] wd,
  input  logic [READS-1:0][$clog2(DEPTH)-1:0] ra,
  output logic [READS-1:0][WIDTH-1:0] rd
);
  (* ram_style = "distributed" *) logic [WIDTH-1:0] Mem[DEPTH];
  always_ff @(posedge HCLK)
    if (we) Mem[wa] <= wd;
  for (genvar r = 0; r < READS; r++) begin : reads
    assign rd[r] = Mem[ra[r]];
  end
endmodule
