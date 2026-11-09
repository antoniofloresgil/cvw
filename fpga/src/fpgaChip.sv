// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The chip asic_soc_rv32imac on the Nexys Video, for the open-source flow (fpga/generator, nexysvideochip): the
// SoC of asic/librelane/chip/chip_top.sv without the pad ring, with the pins the board has.
//   * a PLL makes Wally's clock, 18.4375 MHz, from the board's 100 MHz oscillator: 0.03 % above the 18.432 MHz of the
//     chip's test board, so the bootloader's default divisor 10 (all of SW[4:0] down) gives 115200 baud and the images of
//     the chip, Zephyr's and FreeRTOS's, run unchanged.
//   * CPU RESET (active low) resets the SoC; the PLL must have locked.
//   * SW[7:0] are GPIO[7:0] as inputs and LD[7:0] show GPIO[7:0] as outputs, so a pin that Zephyr drives reads back
//     what it drives, as a pad of the chip does.  The bootloader reads its straps from the switches at reset
//     (GPIO[5] 1: load over the UART; GPIO[4:0]: UART divisor).
//   * the USB-UART bridge is the SoC's UART.  No SPI flash, JTAG or SD card: their inputs are tied to 0.
// The RAM and the BOOTROM are block RAM (src/generic/mem; the ASIC's SRAM macros replace them only in the ASIC flow).

`include "cvw.sv"
`include "config.vh"

module fpgaChip import cvw::*; (
  input  logic       default_100mhz_clk,
  input  logic       resetn,
  input  logic [7:0] SW,
  output logic [7:0] LD,
  input  logic       UARTSin,
  output logic       UARTSout
);

`include "parameter-defs.vh"

  // 24 MHz from the PLL (fpgaChipClk.v, plain Verilog)
  logic clk, locked;
  fpgaChipClk clock(.clk100_in(default_100mhz_clk), .clk, .locked);

  // Reset: released four clocks after the button is up and the PLL has locked
  logic [3:0] rstsr;
  logic       rst_n, rst_n_async;
  assign rst_n_async = resetn & locked;
  always_ff @(posedge clk or negedge rst_n_async)
    if (!rst_n_async) rstsr <= '0;
    else              rstsr <= {rstsr[2:0], 1'b1};
  assign rst_n = rstsr[3];

  logic        SPIOut, SPICLK;
  logic [3:0]  SPICS;
  logic [31:0] GPIOIN, GPIOOUT, GPIOEN;

  // a pin that is an output reads what it drives; an input reads its switch
  always_comb begin
    GPIOIN = '0;
    for (int i = 0; i < 8; i++) GPIOIN[i] = GPIOEN[i] ? GPIOOUT[i] : SW[i];
  end
  assign LD = GPIOOUT[7:0] & GPIOEN[7:0];

  // No external memory, debug stall or SD card
  wallypipelinedsoc #(.P(P)) soc(.clk, .reset_ext(~rst_n), .reset(),
    .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(), .ExternalStall(1'b0),
    .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(), .HBURST(), .HPROT(),
    .HTRANS(), .HMASTLOCK(), .HREADY(),
    .GPIOIN, .GPIOOUT, .GPIOEN, .UARTSin, .UARTSout, .SPIIn(1'b0), .SPIOut, .SPICS, .SPICLK,
    .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO(), .TCK(1'b0), .TMS(1'b0), .TDI(1'b0), .TDO());
endmodule
