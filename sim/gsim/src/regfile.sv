///////////////////////////////////////////
// regfile.sv (gsim variant)
//
// Purpose: src/ieu/regfile.sv for gsim, which has a single rising-edge clock.  The original writes on the falling edge
//          so that a read in the same cycle sees the new value; here the write happens at the rising edge that ends
//          the cycle and a read of the register being written takes wd3 directly.  we3, a3 and wd3 come from the
//          Writeback stage, stable through the cycle, so both forms give the same values cycle by cycle.
//          LATCH_BASED (an ASIC option) is not modelled: this variant is for simulation only.
//
// A component of the Wally configurable RISC-V project.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module regfile #(parameter XLEN, E_SUPPORTED, LATCH_BASED) (
  input  logic             clk, reset,
  input  logic             we3,                 // Write enable
  input  logic [4:0]       a1, a2, a3,          // Source registers to read (a1, a2), destination register to write (a3)
  input  logic [XLEN-1:0]  wd3,                 // Write data for port 3
  output logic [XLEN-1:0]  rd1, rd2);           // Read data for ports 1, 2

  localparam NUMREGS = E_SUPPORTED ? 16 : 32;   // only 16 registers in E mode

  logic [XLEN-1:0] rf[NUMREGS-1:1];
  integer i;

  always_ff @(posedge clk)
    if (reset) for (i=1; i<NUMREGS; i++) rf[i] <= '0;
    else       if (we3 & a3 != 0)        rf[a3] <= wd3;

  function automatic logic [XLEN-1:0] rd(input logic [4:0] a);
    if (a == 0 | reset)     return '0;
    else if (we3 & a == a3) return wd3;
    else                    return rf[a];
  endfunction

  assign rd1 = rd(a1);
  assign rd2 = rd(a2);
endmodule
