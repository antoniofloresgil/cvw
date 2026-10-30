///////////////////////////////////////////
//
// Written: me@KatherineParry.com
// Modified: 7/5/2022
// Modified: 2/11/2026 james.stine@okstate.edu/marcus@infinitymdm.dev
//
// Purpose: Leading Zero Counter
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
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
