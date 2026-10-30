///////////////////////////////////////////
// ahbwishbonebridge.sv
//
// Written: CORE-V-Wally contributors
//
// Purpose: Bridge an AHB-Lite slave interface to a Wishbone master interface.
//          Used by the open-source FPGA flow to connect Wally's external memory
//          bus to the LiteDRAM DDR3 controller, which exposes a Wishbone slave.
//
//          Each AHB transfer, including every beat of a cache-line burst, becomes
//          one Wishbone transaction: the bridge holds HREADYOUT low until the
//          Wishbone ack, so the next beat's address phase is captured only then.
//          Byte enables are taken from HWSTRB.
//
// Documentation: RISC-V System on Chip Design
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
// https://solderpad.org/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module ahbwishbonebridge #(
  parameter ADDR_WIDTH = 32,                    // AHB byte-address width of the bridged region
  parameter DATA_WIDTH = 32                     // AHB / Wishbone data width
) (
  input  logic                    HCLK, HRESETn,
  input  logic                    HSEL,         // AHB select for the bridged region (combinational, valid in address phase)
  input  logic [ADDR_WIDTH-1:0]   HADDR,
  input  logic [1:0]              HTRANS,
  input  logic                    HWRITE,
  input  logic [DATA_WIDTH-1:0]   HWDATA,
  input  logic [DATA_WIDTH/8-1:0] HWSTRB,
  input  logic                    HREADY,
  output logic                    HREADYOUT,
  output logic [DATA_WIDTH-1:0]   HRDATA,
  output logic                    HRESP,
  // Wishbone master
  output logic [ADDR_WIDTH-$clog2(DATA_WIDTH/8)-1:0] wb_adr, // word address
  output logic [DATA_WIDTH-1:0]   wb_dat_w,
  output logic [DATA_WIDTH/8-1:0] wb_sel,
  output logic                    wb_we,
  output logic                    wb_cyc, wb_stb,
  input  logic [DATA_WIDTH-1:0]   wb_dat_r,
  input  logic                    wb_ack
);

  typedef enum logic {BUS_IDLE, BUS_DATA} busstatetype;
  busstatetype CurrState, NextState;

  localparam OFFSET_BITS = $clog2(DATA_WIDTH/8);

  logic                            writeD, selD;
  logic [ADDR_WIDTH-OFFSET_BITS-1:0] addrD;

  // Start of an AHB transaction (address phase).
  logic initTrans;
  assign initTrans = HREADY & HTRANS[1];

  // Capture the address phase.  HSEL is the combinational region select (valid
  // in the address phase); it is registered so that HREADYOUT and the Wishbone
  // request do not depend combinationally on the address decoder, which would
  // create a loop through the core's HTRANS/HSIZE logic.  HWDATA and HWSTRB are
  // driven by the master in the data phase, so they are used directly while the
  // Wishbone request is asserted.
  always_ff @(posedge HCLK or negedge HRESETn)
    if (~HRESETn) begin
      writeD <= 1'b0;
      selD   <= 1'b0;
      addrD  <= '0;
    end else if (initTrans) begin
      writeD <= HWRITE;
      selD   <= HSEL;
      addrD  <= HADDR[ADDR_WIDTH-1:OFFSET_BITS];
    end

  // Wishbone master
  assign wb_cyc   = (CurrState == BUS_DATA) & selD;
  assign wb_stb   = wb_cyc;
  assign wb_we    = writeD;
  assign wb_adr   = addrD;
  assign wb_dat_w = HWDATA;
  assign wb_sel   = HWSTRB;

  // AHB response.  HRESP is always OKAY; the bridge inserts wait states until
  // the Wishbone transaction is acknowledged.
  assign HREADYOUT = (CurrState == BUS_IDLE) | ~selD | wb_ack;
  assign HRDATA    = wb_dat_r;
  assign HRESP     = 1'b0;

  // FSM
  always_comb begin
    case (CurrState)
      BUS_IDLE: NextState = initTrans           ? BUS_DATA : BUS_IDLE;
      // A transfer whose address phase coincides with the end of this one
      // (the next beat of a burst) starts its Wishbone request right away.
      BUS_DATA: NextState = (~selD | wb_ack)    ? (initTrans ? BUS_DATA : BUS_IDLE) : BUS_DATA;
      default:  NextState = BUS_IDLE;
    endcase
  end

  always_ff @(posedge HCLK or negedge HRESETn)
    if (~HRESETn) CurrState <= BUS_IDLE;
    else          CurrState <= NextState;

endmodule
