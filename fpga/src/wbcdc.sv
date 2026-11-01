///////////////////////////////////////////
// wbcdc.sv
//
// Purpose: Wishbone clock-domain crossing for the open-source FPGA flow: Wally's
//          side of the LiteDRAM control bus (master clock) to the LiteDRAM
//          system clock (slave clock).  One transfer at a time with a toggle
//          handshake: the master side holds the request fields in registers
//          until the slave side's acknowledge comes back, so the multi-bit
//          fields are stable whenever the other side samples them.  Control
//          accesses are rare, so the few cycles of latency do not matter.  It
//          also works with the same clock on both sides.
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

module wbcdc #(
  parameter ADR_WIDTH = 30,
  parameter DATA_WIDTH = 32
) (
  // Master side (the AHB bridge)
  input  logic                    m_clk, m_rst,
  input  logic [ADR_WIDTH-1:0]    m_adr,
  input  logic [DATA_WIDTH-1:0]   m_dat_w,
  input  logic [DATA_WIDTH/8-1:0] m_sel,
  input  logic                    m_we, m_cyc, m_stb,
  output logic [DATA_WIDTH-1:0]   m_dat_r,
  output logic                    m_ack,
  // Slave side (LiteDRAM's control bus)
  input  logic                    s_clk, s_rst,
  output logic [ADR_WIDTH-1:0]    s_adr,
  output logic [DATA_WIDTH-1:0]   s_dat_w,
  output logic [DATA_WIDTH/8-1:0] s_sel,
  output logic                    s_we, s_cyc, s_stb,
  input  logic [DATA_WIDTH-1:0]   s_dat_r,
  input  logic                    s_ack
);

  // Master side: capture a request, toggle req, wait for the ack toggle.
  logic m_busy, m_req, s_ack_t;
  logic [2:0] m_ack_sync, s_req_sync;            // two synchronizer stages + previous value
  logic [DATA_WIDTH-1:0] s_dat_r_q;

  always_ff @(posedge m_clk)
    if (m_rst) begin
      m_busy <= 1'b0;
      m_req  <= 1'b0;
      m_ack  <= 1'b0;
      m_ack_sync <= '0;
    end else begin
      m_ack_sync <= {m_ack_sync[1:0], s_ack_t};
      m_ack <= 1'b0;
      if (!m_busy && m_cyc && m_stb && !m_ack) begin
        s_adr   <= m_adr;
        s_dat_w <= m_dat_w;
        s_sel   <= m_sel;
        s_we    <= m_we;
        m_req   <= ~m_req;
        m_busy  <= 1'b1;
      end else if (m_busy && (m_ack_sync[2] != m_ack_sync[1])) begin
        m_dat_r <= s_dat_r_q;
        m_ack   <= 1'b1;
        m_busy  <= 1'b0;
      end
    end

  // Slave side: a req toggle starts one Wishbone cycle; its ack toggles back.
  always_ff @(posedge s_clk)
    if (s_rst) begin
      s_req_sync <= '0;
      s_cyc      <= 1'b0;
      s_ack_t    <= 1'b0;
    end else begin
      s_req_sync <= {s_req_sync[1:0], m_req};
      if (!s_cyc && (s_req_sync[2] != s_req_sync[1])) s_cyc <= 1'b1;
      else if (s_cyc && s_ack) begin
        s_dat_r_q <= s_dat_r;
        s_cyc     <= 1'b0;
        s_ack_t   <= ~s_ack_t;
      end
    end
  assign s_stb = s_cyc;
endmodule
