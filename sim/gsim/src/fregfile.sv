///////////////////////////////////////////
// fregfile.sv (gsim variant)
//
// Purpose: src/fpu/fregfile.sv for gsim, which has a single rising-edge clock.  The original writes on the falling
//          edge so that a read in the same cycle sees the new value; here the write happens at the rising edge that
//          ends the cycle and a read of the register being written takes wd4 directly (see sim/gsim/src/regfile.sv).
//
// A component of the Wally configurable RISC-V project.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module fregfile #(parameter FLEN) (
  input  logic            clk, reset,
  input  logic            we4,            // write enable
  input  logic [4:0]      a1, a2, a3, a4, // addresses
  input  logic [FLEN-1:0] wd4,            // write data
  output logic [FLEN-1:0] rd1, rd2, rd3   // read data
);

  logic [FLEN-1:0] rf[31:0];
  integer i;

  always_ff @(posedge clk)
    if (reset) for (i = 0; i < 32; i++) rf[i] <= '0;
    else if (we4) rf[a4] <= wd4;

  function automatic logic [FLEN-1:0] rd(input logic [4:0] a);
    if (reset)              return '0;
    else if (we4 & a == a4) return wd4;
    else                    return rf[a];
  endfunction

  assign rd1 = rd(a1);
  assign rd2 = rd(a2);
  assign rd3 = rd(a3);

endmodule // fregfile
