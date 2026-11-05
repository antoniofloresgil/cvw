// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Harness for the cocotb test of chip_top: plain ports for cocotb, and the tristate GPIO pads
// resolved here.  The testbench drives gpio_in onto the pads while gpio_drive is high, and plays
// the SPI flash on the SPI pads.

module chip_tb (
  input  logic       clk, rst_n, uart_rx, gpio_drive, tck, tms, tdi, spi_miso,
  input  logic [7:0] gpio_in,
  output logic       uart_tx, tdo, spi_sck, spi_mosi, spi_cs,
  output logic [7:0] gpio_out
);
  wire       clk_PAD = clk, rst_n_PAD = rst_n, uart_rx_PAD = uart_rx, spi_miso_PAD = spi_miso;
  wire       uart_tx_PAD, spi_sck_PAD, spi_mosi_PAD, spi_cs_PAD;
  wire       tck_PAD = tck, tms_PAD = tms, tdi_PAD = tdi, tdo_PAD;
  wire [7:0] gpio_PAD;

  assign gpio_PAD = gpio_drive ? gpio_in : 8'bz;
  assign gpio_out = gpio_PAD;
  assign uart_tx  = uart_tx_PAD;
  assign tdo      = tdo_PAD;
  assign spi_sck  = spi_sck_PAD;
  assign spi_mosi = spi_mosi_PAD;
  assign spi_cs   = spi_cs_PAD;

  chip_top dut(.clk_PAD, .rst_n_PAD, .uart_rx_PAD, .uart_tx_PAD, .spi_sck_PAD, .spi_mosi_PAD,
    .spi_miso_PAD, .spi_cs_PAD, .gpio_PAD, .tck_PAD, .tms_PAD, .tdi_PAD, .tdo_PAD);
endmodule
