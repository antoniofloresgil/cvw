///////////////////////////////////////////
// etracedump.sv
//
// Purpose: Writes the instruction trace interface of hart 0 (src/debug/etraceingress.sv) as the
//          encoder input CSV of the E-Trace reference flow (riscv-trace-spec/referenceFlow), with
//          +EtraceCsv=<file>: one row per line, columns itype_0, cause, tval (hex), priv,
//          iaddr_0 (hex), context, ctype, iretire_0, ilastsize_0.  docs/trace.md explains how the
//          reference encoder and decoder check it.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module etracedump import cvw::*; #(parameter cvw_t P) (
  input logic                  clk, reset,
  input logic [2*P.XLEN+13:0]  ITrace
);

  logic              Valid, Halted, IRetire, ILastSize;
  logic [2:0]        IType;
  logic [1:0]        Priv;
  logic [4:0]        Cause;
  logic [P.XLEN-1:0] IAddr, Tval;
  assign {Valid, Halted, IType, IRetire, ILastSize, Priv, Cause, IAddr, Tval} = ITrace;

  string file;
  int    fd;
  initial begin
    fd = 0;
    if ($value$plusargs("EtraceCsv=%s", file)) begin
      fd = $fopen(file, "w");
      if (fd == 0) $display("Error: cannot write %s", file);
      else $fwrite(fd, "itype_0,cause,tval,priv,iaddr_0,context,ctype,iretire_0,ilastsize_0\n");
    end
  end

  always @(posedge clk)
    if (fd != 0 & ~reset & Valid)
      $fwrite(fd, "%0d,%0d,%h,%0d,%h,0,0,%0d,%0d\n", IType, Cause, Tval, Priv, IAddr, IRetire, ILastSize);

  final if (fd != 0) $fclose(fd);
endmodule
