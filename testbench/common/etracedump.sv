///////////////////////////////////////////
// etracedump.sv
//
// Purpose: Dumps the instruction trace of hart 0 for the E-Trace reference flow
//          (riscv-trace-spec/referenceFlow); docs/trace.md explains the check.
//          +EtraceCsv=<file>:     the lines of the instruction trace interface
//                                 (src/debug/etraceingress.sv) that the encoder takes
//                                 (src/debug/etraceencoder.sv), as the reference encoder's input
//                                 CSV: itype_0, cause, tval (hex), priv, iaddr_0 (hex), context,
//                                 ctype, iretire_0, ilastsize_0
//          +EtracePackets=<file>: the words that the program reads from the RAM sink's trRamData
//                                 (src/debug/etracesink.sv), one per line in hex bytes, first
//                                 byte first: the packets of the encoder as the sink stored them
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module etracedump import cvw::*; #(parameter cvw_t P) (
  input logic                  clk, reset,
  input logic [2*P.XLEN+13:0]  ITrace,
  input logic                  LineTaken,
  input logic                  DataRead,
  input logic [31:0]           RamDout
);

  logic              Valid, Halted, IRetire, ILastSize;
  logic [2:0]        IType;
  logic [1:0]        Priv;
  logic [4:0]        Cause;
  logic [P.XLEN-1:0] IAddr, Tval;
  assign {Valid, Halted, IType, IRetire, ILastSize, Priv, Cause, IAddr, Tval} = ITrace;

  string file;
  int    fd, pfd;
  initial begin
    fd = 0; pfd = 0;
    if ($value$plusargs("EtraceCsv=%s", file)) begin
      fd = $fopen(file, "w");
      if (fd == 0) $display("Error: cannot write %s", file);
      else $fwrite(fd, "itype_0,cause,tval,priv,iaddr_0,context,ctype,iretire_0,ilastsize_0\n");
    end
    if ($value$plusargs("EtracePackets=%s", file)) begin
      pfd = $fopen(file, "w");
      if (pfd == 0) $display("Error: cannot write %s", file);
    end
  end

  always @(posedge clk) begin
    if (fd != 0 & ~reset & LineTaken)
      $fwrite(fd, "%0d,%0d,%h,%0d,%h,0,0,%0d,%0d\n", IType, Cause, Tval, Priv, IAddr, IRetire, ILastSize);
    if (pfd != 0 & ~reset & DataRead)
      $fwrite(pfd, "%h%h%h%h\n", RamDout[7:0], RamDout[15:8], RamDout[23:16], RamDout[31:24]);
  end

  final begin
    if (fd != 0) $fclose(fd);
    if (pfd != 0) $fclose(pfd);
  end
endmodule
