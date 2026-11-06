// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Chip top of asic_soc_rv32imc: Wally's SoC inside an IHP pad ring, after the layout of IHP's
// LibreLane template (github.com/IHP-GmbH/ihp-sg13-librelane-template, src/chip_top.sv).  The pads
// are those of SG13G2, or of SG13CMOS5L with SG13CMOS5L defined.
// 20 signal pads (clock, reset, UART, SPI, 8 GPIOs, JTAG) and 8 power pads, two of each on opposite
// sides (gen_config.py places them), so that no single bond wire powers the core or the IOs.  The bootloader in the
// BOOTROM (chip/boot.S) copies a program from an SPI flash on the SPI pads, or loads it over the UART,
// as straps on the GPIOs at reset choose.
// The JTAG port reaches the Debug Module and the instruction trace (docs/debug.md, docs/trace.md).

import cvw::*;
`include "config.vh"
`include "parameter-defs.vh"

module chip_top (
`ifdef USE_POWER_PINS
  inout wire IOVDD, IOVSS, VDD, VSS,
`endif
  inout wire       clk_PAD,
  inout wire       rst_n_PAD,      // active low
  inout wire       uart_rx_PAD, uart_tx_PAD,
  inout wire       spi_sck_PAD, spi_mosi_PAD, spi_miso_PAD, spi_cs_PAD,
  inout wire [7:0] gpio_PAD,
  inout wire       tck_PAD, tms_PAD, tdi_PAD, tdo_PAD
);

  logic        clk, rst_n, UARTSin, UARTSout, SPIIn, SPIOut, SPICLK;
  logic [3:0]  SPICS;
  logic [31:0] GPIOIN, GPIOOUT, GPIOEN;
  logic        TCK, TMS, TDI, TDO;

`ifdef SG13CMOS5L
  `define PAD(cell) sg13cmos5l_``cell
`else
  `define PAD(cell) sg13g2_``cell
`endif
`ifdef USE_POWER_PINS
  `define PAD_POWER .iovdd(IOVDD), .iovss(IOVSS), .vdd(VDD), .vss(VSS),
  `define PAD_POWER_ONLY .iovdd(IOVDD), .iovss(IOVSS), .vdd(VDD), .vss(VSS)
`else
  `define PAD_POWER
  `define PAD_POWER_ONLY
`endif

  (* keep *) `PAD(IOPadIOVdd) iovdd_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadIOVss) iovss_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadVdd)   vdd_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadVss)   vss_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadIOVdd) iovdd2_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadIOVss) iovss2_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadVdd)   vdd2_pad(`PAD_POWER_ONLY);
  (* keep *) `PAD(IOPadVss)   vss2_pad(`PAD_POWER_ONLY);

  `PAD(IOPadIn)      clk_pad(`PAD_POWER .p2c(clk), .pad(clk_PAD));
  `PAD(IOPadIn)      rst_n_pad(`PAD_POWER .p2c(rst_n), .pad(rst_n_PAD));
  `PAD(IOPadIn)      uart_rx_pad(`PAD_POWER .p2c(UARTSin), .pad(uart_rx_PAD));
  `PAD(IOPadOut30mA) uart_tx_pad(`PAD_POWER .c2p(UARTSout), .pad(uart_tx_PAD));
  `PAD(IOPadOut30mA) spi_sck_pad(`PAD_POWER .c2p(SPICLK), .pad(spi_sck_PAD));
  `PAD(IOPadOut30mA) spi_mosi_pad(`PAD_POWER .c2p(SPIOut), .pad(spi_mosi_PAD));
  `PAD(IOPadIn)      spi_miso_pad(`PAD_POWER .p2c(SPIIn), .pad(spi_miso_PAD));
  `PAD(IOPadOut30mA) spi_cs_pad(`PAD_POWER .c2p(SPICS[0]), .pad(spi_cs_PAD));

  `PAD(IOPadIn)      tck_pad(`PAD_POWER .p2c(TCK), .pad(tck_PAD));
  `PAD(IOPadIn)      tms_pad(`PAD_POWER .p2c(TMS), .pad(tms_PAD));
  `PAD(IOPadIn)      tdi_pad(`PAD_POWER .p2c(TDI), .pad(tdi_PAD));
  `PAD(IOPadOut30mA) tdo_pad(`PAD_POWER .c2p(TDO), .pad(tdo_PAD));

  for (genvar i = 0; i < 8; i++) begin : gpio
    `PAD(IOPadInOut30mA) gpio_pad(`PAD_POWER .c2p(GPIOOUT[i]), .c2p_en(GPIOEN[i]), .p2c(GPIOIN[i]), .pad(gpio_PAD[i]));
  end
  assign GPIOIN[31:8] = '0;

  // No external memory, debug stall or SD card
  wallypipelinedsoc #(.P(P)) soc(.clk, .reset_ext(~rst_n), .reset(),
    .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(), .ExternalStall(1'b0),
    .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(), .HBURST(), .HPROT(),
    .HTRANS(), .HMASTLOCK(), .HREADY(),
    .GPIOIN, .GPIOOUT, .GPIOEN, .UARTSin, .UARTSout, .SPIIn, .SPIOut, .SPICS, .SPICLK,
    .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO(), .TCK, .TMS, .TDI, .TDO);
endmodule
