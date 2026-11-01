///////////////////////////////////////////
//
// lzctree.sv
//
// Purpose: Balanced-tree leading zero counter used by lzc
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2021-26 Harvey Mudd College & Oklahoma State University
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

// Leading-zero count of a power-of-two-wide value; Valid is clear when it is zero.
module lzctree #(parameter N = 2) (
  input  logic [N-1:0]          num,
  output logic                  Valid,
  output logic [$clog2(N)-1:0]  ZeroCnt
);

  if (N == 2) begin : leaf
    assign Valid   = |num;
    assign ZeroCnt = ~num[1];
  end else begin : tree
    logic                   HiValid, LoValid;
    logic [$clog2(N)-2:0]   HiCnt, LoCnt;
    lzctree #(N/2) hi(.num(num[N-1:N/2]), .Valid(HiValid), .ZeroCnt(HiCnt));
    lzctree #(N/2) lo(.num(num[N/2-1:0]), .Valid(LoValid), .ZeroCnt(LoCnt));
    assign Valid   = HiValid | LoValid;
    assign ZeroCnt = HiValid ? {1'b0, HiCnt} : {1'b1, LoCnt};
  end
endmodule
