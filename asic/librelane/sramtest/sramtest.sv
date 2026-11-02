// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Minimal design to bring one IHP SRAM macro through LibreLane: registered inputs and outputs
// around a 1024x32 single-port macro.
module sramtest (
  input  logic        clk,
  input  logic        ce, we,
  input  logic [3:0]  bwe,
  input  logic [9:0]  addr,
  input  logic [31:0] din,
  output logic [31:0] dout
);
  logic        ceR, weR;
  logic [3:0]  bweR;
  logic [9:0]  addrR;
  logic [31:0] dinR, q;
  logic [31:0] bm;

  always_ff @(posedge clk) begin
    {ceR, weR, bweR, addrR, dinR} <= {ce, we, bwe, addr, din};
    dout <= q;
  end

  for (genvar i = 0; i < 32; i++) assign bm[i] = bweR[i/8];

  RM_IHPSG13_1P_1024x32_c2_bm_bist sram (
    .A_CLK(clk), .A_MEN(ceR), .A_WEN(weR), .A_REN(~weR), .A_ADDR(addrR), .A_DIN(dinR), .A_BM(bm),
    .A_DLY(1'b1), .A_DOUT(q),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR('0), .A_BIST_DIN('0), .A_BIST_BM('0));
endmodule
