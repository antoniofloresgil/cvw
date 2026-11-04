///////////////////////////////////////////
// openocd_tb.sv
//
// Purpose: wallypipelinedsoc with its JTAG pins driven by OpenOCD through remote_bitbang
//          (jtag_rbb.cpp): run it, then connect OpenOCD with openocd.cfg (make openocd does
//          both, with the checks of openocd_test.tcl).  Each command of OpenOCD advances the
//          simulation by two clock cycles, so TCK runs at a quarter of the system clock or less.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module openocd_tb;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"

  import "DPI-C" function int jtag_rbb_tick(input int port, output bit tck, output bit tms,
                                            output bit tdi, input bit tdo);

  logic        clk, reset_ext, reset;
  bit          TCK, TMS, TDI;
  logic        TDO;
  logic [31:0] GPIOOUT, GPIOEN;
  logic        HSELEXT, HCLK, HRESETn, HWRITE, HMASTLOCK, HREADY;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.AHBW-1:0]    HWDATA;
  logic [P.XLEN/8-1:0]  HWSTRB;
  logic [2:0]  HSIZE, HBURST;
  logic [3:0]  HPROT, SPICS, SDCCS, PWMGPIO;
  logic [1:0]  HTRANS;
  logic        UARTSout, SPIOut, SPICLK, SDCCmd, SDCCLK;
  int          Port, Cycle;

  wallypipelinedsoc #(P) dut(.clk, .reset_ext, .reset, .ExternalStall(1'b0),
    .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT,
    .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT,
    .HTRANS, .HMASTLOCK, .HREADY, .TIMECLK(1'b0), .GPIOIN('0), .GPIOOUT, .GPIOEN,
    .UARTSin(1'b1), .UARTSout, .SPIIn(1'b0), .SPIOut, .SPICS, .SPICLK, .SDCIn(1'b1), .SDCCmd,
    .SDCCS, .SDCCLK, .PWMGPIO, .TCK, .TMS, .TDI, .TDO);

  always begin
    clk = 1'b1; #5; clk = 1'b0; #5;
  end

  initial begin
    if (!$value$plusargs("RBB_PORT=%d", Port)) Port = 9823;
    TCK = 0; TMS = 1; TDI = 0;
    reset_ext = 1'b1;
    #100 reset_ext = 1'b0;
  end

  always @(posedge clk) begin
    Cycle <= Cycle + 1;
    if (!reset_ext && Cycle[0])
      if (jtag_rbb_tick(Port, TCK, TMS, TDI, TDO) != 0) begin
        $display("OpenOCD disconnected; GPIOOUT = 0x%08h", GPIOOUT);
        $finish;
      end
  end
endmodule
