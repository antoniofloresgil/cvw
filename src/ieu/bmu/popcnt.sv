///////////////////////////////////////////
// popcnt.sv
//
// Written:  Kevin Kim kekim@hmc.edu 4 February 2023
// Modified: Kip Macsai-Goren
//
// Purpose: Population count.
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2023-26 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module popcnt #(parameter WIDTH = 32) (
  input  logic [WIDTH-1:0]        num,    // number to count total ones
  output logic [$clog2(WIDTH):0]  PopCnt  // the total number of ones
);

  // Balanced adder tree: count each half recursively and add the counts.  A
  // linear chain of WIDTH increments is WIDTH adders deep, which synthesis tools
  // that do not restructure it (e.g. Yosys) map to a very slow carry path.
  if (WIDTH == 1) begin : leaf
    assign PopCnt = num;
  end else begin : tree
    logic [$clog2(WIDTH)-1:0] LoCnt, HiCnt;
    popcnt #(WIDTH/2) lo(.num(num[WIDTH/2-1:0]),     .PopCnt(LoCnt));
    popcnt #(WIDTH/2) hi(.num(num[WIDTH-1:WIDTH/2]), .PopCnt(HiCnt));
    assign PopCnt = {1'b0, LoCnt} + {1'b0, HiCnt};
  end
endmodule
