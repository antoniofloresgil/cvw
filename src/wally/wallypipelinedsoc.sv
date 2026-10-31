///////////////////////////////////////////
// wallypipelinedsoc.sv
//
// Written:  David Harris David_Harris@hmc.edu 6 November 2020
// Modified: Rose Thompson, Jacob Pease, Ben Bracker, Naiche Whyte-Aguayo
//
// Purpose: System on chip: core and uncore.
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2020-26 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module wallypipelinedsoc import cvw::*; #(parameter cvw_t P, `CVW_MULTICORE_PARAMS(P.AHBW))  (
  input  logic                clk,
  input  logic                reset_ext,        // external asynchronous reset pin
  output logic                reset,            // reset synchronized to clk to prevent races on release
  // AHB Interface
  input  logic [P.AHBW-1:0]    HRDATAEXT,
  input  logic                 HREADYEXT, HRESPEXT,
  output logic                 HSELEXT,
  // fpga debug signals
  input  logic                 ExternalStall,
  // outputs to external memory, shared with uncore memory
  output logic                 HCLK, HRESETn,
  output logic [P.PA_BITS-1:0] HADDR,
  output logic [P.AHBW-1:0]    HWDATA,
  output logic [P.XLEN/8-1:0]  HWSTRB,
  output logic                 HWRITE,
  output logic [2:0]           HSIZE,
  output logic [2:0]           HBURST,
  output logic [3:0]           HPROT,
  output logic [1:0]           HTRANS,
  output logic                 HMASTLOCK,
  output logic                 HREADY,
  // I/O Interface
  input  logic                 TIMECLK,         // optional for CLINT MTIME counter
  input  logic [31:0]          GPIOIN,          // inputs from GPIO
  output logic [31:0]          GPIOOUT,         // output values for GPIO
  output logic [31:0]          GPIOEN,          // output enables for GPIO
  input  logic                 UARTSin,         // UART serial data input
  output logic                 UARTSout,        // UART serial data output
  input  logic                 SPIIn,           // SPI pins in
  output logic                 SPIOut,          // SPI pins out
  output logic [3:0]           SPICS,           // SPI chip select pins
  output logic                 SPICLK,          // SPI clock
  input  logic                 SDCIn,           // SDC DATA[0]     to     SPI DI
  output logic                 SDCCmd,          // SDC CMD         from   SPI DO
  output logic [3:0]           SDCCS,           // SDC Card Detect from   SPI CS
  output logic                 SDCCLK,          // SDC Clock       from   SPI Clock
  output logic [3:0]           PWMGPIO          // PWM GPIO output
);

  // Uncore signals
  logic [P.AHBW-1:0]          HRDATA;           // from AHB mux in uncore
  logic                       HRESP;            // response from AHB
  logic [NCORES-1:0]          MTimerInt, MSwInt;// timer and software interrupts from CLINT
  logic [63:0]                MTIME_CLINT;      // from CLINT to CSRs
  logic [NCORES-1:0]          MExtInt,SExtInt;  // from PLIC

  // synchronize reset to SOC clock domain
  synchronizer resetsync(.clk, .d(reset_ext), .q(reset));

  // Keep hart zero named core for existing single-core verification probes.
  logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR;
  logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA, CoreHRDATA;
  logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB;
  logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK, CoreHREADY, CoreHRESP, CoreSCFail;
  logic [NCORES-1:0][2:0] CoreHSIZE, CoreHBURST;
  logic [NCORES-1:0][3:0] CoreHPROT;
  logic [NCORES-1:0][1:0] CoreHTRANS, CoreHATOMIC;

  // Preserve the upstream no-bus outputs; bus-enabled harts share clock/reset.
  assign HCLK = P.BUS_SUPPORTED ? clk : 1'b0;
  assign HRESETn = P.BUS_SUPPORTED ? ~reset : 1'b0;
  wallypipelinedcore #(.P(P), .HART_ID(0), .SHARED_ATOMICS(NCORES > 1 || SHARED_CACHE)) core(.clk, .reset,
    .SCFail(CoreSCFail[0]), .HATOMIC(CoreHATOMIC[0]),
    .MTimerInt(MTimerInt[0]), .MExtInt(MExtInt[0]), .SExtInt(SExtInt[0]), .MSwInt(MSwInt[0]), .MTIME_CLINT,
    .HRDATA(CoreHRDATA[0]), .HREADY(CoreHREADY[0]), .HRESP(CoreHRESP[0]), .HCLK(), .HRESETn(),
    .HADDR(CoreHADDR[0]), .HWDATA(CoreHWDATA[0]), .HWSTRB(CoreHWSTRB[0]),
    .HWRITE(CoreHWRITE[0]), .HSIZE(CoreHSIZE[0]), .HBURST(CoreHBURST[0]), .HPROT(CoreHPROT[0]),
    .HTRANS(CoreHTRANS[0]), .HMASTLOCK(CoreHMASTLOCK[0]), .ExternalStall);

  for (genvar h = 1; h < NCORES; h++) begin : harts
    wallypipelinedcore #(.P(P), .HART_ID(h), .SHARED_ATOMICS(1)) core(.clk, .reset,
      .SCFail(CoreSCFail[h]), .HATOMIC(CoreHATOMIC[h]),
      .MTimerInt(MTimerInt[h]), .MExtInt(MExtInt[h]), .SExtInt(SExtInt[h]), .MSwInt(MSwInt[h]), .MTIME_CLINT,
      .HRDATA(CoreHRDATA[h]), .HREADY(CoreHREADY[h]), .HRESP(CoreHRESP[h]), .HCLK(), .HRESETn(),
      .HADDR(CoreHADDR[h]), .HWDATA(CoreHWDATA[h]), .HWSTRB(CoreHWSTRB[h]),
      .HWRITE(CoreHWRITE[h]), .HSIZE(CoreHSIZE[h]), .HBURST(CoreHBURST[h]), .HPROT(CoreHPROT[h]),
      .HTRANS(CoreHTRANS[h]), .HMASTLOCK(CoreHMASTLOCK[h]), .ExternalStall);
  end

  // Memory topology and capability checks are owned by the optional subsystem.
  multicore_memory_system #(.P(P), `CVW_MULTICORE_CONNECT) memory_system(
    .HCLK, .HRESETn, .CoreHADDR, .CoreHWDATA, .CoreHWSTRB, .CoreHWRITE, .CoreHMASTLOCK,
    .CoreHSIZE, .CoreHBURST, .CoreHPROT, .CoreHTRANS, .CoreHATOMIC,
    .CoreSCFail, .CoreHRDATA, .CoreHREADY, .CoreHRESP,
    .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK,
    .HRDATA, .HREADY, .HRESP);

  // instantiate uncore if a bus interface exists
  if (P.BUS_SUPPORTED) begin : uncoregen // Hack to work around Verilator bug https://github.com/verilator/verilator/issues/4769
    uncore #(.P(P), .NCORES(NCORES)) uncore(.HCLK, .HRESETn, .TIMECLK,
      .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT, .HTRANS, .HMASTLOCK, .HRDATAEXT,
      .HREADYEXT, .HRESPEXT, .HRDATA, .HREADY, .HRESP, .HSELEXT,
      .MTimerInt, .MSwInt, .MExtInt, .SExtInt, .GPIOIN, .GPIOOUT, .GPIOEN, .UARTSin,
      .UARTSout, .MTIME_CLINT, .SPIIn, .SPIOut, .SPICS, .SPICLK, .SDCIn, .SDCCmd, .SDCCS, .SDCCLK, .PWMGPIO);
  end else begin
    assign {HRDATA, HREADY, HRESP, HSELEXT, MTimerInt, MSwInt, MExtInt, SExtInt,
            MTIME_CLINT, GPIOOUT, GPIOEN, UARTSout, SPIOut, SPICS, SPICLK, SDCCmd, SDCCS, SDCCLK, PWMGPIO} = '0;
  end

endmodule
