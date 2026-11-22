///////////////////////////////////////////
// gsimtop.sv
//
// Purpose: Top level of Wally for gsim: the SoC with its external AHB port, UART and GPIO as ports, so that
//          Yosys keeps the whole design when it writes FIRRTL and a C++ harness can drive it.
//
// A component of the Wally configurable RISC-V project.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

`include "config.vh"

module gsimtop import cvw::*; #(`CVW_MULTICORE_PARAMS(AHBW)) (
  input  logic                clock,
  input  logic                reset,
  // external AHB port (EXT_MEM), served by the harness
  input  logic [AHBW-1:0]     HRDATAEXT,
  input  logic                HREADYEXT, HRESPEXT,
  output logic                HSELEXT,
  output logic [PA_BITS-1:0]   HADDR,
  output logic [AHBW-1:0]     HWDATA,
  output logic [XLEN/8-1:0]   HWSTRB,
  output logic                HWRITE,
  output logic [2:0]          HSIZE,
  output logic [2:0]          HBURST,
  output logic [3:0]          HPROT,
  output logic [1:0]          HTRANS,
  output logic                HMASTLOCK,
  output logic                HREADY,
  // peripherals
  input  logic [31:0]         GPIOIN,
  output logic [31:0]         GPIOOUT, GPIOEN,
  input  logic                UARTSin,
  output logic                UARTSout,
  input  logic                SPIIn, SDCIn,
  output logic                SPIOut, SPICLK, SDCCmd, SDCCLK,
  output logic [3:0]          SPICS, SDCCS, PWMGPIO,
  // Memory stage, for the harness to see the store to tohost the way testbench.sv does (it may stay in the D$)
  output logic [XLEN-1:0]     IEUAdrM, WriteDataM, PCM,
  output logic [31:0]         InstrM,
  output logic                InstrValidM, StallM, FlushM
);

`include "parameter-defs.vh"

  logic HCLK, HRESETn, resetint;

  wallypipelinedsoc #(.P(P), `CVW_MULTICORE_CONNECT) dut(.clk(clock), .reset_ext(reset), .reset(resetint), .ExternalStall(1'b0),
    .HRDATAEXT, .HREADYEXT, .HRESPEXT, .HSELEXT, .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST,
    .HPROT, .HTRANS, .HMASTLOCK, .HREADY, .GPIOIN, .GPIOOUT, .GPIOEN, .UARTSin, .UARTSout, .SPIIn, .SPIOut, .SPICS,
    .SPICLK, .SDCIn, .SDCCmd, .SDCCS, .SDCCLK, .PWMGPIO, .TDO());

  // Registered, one cycle late: after gsim's step() the registers hold the new state but combinational nodes still
  // hold the values of the cycle just evaluated, so only flop outputs read consistently (in Verilator too).
  always_ff @(posedge clock) begin
    IEUAdrM     <= dut.core.lsu.IEUAdrM;
    WriteDataM  <= dut.core.WriteDataM;
    PCM         <= dut.core.PCM;
    InstrM      <= dut.core.InstrM;
    InstrValidM <= dut.core.InstrValidM;
    StallM      <= dut.core.StallM;
    FlushM      <= dut.core.FlushM;
  end

endmodule
