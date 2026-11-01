///////////////////////////////////////////
// lzc.sv
//
// Written:  Katherine Parry me@KatherineParry.com 27 May 2022
// Modified: James Stine james.stine@okstate.edu, Marcus Mellor marcus@infinitymdm.dev, Kevin Kim
//
// Purpose: Leading zero counter.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2022-26 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module lzc #(parameter WIDTH = 1) (
  input  logic [WIDTH-1:0]            num,    // number to count the leading zeroes of
  output logic [$clog2(WIDTH+1)-1:0]  ZeroCnt // the number of leading zeroes
);

  // Pad num with ones on the right to a power of two N > WIDTH, so the padded
  // value is never zero and its leading-zero count (WIDTH when num is zero)
  // fits in $clog2(N) = $clog2(WIDTH+1) bits.  A balanced tree keeps the depth
  // logarithmic; a priority loop counting up one bit at a time is WIDTH
  // incrementers deep in tools that do not restructure it (e.g. Yosys).
  localparam N = 2**$clog2(WIDTH+1);
  logic Valid;

  lzctree #(N) tree(.num({num, {(N-WIDTH){1'b1}}}), .Valid, .ZeroCnt);
endmodule
