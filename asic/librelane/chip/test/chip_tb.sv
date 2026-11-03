// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Harness for the cocotb test of chip_top: plain ports for cocotb, and the tristate GPIO pads
// resolved here.  The testbench drives gpio_in onto the pads while gpio_drive is high.

module chip_tb (
  input  logic       clk, rst_n, uart_rx, gpio_drive,
  input  logic [7:0] gpio_in,
  output logic       uart_tx,
  output logic [7:0] gpio_out
);
  wire       clk_PAD = clk, rst_n_PAD = rst_n, uart_rx_PAD = uart_rx, spi_miso_PAD = 1'b0;
  wire       uart_tx_PAD, spi_sck_PAD, spi_mosi_PAD, spi_cs_PAD;
  wire [7:0] gpio_PAD;

  assign gpio_PAD = gpio_drive ? gpio_in : 8'bz;
  assign gpio_out = gpio_PAD;
  assign uart_tx  = uart_tx_PAD;

  chip_top dut(.clk_PAD, .rst_n_PAD, .uart_rx_PAD, .uart_tx_PAD, .spi_sck_PAD, .spi_mosi_PAD,
    .spi_miso_PAD, .spi_cs_PAD, .gpio_PAD);
endmodule
