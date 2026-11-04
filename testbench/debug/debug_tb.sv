///////////////////////////////////////////
// debug_tb.sv
//
// Purpose: Self-checking test of the JTAG debug port (src/debug) on a configuration with
//          DEBUG_SUPPORTED: the testbench acts as a debugger, driving TCK, TMS and TDI itself
//          (TCK asynchronous to the system clock), and checks:
//          - the TAP: IDCODE after reset, BYPASS, dtmcs (version 1, abits 7);
//          - the Debug Module: dmstatus (version 3, the hart running or in reset, havereset),
//            hartreset, ackhavereset, an abstract command failing with cmderr 2;
//          - System Bus Access: loading a program into RAM with auto-increment while hartreset
//            holds the core, reading it back with sbreadonaddr and sbreadondata, byte and
//            halfword accesses, an alignment error;
//          - the program running after hartreset is released (it drives 42 on the GPIOs and
//            writes a signature to RAM), and System Bus Access reading RAM and a peripheral
//            while the core fetches over the same bus;
//          - ndmreset: the SoC resets (GPIOs back to 0) and the Debug Module stays active.
//          It prints "SUCCESS! All tests ran without failures." or the number of failures.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module debug_tb;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"

  // DMI registers
  localparam logic [6:0] DMCONTROL = 7'h10, DMSTATUS = 7'h11, ABSTRACTCS = 7'h16, COMMAND = 7'h17,
                         SBCS = 7'h38, SBADDRESS0 = 7'h39, SBDATA0 = 7'h3C;
  localparam logic [31:0] RAM = 32'h8000_0000, SIGNATURE = 32'h8000_1000, GPIO = 32'h1006_0000;
  localparam int unsigned ABITS = 7;

  // The program that System Bus Access loads (position independent, for RV32 and RV64):
  // drive 42 on the GPIOs, write 0x600dc0de at 0x80001000, loop
  localparam logic [31:0] PROGRAM [10] = '{
    32'h100602b7,   // lui   t0, 0x10060
    32'h0ff00313,   // li    t1, 255
    32'h0062a423,   // sw    t1, 8(t0)       output_en
    32'h02a00313,   // li    t1, 42
    32'h0062a623,   // sw    t1, 12(t0)      output_val
    32'h00001397,   // auipc t2, 0x1         0x80001014
    32'h600dc337,   // lui   t1, 0x600dc
    32'h0de30313,   // addi  t1, t1, 0xde
    32'hfe63a623,   // sw    t1, -20(t2)     0x80001000
    32'h0000006f};  // j     .

  logic        clk, reset_ext, reset;
  logic        TCK, TMS, TDI, TDO;
  logic [31:0] GPIOIN, GPIOOUT, GPIOEN;
  logic        UARTSin, UARTSout, SPIIn, SPIOut, SPICLK, SDCIn, SDCCmd, SDCCLK;
  logic [3:0]  SPICS, SDCCS, PWMGPIO;
  logic        HCLK, HRESETn, HSELEXT, HWRITE, HMASTLOCK, HREADY;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.AHBW-1:0]    HWDATA;
  logic [P.XLEN/8-1:0]  HWSTRB;
  logic [2:0]  HSIZE, HBURST;
  logic [3:0]  HPROT;
  logic [1:0]  HTRANS;
  int          Errors;

  assign GPIOIN = '0;
  assign UARTSin = 1'b1;
  assign SPIIn = 1'b0;
  assign SDCIn = 1'b1;

  wallypipelinedsoc #(P) dut(.clk, .reset_ext, .reset, .ExternalStall(1'b0),
    .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT,
    .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST, .HPROT,
    .HTRANS, .HMASTLOCK, .HREADY, .TIMECLK(1'b0), .GPIOIN, .GPIOOUT, .GPIOEN,
    .UARTSin, .UARTSout, .SPIIn, .SPIOut, .SPICS, .SPICLK, .SDCIn, .SDCCmd, .SDCCS, .SDCCLK, .PWMGPIO,
    .TCK, .TMS, .TDI, .TDO);

  // 100 MHz system clock; TCK is asynchronous to it, with a period of 46 ns
  always begin
    clk = 1'b1; #5; clk = 1'b0; #5;
  end

  ///////////////////////////////////////////////////////////////
  // JTAG
  ///////////////////////////////////////////////////////////////

  // One TCK cycle: TMS and TDI set up before the rising edge, TDO sampled at it
  task automatic tck(input logic tms, input logic tdi, output logic tdo);
    TMS = tms; TDI = tdi;
    #23; tdo = TDO; TCK = 1'b1;
    #23; TCK = 1'b0;
  endtask

  task automatic tck0(input logic tms);
    logic unused;
    tck(tms, 1'b0, unused);
  endtask

  task automatic tapreset();
    repeat (6) tck0(1'b1);
    tck0(1'b0);                                       // Run-Test/Idle
  endtask

  // From Run-Test/Idle, shift n bits (LSB first) through IR or DR and return to Run-Test/Idle
  task automatic shift(input logic ir, input int n, input logic [63:0] din, output logic [63:0] dout);
    logic b;
    tck0(1'b1);                                       // Select-DR
    if (ir) tck0(1'b1);                               // Select-IR
    tck0(1'b0);                                       // Capture
    tck0(1'b0);                                       // Shift
    dout = '0;
    for (int i = 0; i < n; i++) begin
      tck(i == n-1, din[i], b);                       // the last bit moves to Exit1
      dout[i] = b;
    end
    tck0(1'b1);                                       // Update
    tck0(1'b0);                                       // Run-Test/Idle
  endtask

  task automatic setir(input logic [4:0] ir);
    logic [63:0] unused;
    shift(1'b1, 5, 64'(ir), unused);
  endtask

  // A DMI access: the request scan, the Run-Test/Idle cycles that dtmcs.idle asks for, then a
  // nop scan that returns the result; on busy, clear it with dtmcs.dmireset and retry
  task automatic dmi(input logic [1:0] op, input logic [6:0] addr, input logic [31:0] data,
                     output logic [31:0] rdata);
    logic [63:0] dout, unused;
    for (int attempt = 0; attempt < 10; attempt++) begin
      setir(5'h11);
      shift(1'b0, ABITS+34, {23'b0, addr, data, op}, unused);
      repeat (4) tck0(1'b0);
      shift(1'b0, ABITS+34, '0, dout);
      if (dout[1:0] != 2'd3) begin
        rdata = dout[33:2];
        if (dout[1:0] != 2'd0) begin
          $display("FAIL: DMI op %0d at 0x%02h returned status %0d", op, addr, dout[1:0]);
          Errors++;
        end
        return;
      end
      setir(5'h10);
      shift(1'b0, 32, 64'h1 << 16, unused);           // dmireset
    end
    $display("FAIL: DMI op %0d at 0x%02h stays busy", op, addr);
    Errors++;
  endtask

  task automatic dmiwrite(input logic [6:0] addr, input logic [31:0] data);
    logic [31:0] unused;
    dmi(2'd2, addr, data, unused);
  endtask

  task automatic dmiread(input logic [6:0] addr, output logic [31:0] data);
    dmi(2'd1, addr, '0, data);
  endtask

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] expected);
    if (got !== expected) begin
      $display("FAIL: %s: 0x%08h, expected 0x%08h", what, got, expected);
      Errors++;
    end else $display("ok   %s: 0x%08h", what, got);
  endtask

  // System Bus Access: sbcs with the access size and the read-on-address/data and
  // auto-increment bits
  task automatic sbcs(input logic [2:0] access, input logic readonaddr, input logic autoincrement,
                      input logic readondata);
    dmiwrite(SBCS, {11'b0, readonaddr, access, autoincrement, readondata, 15'b0});
  endtask

  task automatic sbwait();
    logic [31:0] cs;
    do dmiread(SBCS, cs); while (cs[21]);           // sbbusy
    if (cs[14:12] != 0 || cs[22]) begin
      $display("FAIL: sbcs 0x%08h: sberror %0d, sbbusyerror %0d", cs, cs[14:12], cs[22]);
      Errors++;
    end
  endtask

  task automatic sbread(input logic [2:0] access, input logic [31:0] addr, output logic [31:0] data);
    sbcs(access, 1'b1, 1'b0, 1'b0);
    dmiwrite(SBADDRESS0, addr);
    sbwait();
    dmiread(SBDATA0, data);
  endtask

  task automatic sbwrite(input logic [2:0] access, input logic [31:0] addr, input logic [31:0] data);
    sbcs(access, 1'b0, 1'b0, 1'b0);
    dmiwrite(SBADDRESS0, addr);
    dmiwrite(SBDATA0, data);
    sbwait();
  endtask

  ///////////////////////////////////////////////////////////////
  // The test
  ///////////////////////////////////////////////////////////////

  initial begin
    logic [63:0] dout;
    logic [31:0] d;
    Errors = 0;
    TCK = 1'b0; TMS = 1'b1; TDI = 1'b0;
    reset_ext = 1'b1;
    #100 reset_ext = 1'b0;
    #100;

    // TAP: IDCODE is selected after reset; BYPASS is one bit
    tapreset();
    shift(1'b0, 32, '0, dout);
    check("IDCODE", dout[31:0], 32'h0000_0001);
    setir(5'h1F);
    shift(1'b0, 4, 64'b1011, dout);
    check("BYPASS delays one bit", 32'(dout[3:0]), 32'b0110);
    setir(5'h10);
    shift(1'b0, 32, '0, dout);
    check("dtmcs version and abits", dout[31:0] & 32'h3FF, {22'b0, 6'(ABITS), 4'd1});

    // Debug Module: activate it and hold the hart in reset
    dmiwrite(DMCONTROL, 32'h1);
    dmiread(DMCONTROL, d);
    check("dmcontrol.dmactive", d, 32'h1);
    dmiwrite(DMCONTROL, 32'h2000_0001);                // hartreset
    dmiread(DMSTATUS, d);
    check("dmstatus: version 3, authenticated, all unavailable, havereset",
          d & 32'h000F_3F8F, 32'h000C_3083);

    // Abstract commands are not supported
    dmiwrite(COMMAND, 32'h0);
    dmiread(ABSTRACTCS, d);
    check("abstractcs.cmderr after a command", 32'(d[10:8]), 32'd2);
    dmiwrite(ABSTRACTCS, 32'h700);
    dmiread(ABSTRACTCS, d);
    check("abstractcs.cmderr cleared", 32'(d[10:8]), 32'd0);

    // System Bus Access: load the program with auto-increment, read it back
    dmiread(SBCS, d);
    check("sbcs: sbversion 1, sbasize, 32-bit access", d & 32'hE000_0FE4, {3'd1, 17'b0, 7'(P.PA_BITS), 5'b00100});
    sbcs(3'd2, 1'b0, 1'b1, 1'b0);
    dmiwrite(SBADDRESS0, RAM);
    foreach (PROGRAM[i]) begin
      dmiwrite(SBDATA0, PROGRAM[i]);
      sbwait();
    end
    dmiread(SBADDRESS0, d);
    check("sbaddress0 auto-incremented", d, RAM + 4*$size(PROGRAM));
    sbcs(3'd2, 1'b1, 1'b1, 1'b1);
    dmiwrite(SBADDRESS0, RAM);
    foreach (PROGRAM[i]) begin
      sbwait();
      dmiread(SBDATA0, d);                               // and starts the next read
      check($sformatf("program word %0d", i), d, PROGRAM[i]);
    end
    sbwait();

    // Bytes and halfwords
    sbwrite(3'd2, SIGNATURE + 32'h10, 32'h0000_0000);
    sbwrite(3'd0, SIGNATURE + 32'h11, 32'h0000_00A5);
    sbwrite(3'd1, SIGNATURE + 32'h12, 32'h0000_BEEF);
    sbread(3'd2, SIGNATURE + 32'h10, d);
    check("byte and halfword writes", d, 32'hBEEF_A500);
    sbread(3'd0, SIGNATURE + 32'h13, d);
    check("byte read", d, 32'h0000_00BE);
    sbread(3'd1, SIGNATURE + 32'h10, d);
    check("halfword read", d, 32'h0000_A500);

    // An unaligned word access fails with sberror 3, cleared by writing 1
    sbcs(3'd2, 1'b1, 1'b0, 1'b0);
    dmiwrite(SBADDRESS0, RAM + 2);
    dmiread(SBCS, d);
    check("sberror on an unaligned access", 32'(d[14:12]), 32'd3);
    dmiwrite(SBCS, 32'h7000);
    dmiread(SBCS, d);
    check("sberror cleared", 32'(d[14:12]), 32'd0);

    // Release the hart: it runs the program, fetching over the bus that System Bus Access shares
    check("GPIOs while the hart is held in reset", GPIOOUT, 32'h0);
    dmiwrite(DMCONTROL, 32'h1000_0001);                // ackhavereset, hartreset 0
    dmiread(DMSTATUS, d);
    check("dmstatus: all running, havereset acknowledged", d & 32'h000F_3F00, 32'h0000_0C00);
    repeat (200) @(posedge clk);
    check("GPIOs driven by the program", GPIOOUT, 32'd42);
    // System Bus Access reads memory, not the hart's caches (the specification leaves coherence
    // to the debugger): with a write-back D-cache the signature is still in the cache
    if (P.DCACHE_SUPPORTED)
      $display("skip signature written by the program: in the D-cache, which System Bus Access does not see");
    else begin
      sbread(3'd2, SIGNATURE, d);
      check("signature written by the program", d, 32'h600D_C0DE);
    end
    sbread(3'd2, GPIO + 32'hC, d);
    check("GPIO output_val read over System Bus Access", d, 32'd42);
    for (int i = 0; i < 4; i++) begin
      sbwrite(3'd2, SIGNATURE + 32'h20 + 4*i, 32'h1234_0000 + i);
      sbread(3'd2, SIGNATURE + 32'h20 + 4*i, d);
      check($sformatf("write and read while the hart runs, %0d", i), d, 32'h1234_0000 + i);
    end

    // ndmreset resets the SoC but not the Debug Module
    dmiwrite(DMCONTROL, 32'h0000_0003);
    dmiwrite(DMCONTROL, 32'h2000_0001);                // hold the hart again
    check("GPIOs after ndmreset", GPIOOUT, 32'h0);
    dmiread(DMCONTROL, d);
    check("Debug Module active after ndmreset", d, 32'h2000_0001);
    dmiwrite(DMCONTROL, 32'h1000_0001);
    repeat (200) @(posedge clk);
    check("GPIOs driven again after the restart", GPIOOUT, 32'd42);

    if (Errors == 0) $display("SUCCESS! All tests ran without failures.");
    else             $display("FAIL: %0d test programs had errors", Errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
