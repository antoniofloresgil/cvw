///////////////////////////////////////////
// extbussplit.sv
//
// Purpose: Split Wally's external bus region (HSELEXT) into two windows for the
//          open-source FPGA flow: the DDR3 data path (low half) and the LiteDRAM
//          control/status registers (CSRs, high half), and merge the two
//          AHB responses back into one.  Wally's own RTL only knows one external
//          region; this module lives in the FPGA top so the core is not touched.
//
//          The window is selected by address bit SPLIT_BIT.  Each side is an
//          ahbwishbonebridge, which returns HREADYOUT = 1 while it is not
//          selected, so the merged HREADY is the AND of the two and the data
//          comes from the side that was selected in the address phase.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module extbussplit #(
  parameter DATA_WIDTH = 32
) (
  input  logic                  HCLK, HRESETn,
  // Address phase from the core
  input  logic                  HSELEXT,       // address is in the external region
  input  logic                  SelCtrl,       // address bit that picks the CSR window
  input  logic                  HREADY,
  input  logic [1:0]            HTRANS,
  // Selects for the two bridges
  output logic                  HSELDDR, HSELCtrl,
  // Responses from the two bridges
  input  logic [DATA_WIDTH-1:0] HRDATADDR, HRDATACtrl,
  input  logic                  HREADYDDR, HREADYCtrl,
  input  logic                  HRESPDDR, HRESPCtrl,
  // Merged response to the core
  output logic [DATA_WIDTH-1:0] HRDATAEXT,
  output logic                  HREADYEXT,
  output logic                  HRESPEXT
);

  assign HSELDDR  = HSELEXT & ~SelCtrl;
  assign HSELCtrl = HSELEXT &  SelCtrl;

  // Which side owns the data phase: captured with the address phase, like the
  // bridges do.
  logic CtrlD;
  always_ff @(posedge HCLK or negedge HRESETn)
    if (~HRESETn)                CtrlD <= 1'b0;
    else if (HREADY & HTRANS[1]) CtrlD <= HSELCtrl;

  assign HRDATAEXT = CtrlD ? HRDATACtrl : HRDATADDR;
  assign HRESPEXT  = CtrlD ? HRESPCtrl  : HRESPDDR;
  assign HREADYEXT = HREADYDDR & HREADYCtrl;
endmodule
