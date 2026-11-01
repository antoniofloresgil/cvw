///////////////////////////////////////////
// tb_wbcdc.sv
//
// Purpose: Self-checking test of wbcdc, the Wishbone clock-domain crossing for
//          the LiteDRAM control bus: back-to-back writes and read-backs from a
//          master clock to a slave clock with a 2-cycle register slave.  Run it
//          with SAME_CLK=0 (80 ns master, 25 ns slave, as Wally at 12.5 MHz and
//          LiteDRAM at 40 MHz) and SAME_CLK=1 (one clock, as on RV32).
//
// Run:     verilator --binary --timing --Wno-fatal -GSAME_CLK=0 -Mdir <dir> \
//            --top-module tb_wbcdc tests/fpga/tb_wbcdc.sv fpga/src/wbcdc.sv
//          <dir>/Vtb_wbcdc
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module tb_wbcdc #(parameter SAME_CLK = 0);
  logic m_clk = 0, s_clk_own = 0, s_clk, rst = 1;
  always #40 m_clk = ~m_clk;
  always #12.5 s_clk_own = ~s_clk_own;
  assign s_clk = SAME_CLK ? m_clk : s_clk_own;

  logic [29:0] m_adr, s_adr;
  logic [31:0] m_dat_w, m_dat_r, s_dat_w, s_dat_r;
  logic [3:0]  m_sel, s_sel;
  logic        m_we, m_cyc, m_stb, m_ack, s_we, s_cyc, s_stb, s_ack;

  wbcdc #(.ADR_WIDTH(30), .DATA_WIDTH(32)) dut (
    .m_clk, .m_rst(rst), .m_adr, .m_dat_w, .m_sel, .m_we, .m_cyc, .m_stb, .m_dat_r, .m_ack,
    .s_clk, .s_rst(rst), .s_adr, .s_dat_w, .s_sel, .s_we, .s_cyc, .s_stb, .s_dat_r, .s_ack
  );

  // Slave: 16 registers, ack one cycle after the request, one cycle long.
  logic [31:0] regs [16];
  int writes = 0, reads = 0;
  always_ff @(posedge s_clk) begin
    s_ack <= 1'b0;
    if (s_cyc & s_stb & ~s_ack) begin
      s_ack <= 1'b1;
      if (s_we) begin
        for (int b = 0; b < 4; b++) if (s_sel[b]) regs[s_adr[3:0]][8*b +: 8] <= s_dat_w[8*b +: 8];
        writes <= writes + 1;
      end else begin
        s_dat_r <= regs[s_adr[3:0]];
        reads <= reads + 1;
      end
    end
  end

  // Master: like ahbwishbonebridge, it keeps cyc and the fields of a transfer
  // through the cycle in which m_ack is high, and a back-to-back transfer
  // presents its new fields from the next cycle.
  localparam N = 17;
  logic        tw [N];
  logic [29:0] ta [N];
  logic [31:0] td [N], te [N];
  logic [3:0]  ts [N];
  int idx = 0, errors = 0;
  bit go = 0, done = 0;
  always_ff @(posedge m_clk)
    if (rst || !go) m_cyc <= 1'b0;
    else if (!done) begin
      if (!m_cyc) begin
        m_cyc <= 1'b1; m_we <= tw[idx]; m_adr <= ta[idx]; m_dat_w <= td[idx]; m_sel <= ts[idx];
      end else if (m_ack) begin
        if (!tw[idx] && m_dat_r !== te[idx]) begin
          $display("FAIL: reg %0d read %h expected %h", ta[idx], m_dat_r, te[idx]);
          errors++;
        end
        if (idx + 1 < N) begin
          m_we <= tw[idx+1]; m_adr <= ta[idx+1]; m_dat_w <= td[idx+1]; m_sel <= ts[idx+1];
        end else begin
          m_cyc <= 1'b0; done = 1;
        end
        idx++;
      end
    end
  assign m_stb = m_cyc;

  initial begin
    for (int i = 0; i < 16; i++) regs[i] = 32'h0;
    for (int i = 0; i < 8; i++) begin
      tw[i] = 1; ta[i] = 30'(i); td[i] = 32'hA5000000 + i * 32'h01010101; ts[i] = 4'hF; te[i] = 'x;
    end
    tw[8] = 1; ta[8] = 30'd3; td[8] = 32'h000000EE; ts[8] = 4'h1; te[8] = 'x;   // byte write
    for (int i = 0; i < 8; i++) begin
      tw[9+i] = 0; ta[9+i] = 30'(i); td[9+i] = 'x; ts[9+i] = 4'hF;
      te[9+i] = 32'hA5000000 + i * 32'h01010101;
      if (i == 3) te[9+i][7:0] = 8'hEE;
    end
    repeat (3) @(posedge m_clk);
    rst = 0;
    repeat (2) @(posedge m_clk);
    @(negedge m_clk) go = 1;
    wait (done);
    repeat (8) @(posedge m_clk);
    if (writes != 9 || reads != 8) begin
      $display("FAIL: slave saw %0d writes and %0d reads, expected 9 and 8", writes, reads);
      errors++;
    end
    if (errors == 0) $display("PASS: SAME_CLK=%0d, 9 writes and 8 reads crossed", SAME_CLK);
    else $display("FAIL: %0d errors", errors);
    $finish;
  end
  initial begin #200000; $display("FAIL: timeout"); $finish; end
endmodule
