// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Harness for the cocotb test of chip_top: plain ports for cocotb, and the tristate GPIO pads
// resolved here.  The testbench drives bit i of gpio_in onto pad i while bit i of gpio_drive is set,
// and plays the SPI flash on the SPI pads.  The GPIO pads have pull-ups, as an I2C bus has.

module chip_tb (
  input  logic       clk, rst_n, uart_rx, tck, tms, tdi, spi_miso,
  input  logic [7:0] gpio_in, gpio_drive,
  output logic       uart_tx, tdo, spi_sck, spi_mosi, spi_cs,
  output logic [7:0] gpio_out
);
  wire       clk_PAD = clk, rst_n_PAD = rst_n, uart_rx_PAD = uart_rx, spi_miso_PAD = spi_miso;
  wire       uart_tx_PAD, spi_sck_PAD, spi_mosi_PAD, spi_cs_PAD;
  wire       tck_PAD = tck, tms_PAD = tms, tdi_PAD = tdi, tdo_PAD;
  tri1 [7:0] gpio_PAD;

  for (genvar i = 0; i < 8; i++) begin : gpiodrv
    assign gpio_PAD[i] = gpio_drive[i] ? gpio_in[i] : 1'bz;
  end
  assign gpio_out = gpio_PAD;
  assign uart_tx  = uart_tx_PAD;
  assign tdo      = tdo_PAD;
  assign spi_sck  = spi_sck_PAD;
  assign spi_mosi = spi_mosi_PAD;
  assign spi_cs   = spi_cs_PAD;

  chip_top dut(.clk_PAD, .rst_n_PAD, .uart_rx_PAD, .uart_tx_PAD, .spi_sck_PAD, .spi_mosi_PAD,
    .spi_miso_PAD, .spi_cs_PAD, .gpio_PAD, .tck_PAD, .tms_PAD, .tdi_PAD, .tdo_PAD);
endmodule
