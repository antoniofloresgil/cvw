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
//            halfword accesses, the alignment and bad-address errors;
//          - the program running after hartreset is released (it drives 42 on the GPIOs and
//            writes a signature to RAM), and System Bus Access reading RAM and a peripheral
//            while the core fetches over the same bus;
//          - halt, dpc and dcsr, Access Register for GPRs and CSRs (cmderr 3 for a CSR that does
//            not exist), the program buffer with and without a transfer, an exception in it,
//            resume, and cmderr 2 and 4;
//          - single step (also over a wfi, which is then a nop), ebreak with dcsr.ebreakm, and
//            setresethaltreq, with dcsr.cause 4, 1 and 5;
//          - triggers (DEBUG_TRIGGERS): tselect and tinfo, execute and store address matches,
//            icount, etrigger (dcsr.cause 2), a native trigger raising a breakpoint exception,
//            and WARL values of tdata1;
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
                         SBCS = 7'h38, SBADDRESS0 = 7'h39, SBDATA0 = 7'h3C, DATA0 = 7'h04, DATA1 = 7'h05,
                         PROGBUF0 = 7'h20, HARTINFO = 7'h12;
  // Access Register: aarsize 2 (32 bits) or XLEN, transfer, write
  localparam logic [31:0] AR32 = 32'h0022_0000, ARX = P.XLEN == 64 ? 32'h0032_0000 : 32'h0022_0000,
                          ARWRITE = 32'h0001_0000, POSTEXEC = 32'h0004_0000;
  localparam logic [31:0] RAM = 32'h8000_0000, SIGNATURE = 32'h8000_1000, GPIO = 32'h1006_0000;
  localparam int unsigned ABITS = 7;

  // The program that System Bus Access loads (position independent, for RV32 and RV64):
  // drive 42 on the GPIOs, write 0x600dc0de at 0x80001000, loop; then an ebreak, a wfi and a
  // loop that only the debugger runs, by setting dpc
  localparam logic [31:0] PROGRAM [13] = '{
    32'h100602b7,   // lui   t0, 0x10060
    32'h0ff00313,   // li    t1, 255
    32'h0062a423,   // sw    t1, 8(t0)       output_en
    32'h02a00313,   // li    t1, 42
    32'h0062a623,   // sw    t1, 12(t0)      output_val
    32'h00001397,   // auipc t2, 0x1         0x80001014
    32'h600dc337,   // lui   t1, 0x600dc
    32'h0de30313,   // addi  t1, t1, 0xde
    32'hfe63a623,   // sw    t1, -20(t2)     0x80001000
    32'h0000006f,   // j     .               0x80000024
    32'h00100073,   // ebreak                0x80000028
    32'h10500073,   // wfi                   0x8000002c
    32'h0000006f};  // j     .               0x80000030

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

  // The bits go through jtagdrv, a module that does the TCK cycles on request: a task that
  // loops over the bits would be expanded at every call, and a testbench this long would
  // become a function that takes gigabytes to compile
  logic        JReq = 1'b0, JAck = 1'b0, JKind, JIr;
  int          JN;
  logic [63:0] JDin, JDout;
  jtagdrv jtag(.TCK, .TMS, .TDI, .TDO, .Req(JReq), .Ack(JAck), .Kind(JKind), .Ir(JIr), .N(JN),
               .Din(JDin), .Dout(JDout));

  task automatic jtagrequest(input logic kind, input logic ir, input int n, input logic [63:0] din);
    JKind = kind; JIr = ir; JN = n; JDin = din;
    JReq = ~JReq;
    wait (JAck == JReq);
  endtask

  // n TCK cycles with TMS taken from bits (LSB first) and TDI 0
  task automatic tmsseq(input int n, input logic [63:0] bits);
    jtagrequest(1'b1, 1'b0, n, bits);
  endtask

  task automatic tapreset();
    tmsseq(7, 64'h3F);                                // six cycles of TMS 1, then Run-Test/Idle
  endtask

  // From Run-Test/Idle, shift n bits (LSB first) through IR or DR and return to Run-Test/Idle
  task automatic shift(input logic ir, input int n, input logic [63:0] din, output logic [63:0] dout);
    jtagrequest(1'b0, ir, n, din);
    dout = JDout;
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
      tmsseq(4, 64'h0);
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

  // An abstract command: write it, wait while busy, return cmderr and clear it
  task automatic command(input logic [31:0] cmd, output logic [2:0] cmderr);
    logic [31:0] cs;
    dmiwrite(COMMAND, cmd);
    do dmiread(ABSTRACTCS, cs); while (cs[12]);       // busy
    cmderr = cs[10:8];
    if (cmderr != 0) dmiwrite(ABSTRACTCS, 32'h700);
  endtask

  task automatic readreg(input logic [15:0] regno, output logic [31:0] data);
    logic [2:0] err;
    command(ARX | 32'(regno), err);
    if (err != 0) begin
      $display("FAIL: reading register 0x%04h: cmderr %0d", regno, err);
      Errors++;
    end
    dmiread(DATA0, data);
  endtask

  task automatic writereg(input logic [15:0] regno, input logic [31:0] data);
    logic [2:0] err;
    dmiwrite(DATA0, data);
    if (P.XLEN == 64) dmiwrite(DATA1, 32'(0));
    command(ARX | ARWRITE | 32'(regno), err);
    if (err != 0) begin
      $display("FAIL: writing register 0x%04h: cmderr %0d", regno, err);
      Errors++;
    end
  endtask

  task automatic waithalted();
    logic [31:0] st;
    do dmiread(DMSTATUS, st); while (!st[9]);         // allhalted
  endtask

  // Resume at pc, and wait for the hart to halt again (a step or an ebreak)
  task automatic resumeat(input logic [31:0] pc);
    logic [31:0] st;
    writereg(16'h07B1, pc);                            // dpc
    dmiwrite(DMCONTROL, 32'h4000_0001);                // resumereq
    do dmiread(DMSTATUS, st); while (!st[17]);        // allresumeack
    waithalted();
  endtask

  // tdata1, given in the RV32 layout: on RV64, type and dmode (bits 31:27) move to bits 63:59
  task automatic writetdata1(input logic [31:0] v);
    logic [2:0] err;
    dmiwrite(DATA0, P.XLEN == 64 ? {5'b0, v[26:0]} : v);
    if (P.XLEN == 64) dmiwrite(DATA1, {v[31:27], 27'b0});
    command(ARX | ARWRITE | 32'h07A1, err);
    if (err != 0) begin
      $display("FAIL: writing tdata1: cmderr %0d", err);
      Errors++;
    end
  endtask

  task automatic readtdata1(output logic [31:0] v);
    logic [31:0] hi;
    readreg(16'h07A1, v);
    if (P.XLEN == 64) begin
      dmiread(DATA1, hi);
      v = {hi[31:27], v[26:0]};
    end
  endtask

  // dcsr.cause and dpc after the hart halts
  task automatic checkhalt(input string what, input logic [2:0] cause, input logic [31:0] pc);
    logic [31:0] d;
    readreg(16'h07B0, d);
    check({what, ": dcsr.cause"}, 32'(d[8:6]), 32'(cause));
    readreg(16'h07B1, d);
    check({what, ": dpc"}, d, pc);
  endtask

  ///////////////////////////////////////////////////////////////
  // The test
  ///////////////////////////////////////////////////////////////

  initial begin
    logic [63:0] dout;
    logic [31:0] d, dcsr, mtvec, mstatus;
    logic [2:0]  err;
    Errors = 0;
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

    // Only Access Register is supported: a Quick Access command fails with cmderr 2
    dmiwrite(COMMAND, 32'h0100_0000);
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
    // An address that no region decodes fails with sberror 2 (bad address)
    sbcs(3'd2, 1'b1, 1'b0, 1'b0);
    dmiwrite(SBADDRESS0, RAM - 8);
    dmiread(SBCS, d);
    check("sberror on an unmapped address", 32'(d[14:12]), 32'd2);
    dmiwrite(SBCS, 32'h7000);

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

    // Halt the hart: it loops at 0x80000024
    dmiread(HARTINFO, d);
    check("hartinfo: nscratch 1, dataaccess, datasize 2, dataaddr 0x380", d, 32'h0011_2380);
    dmiread(ABSTRACTCS, d);
    check("abstractcs: progbufsize 8, datacount 2", d & 32'h1F00_000F, 32'h0800_0002);
    dmiwrite(DMCONTROL, 32'h8000_0001);               // haltreq
    waithalted();
    dmiwrite(DMCONTROL, 32'h0000_0001);
    dmiread(DMSTATUS, d);
    check("dmstatus: all halted, impebreak", d & 32'h0040_0F00, 32'h0040_0300);
    readreg(16'h07B1, d);
    check("dpc", d, RAM + 32'h24);
    readreg(16'h07B0, d);
    check("dcsr: debugver 4, cause haltreq, prv M", d & 32'hF000_01C3, 32'h4000_00C3);
    readreg(16'h1005, d);
    check("x5 (t0) written by the program", d, GPIO);
    readreg(16'h1006, d);
    check("x6 (t1)", d, 32'h600D_C0DE);
    readreg(16'h0F14, d);
    check("mhartid", d, 32'h0);
    // A CSR that does not exist: the access raises an exception, cmderr 3
    dmiwrite(DATA0, 32'h8000_0000);
    if (P.XLEN == 64) dmiwrite(DATA1, 32'(0));
    command(ARX | ARWRITE | (P.VIRTMEM_SUPPORTED ? 32'h08F0 : 32'h0180), err);
    check("cmderr after writing a CSR that does not exist", 32'(err), 32'd3);
    dmiwrite(ABSTRACTCS, 32'h700);
    command(ARX | 32'h08F0, err);
    check("cmderr after reading a CSR that does not exist", 32'(err), 32'd3);
    dmiwrite(ABSTRACTCS, 32'h700);
    writereg(16'h1007, 32'h1234_5678);
    readreg(16'h1007, d);
    check("x7 (t2) written and read back", d, 32'h1234_5678);
    writereg(16'h1008, 32'h0000_0BAD);                 // s0, which the ROM saves and restores
    readreg(16'h1008, d);
    check("x8 (s0) written and read back", d, 32'h0000_0BAD);
    // Program buffer: addi t2, t2, 1; then read t2
    dmiwrite(PROGBUF0, 32'h0013_8393);
    command(POSTEXEC, err);
    check("cmderr of a program buffer execution", 32'(err), 32'd0);
    readreg(16'h1007, d);
    check("x7 after addi in the program buffer", d, 32'h1234_5679);
    // Transfer then postexec: write t2 = 5, then addi
    dmiwrite(DATA0, 32'd5);
    if (P.XLEN == 64) dmiwrite(DATA1, 32'(0));
    command(ARX | ARWRITE | POSTEXEC | 32'h1007, err);
    readreg(16'h1007, d);
    check("x7 written then incremented by postexec", d, 32'd6);
    // An exception in the program buffer: cmderr 3
    dmiwrite(PROGBUF0, 32'h0000_0000);                 // illegal instruction
    command(POSTEXEC, err);
    check("cmderr after an exception", 32'(err), 32'd3);
    readreg(16'h1008, d);
    check("x8 (s0) kept across the exception", d, 32'h0000_0BAD);
    // Single step (dcsr.step): the hart halts again after one instruction, with cause 4
    readreg(16'h07B0, dcsr);
    writereg(16'h07B0, dcsr | 32'h4);
    resumeat(RAM);
    checkhalt("step from the first instruction", 3'd4, RAM + 4);
    resumeat(RAM + 4);
    checkhalt("second step", 3'd4, RAM + 8);
    // A wfi that is stepped over is a nop
    resumeat(RAM + 32'h2C);
    checkhalt("step over wfi", 3'd4, RAM + 32'h30);
    // An ebreak in M-mode with dcsr.ebreakm enters Debug Mode, with cause 1, dpc at the ebreak
    writereg(16'h07B0, dcsr | 32'h8000);
    resumeat(RAM + 32'h28);
    checkhalt("ebreak with ebreakm", 3'd1, RAM + 32'h28);
    writereg(16'h07B0, dcsr);

    // Triggers (Sdtrig): tselect counts DEBUG_TRIGGERS, tinfo lists the types
    writereg(16'h07A0, P.DEBUG_TRIGGERS - 1);
    readreg(16'h07A0, d);
    check("tselect: the last trigger", d, P.DEBUG_TRIGGERS - 1);
    writereg(16'h07A0, P.DEBUG_TRIGGERS);
    readreg(16'h07A0, d);
    check("tselect: a trigger that does not exist is not selected", d, P.DEBUG_TRIGGERS - 1);
    writereg(16'h07A0, 32'h0);
    readreg(16'h07A4, d);
    check("tinfo: version 1, types 2 to 6 and 15", d, 32'h0100_807C);
    // An execute address trigger (mcontrol6, dmode, action 1, m) halts before the instruction
    writereg(16'h07A2, RAM + 32'h10);                  // tdata2: sw t1, 12(t0)
    writetdata1(32'h6800_1044);
    resumeat(RAM);
    checkhalt("execute trigger", 3'd2, RAM + 32'h10);
    readtdata1(d);
    check("mcontrol6 hit1:hit0 = 1: fired before the instruction", d & 32'h0240_0000, 32'h0040_0000);
    // A store address trigger halts before the store reaches the GPIO
    sbwrite(3'd2, GPIO + 32'hC, 32'h0);
    writereg(16'h07A2, GPIO + 32'hC);
    writetdata1(32'h6800_1042);
    resumeat(RAM);
    checkhalt("store address trigger", 3'd2, RAM + 32'h10);
    check("GPIOs: the store did not happen", GPIOOUT, 32'h0);
    // icount (count 2, m, action 1) halts after two instructions
    writetdata1(32'h3800_0A01);
    resumeat(RAM);
    checkhalt("icount 2", 3'd2, RAM + 8);
    // etrigger on breakpoint exceptions halts before the first instruction of the handler
    readreg(16'h0305, mtvec);
    writereg(16'h0305, RAM + 32'h30);                  // mtvec: j .
    writereg(16'h07A2, 32'h8);                         // cause 3
    writetdata1(32'h5800_0201);
    resumeat(RAM + 32'h28);                            // ebreak, with dcsr.ebreakm 0
    checkhalt("etrigger", 3'd2, RAM + 32'h30);
    readreg(16'h0342, d);
    check("mcause of the exception that fired etrigger", d, 32'd3);
    // A native trigger (dmode 0, action 0) raises a breakpoint exception, in M-mode only with
    // mstatus.MIE set
    writereg(16'h07A2, RAM + 32'h10);
    writetdata1(32'h6000_0044);
    readreg(16'h0300, mstatus);
    writereg(16'h0300, mstatus | 32'h8);
    writereg(16'h07B1, RAM);
    dmiwrite(DMCONTROL, 32'h4000_0001);                // resume; the handler loops at RAM + 0x30
    repeat (100) @(posedge clk);
    dmiwrite(DMCONTROL, 32'h8000_0001);
    waithalted();
    dmiwrite(DMCONTROL, 32'h0000_0001);
    checkhalt("halt in the handler of a native trigger", 3'd3, RAM + 32'h30);
    readreg(16'h0342, d);
    check("native trigger: mcause breakpoint", d, 32'd3);
    readreg(16'h0341, d);
    check("native trigger: mepc", d, RAM + 32'h10);
    // tdata1 is WARL: without dmode, action 1 is not legal
    writetdata1(32'h6000_1001);
    readtdata1(d);
    check("tdata1 WARL: action 0 without dmode", d, 32'h6000_0001);
    writetdata1(32'h0);
    readtdata1(d);
    check("tdata1: type 0 written reads a free trigger (mcontrol6, all 0)", d, 32'h6000_0000);
    writereg(16'h0300, mstatus);
    writereg(16'h0305, mtvec);
    sbwrite(3'd2, GPIO + 32'hC, 32'd42);
    // Restore the registers the program uses, and resume in its loop
    writereg(16'h1008, 32'h0);
    writereg(16'h07B1, RAM + 32'h24);
    dmiwrite(DMCONTROL, 32'h4000_0001);                // resumereq
    dmiread(DMSTATUS, d);
    check("dmstatus: all running, resumeack", d & 32'h0003_0F00, 32'h0003_0C00);
    command(ARX | 32'h1005, err);
    check("cmderr of a command while running", 32'(err), 32'd4);
    repeat (50) @(posedge clk);
    check("GPIOs after resuming", GPIOOUT, 32'd42);

    // setresethaltreq: the hart halts on its first instruction after a reset, with cause 5
    dmiwrite(DMCONTROL, 32'h0000_0009);                // setresethaltreq
    dmiwrite(DMCONTROL, 32'h2000_0001);                // hartreset
    dmiwrite(DMCONTROL, 32'h1000_0001);                // release it, ackhavereset
    waithalted();
    checkhalt("halt after reset with resethaltreq", 3'd5, RAM);
    dmiwrite(DMCONTROL, 32'h0000_0005);                // clrresethaltreq
    dmiwrite(DMCONTROL, 32'h4000_0001);                // resumereq
    repeat (200) @(posedge clk);
    check("GPIOs after resuming from the reset halt", GPIOOUT, 32'd42);

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

///////////////////////////////////////////////////////////////
// jtagdrv: the TCK cycles of debug_tb's JTAG scans.  The testbench sets Kind, Ir, N and Din and
// toggles Req; the module does the work and sets Ack equal to Req.
//   Kind 0: from Run-Test/Idle, shift N bits (LSB first) of Din through IR or DR, return to
//           Run-Test/Idle, and leave the bits that came out in Dout
//   Kind 1: N TCK cycles with TMS taken from the bits of Din and TDI 0
///////////////////////////////////////////////////////////////

module jtagdrv (
  output logic        TCK = 1'b0, TMS = 1'b1, TDI = 1'b0,
  input  logic        TDO,
  input  logic        Req,
  output logic        Ack = 1'b0,
  input  logic        Kind, Ir,
  input  int          N,
  input  logic [63:0] Din,
  output logic [63:0] Dout
);

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

  always @(Req) begin
    logic b;
    if (Kind) begin
      for (int i = 0; i < N; i++) tck0(Din[i]);
    end else begin
      tck0(1'b1);                                     // Select-DR
      if (Ir) tck0(1'b1);                             // Select-IR
      tck0(1'b0);                                     // Capture
      tck0(1'b0);                                     // Shift
      Dout = '0;
      for (int i = 0; i < N; i++) begin
        tck(i == N-1, Din[i], b);                     // the last bit moves to Exit1
        Dout[i] = b;
      end
      tck0(1'b1);                                     // Update
      tck0(1'b0);                                     // Run-Test/Idle
    end
    Ack = Req;
  end
endmodule
