///////////////////////////////////////////
// ram2p2rwbe.sv
//
// True dual-port RAM: two read/write ports with byte write enables and registered, read-first outputs, one clock.
// Written after the block-RAM templates of Vivado (UG901, byte-write true dual port, read first), so it maps to
// RAMB36/RAMB18; a read and a write of one address through different ports in the same cycle return undefined data
// on the reading port in hardware, so callers must not rely on that read.
//
// Purpose: storage of the multicore private data caches (src/ebu/multicore_dcache_data.sv)
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwgroup/cvw
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

module ram2p2rwbe #(parameter DEPTH = 256, WIDTH = 64) (
  input  logic                     clk,
  input  logic                     ce1, we1,
  input  logic [$clog2(DEPTH)-1:0] a1,
  input  logic [WIDTH/8-1:0]       bwe1,
  input  logic [WIDTH-1:0]         wd1,
  output logic [WIDTH-1:0]         rd1,
  input  logic                     ce2, we2,
  input  logic [$clog2(DEPTH)-1:0] a2,
  input  logic [WIDTH/8-1:0]       bwe2,
  input  logic [WIDTH-1:0]         wd2,
  output logic [WIDTH-1:0]         rd2
);
  logic [WIDTH-1:0] RAM[DEPTH-1:0];

  // verilator lint_off MULTIDRIVEN
  always_ff @(posedge clk)
    if (ce1) begin
      rd1 <= RAM[a1];
      if (we1)
        for (int i = 0; i < WIDTH/8; i++)
          if (bwe1[i]) RAM[a1][i*8 +: 8] <= wd1[i*8 +: 8];
    end

  always_ff @(posedge clk)
    if (ce2) begin
      rd2 <= RAM[a2];
      if (we2)
        for (int i = 0; i < WIDTH/8; i++)
          if (bwe2[i]) RAM[a2][i*8 +: 8] <= wd2[i*8 +: 8];
    end
  // verilator lint_on MULTIDRIVEN

  initial assert (WIDTH % 8 == 0 && DEPTH >= 2 && (DEPTH & (DEPTH-1)) == 0)
    else $fatal(1, "ram2p2rwbe: WIDTH must be whole bytes and DEPTH a power of two");
endmodule
