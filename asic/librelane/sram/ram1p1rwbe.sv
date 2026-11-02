// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// ram1p1rwbe for the open ASIC flow: shapes that an IHP SG13G2 SRAM macro implements use the
// macro, and every other shape uses Wally's ram1p1rwbe, which gen_config.py copies under the
// name ram1p1rwbe_generic.  The choice depends on the shape only, not on USE_SRAM, which also
// selects other macros in the caches and branch predictor.
//
// The macro registers the address and data like the generic RAM: dout changes only on a clock
// edge with ce, reads the addressed word, and with A_REN held high a write returns the merged
// word (write-through), as the generic RAM's read of the registered address does.

module ram1p1rwbe import cvw::*; #(parameter USE_SRAM = 0, DEPTH = 64, WIDTH = 44, PRELOAD_ENABLED = 0) (
  input  logic                     clk,
  input  logic                     ce,
  input  logic [$clog2(DEPTH)-1:0] addr,
  input  logic [WIDTH-1:0]         din,
  input  logic                     we,
  input  logic [(WIDTH-1)/8:0]     bwe,
  output logic [WIDTH-1:0]         dout
);

  if (DEPTH == 1024 & WIDTH == 32 & !PRELOAD_ENABLED) begin : ihp
    logic [WIDTH-1:0] BitWriteMask;
    for (genvar i = 0; i < WIDTH; i++) begin : mask
      assign BitWriteMask[i] = bwe[i/8];
    end
    RM_IHPSG13_1P_1024x32_c2_bm_bist sram(.A_CLK(clk), .A_MEN(ce), .A_WEN(we), .A_REN(1'b1),
      .A_ADDR(addr), .A_DIN(din), .A_BM(BitWriteMask), .A_DLY(1'b1), .A_DOUT(dout),
      .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
      .A_BIST_ADDR('0), .A_BIST_DIN('0), .A_BIST_BM('0));
  end else begin : generic
    ram1p1rwbe_generic #(.USE_SRAM(USE_SRAM), .DEPTH(DEPTH), .WIDTH(WIDTH), .PRELOAD_ENABLED(PRELOAD_ENABLED))
      ram(.clk, .ce, .addr, .din, .we, .bwe, .dout);
  end

endmodule
