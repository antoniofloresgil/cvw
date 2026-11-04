///////////////////////////////////////////
// etrace_tb.sv
//
// Purpose: The instruction trace of a SoC with several harts (docs/trace.md): every hart runs
//          etracetest.S at once, each tracing itself through its own trace encoder and RAM sink
//          (src/debug/etrace.sv), and etracedump.sv writes, for each hart h, the lines that its
//          encoder takes (+EtraceCsv=<file>.h<h>) and the words that the hart reads back from its
//          sink (+EtracePackets=<file>.h<h>), for the check with etracecheck.py.
//          testbench.sv runs one hart only, so this testbench loads the program itself:
//            +MemFile=<elf>.memfile   the program, loaded into RAM before reset is released
//            +Tohost=<hex address>    where hart 0 reports its result
//            +Results=<hex address>   results[h]: where hart h > 0 reports its result
//          It waits until every hart has reported, and prints "SUCCESS! All tests ran without
//          failures." if every result is 1.  The SoC needs a configuration without caches (the
//          multicore rule), so that the testbench reads the results straight from RAM.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module etrace_tb #(parameter int unsigned NHARTS = 2);   // -GNHARTS=<n>
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"

  localparam int unsigned TIMEOUT = 2_000_000;     // cycles

  logic        clk, reset_ext, reset;
  logic        TDO;
  logic [31:0] GPIOOUT, GPIOEN;
  logic        UARTSout, SPIOut, SPICLK, SDCCmd, SDCCLK;
  logic [3:0]  SPICS, SDCCS, PWMGPIO;
  logic        HCLK, HRESETn, HSELEXT, HWRITE, HMASTLOCK, HREADY;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.AHBW-1:0]    HWDATA;
  logic [P.XLEN/8-1:0]  HWSTRB;
  logic [2:0]  HSIZE, HBURST;
  logic [3:0]  HPROT;
  logic [1:0]  HTRANS;

  wallypipelinedsoc #(.P(P), .NCORES(NHARTS)) dut(.clk, .reset_ext, .reset, .ExternalStall(1'b0),
    .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT,
    .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT,
    .HTRANS, .HMASTLOCK, .HREADY, .GPIOIN('0), .GPIOOUT, .GPIOEN,
    .UARTSin(1'b1), .UARTSout, .SPIIn(1'b0), .SPIOut, .SPICS, .SPICLK, .SDCIn(1'b1), .SDCCmd, .SDCCS,
    .SDCCLK, .PWMGPIO, .TCK(1'b0), .TMS(1'b1), .TDI(1'b0), .TDO);

  // The trace of each hart
  for (genvar h = 0; h < NHARTS; h++) begin : dump
    etracedump #(.P(P), .HART(h)) etracedump(.clk, .reset, .ITrace(dut.CoreITrace[h]),
      .LineTaken(dut.etracegen.etrace.hart[h].LineTaken),
      .DataRead(dut.etracegen.etrace.hart[h].DataRead), .RamDout(dut.etracegen.etrace.hart[h].RamDout));
  end

  always begin
    clk = 1'b1; #5; clk = 1'b0; #5;
  end

  // The XLEN-bit RAM word at a physical address
  function automatic logic [P.XLEN-1:0] ramword(input logic [63:0] adr);
    return dut.uncoregen.uncore.ram.ram.memory.ram.RAM[(adr - P.UNCORE_RAM_BASE) / (P.XLEN/8)];
  endfunction

  string             memfile;
  logic [63:0]       tohost, results;
  logic [P.XLEN-1:0] Result [NHARTS];
  int                Errors, Cycles;
  logic              Done;
  initial begin
    if (!$value$plusargs("MemFile=%s", memfile) || !$value$plusargs("Tohost=%h", tohost) ||
        !$value$plusargs("Results=%h", results)) begin
      $display("Error: etrace_tb needs +MemFile=, +Tohost= and +Results=");
      $finish;
    end
    reset_ext = 1'b1;
    $readmemh(memfile, dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
    #100 reset_ext = 1'b0;

    // Wait until every hart has reported its result
    Done = 1'b0;
    for (Cycles = 0; Cycles < TIMEOUT && !Done; Cycles += 100) begin
      repeat (100) @(posedge clk);
      Result[0] = ramword(tohost);
      for (int h = 1; h < NHARTS; h++) Result[h] = ramword(results + 64'(8*h));
      Done = 1'b1;
      for (int h = 0; h < NHARTS; h++) if (Result[h] == 0) Done = 1'b0;
    end
    repeat (10) @(posedge clk);                    // the files of etracedump
    Errors = 0;
    for (int h = 0; h < NHARTS; h++)
      if (Result[h] != 1) begin
        Errors++;
        if (Result[h] == 0) $display("FAIL: hart %0d did not report a result in %0d cycles", h, TIMEOUT);
        else $display("FAIL: hart %0d reported %0d (exit code %0d)", h, Result[h], Result[h] >> 1);
      end else $display("ok   hart %0d passed", h);
    if (Errors == 0) $display("SUCCESS! All tests ran without failures.");
    else             $display("FAIL: %0d harts had errors", Errors);
    $finish;
  end
endmodule
