// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// ram1p1rwbe for the open ASIC flow: shapes that IHP SRAM macros (SG13G2 or SG13CMOS5L) implement use the
// macros, and every other shape uses Wally's ram1p1rwbe, which gen_config.py copies under the
// name ram1p1rwbe_generic.  The choice depends on the shape only, not on USE_SRAM, which also
// selects other macros in the caches and branch predictor.
//   1024 x 32                   one RM_IHPSG13_1P_1024x32_c2_bm_bist (ihp.sram)
//   2048 x 32 and multiples     banks of RM_IHPSG13_1P_2048x32_c2_bm_bist (banked.bank[i].sram),
//                               the bank chosen by the top address bits.  The 8192 x 32 macro is
//                               denser but has no write mask, which byte and halfword stores need.
//
// The macro registers the address and data like the generic RAM: dout changes only on a clock
// edge with ce, reads the addressed word, and with A_REN held high a write returns the merged
// word (write-through), as the generic RAM's read of the registered address does.  With banks,
// only the addressed bank is enabled, and the bank whose dout is read is registered with ce too.

module ram1p1rwbe import cvw::*; #(parameter USE_SRAM = 0, DEPTH = 64, WIDTH = 44, PRELOAD_ENABLED = 0) (
  input  logic                     clk,
  input  logic                     ce,
  input  logic [$clog2(DEPTH)-1:0] addr,
  input  logic [WIDTH-1:0]         din,
  input  logic                     we,
  input  logic [(WIDTH-1)/8:0]     bwe,
  output logic [WIDTH-1:0]         dout
);

  localparam BANKDEPTH = 2048;
  localparam NBANKS    = DEPTH / BANKDEPTH;

  logic [WIDTH-1:0] BitWriteMask;
  for (genvar i = 0; i < WIDTH; i++) begin : mask
    assign BitWriteMask[i] = bwe[i/8];
  end

  if (DEPTH == 1024 & WIDTH == 32 & !PRELOAD_ENABLED) begin : ihp
    RM_IHPSG13_1P_1024x32_c2_bm_bist sram(.A_CLK(clk), .A_MEN(ce), .A_WEN(we), .A_REN(1'b1),
      .A_ADDR(addr), .A_DIN(din), .A_BM(BitWriteMask), .A_DLY(1'b1), .A_DOUT(dout),
      .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
      .A_BIST_ADDR('0), .A_BIST_DIN('0), .A_BIST_BM('0));
  end else if (WIDTH == 32 & !PRELOAD_ENABLED & DEPTH >= BANKDEPTH & DEPTH % BANKDEPTH == 0 &
               2**$clog2(NBANKS) == NBANKS) begin : banked
    localparam BANKBITS = $clog2(BANKDEPTH);
    localparam SELBITS  = NBANKS > 1 ? $clog2(NBANKS) : 1;
    logic [SELBITS-1:0] Bank, BankRead;
    logic [WIDTH-1:0]   BankDout [NBANKS];
    assign Bank = NBANKS > 1 ? SELBITS'(addr >> BANKBITS) : '0;
    for (genvar i = 0; i < NBANKS; i++) begin : bank
      RM_IHPSG13_1P_2048x32_c2_bm_bist sram(.A_CLK(clk), .A_MEN(ce & Bank == i), .A_WEN(we), .A_REN(1'b1),
        .A_ADDR(addr[BANKBITS-1:0]), .A_DIN(din), .A_BM(BitWriteMask), .A_DLY(1'b1), .A_DOUT(BankDout[i]),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR('0), .A_BIST_DIN('0), .A_BIST_BM('0));
    end
    always_ff @(posedge clk)
      if (ce) BankRead <= Bank;
    assign dout = BankDout[BankRead];
  end else begin : generic
    ram1p1rwbe_generic #(.USE_SRAM(USE_SRAM), .DEPTH(DEPTH), .WIDTH(WIDTH), .PRELOAD_ENABLED(PRELOAD_ENABLED))
      ram(.clk, .ce, .addr, .din, .we, .bwe, .dout);
  end

endmodule
