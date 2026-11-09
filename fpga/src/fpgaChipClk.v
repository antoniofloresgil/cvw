// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The clock of fpgaChip: 18.4375 MHz from the Nexys Video's 100 MHz oscillator, 100 MHz * 59 / 5 / 64 (VCO 1180 MHz), 0.03 % above the
// 18.432 MHz of the chip's test board, so the chip's images and bootloader run unchanged.  Plain Verilog,
// read by Yosys' own frontend: slang cannot take the real-valued parameters of a primitive that is a blackbox.
module fpgaChipClk (
  input  wire clk100_in,
  output wire clk,
  output wire locked
);
  wire clk100, clkfb, clkpll;
  BUFG clk100buf (.I(clk100_in), .O(clk100));
  PLLE2_ADV #(
    .CLKFBOUT_MULT  (59),
    .CLKIN1_PERIOD  (10.0),
    .CLKOUT0_DIVIDE (64),
    .CLKOUT0_PHASE  (0.0),
    .DIVCLK_DIVIDE  (5),
    .REF_JITTER1    (0.01),
    .STARTUP_WAIT   ("FALSE")
  ) pll (
    .CLKFBIN (clkfb), .CLKIN1 (clk100), .PWRDWN (1'b0), .RST (1'b0),
    .CLKFBOUT (clkfb), .CLKOUT0 (clkpll), .LOCKED (locked)
  );
  BUFG clkbuf (.I(clkpll), .O(clk));
endmodule
