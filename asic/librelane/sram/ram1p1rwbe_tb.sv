// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Compares the ram1p1rwbe adapter, simulated with the IHP macro's behavioral model, with Wally's
// generic RAM under the same random stimulus.  Every word is written first, because the macro's
// model starts with X; after that dout must match on every cycle.

module ram1p1rwbe_tb;
  localparam DEPTH = 1024, WIDTH = 32, CYCLES = 200000;

  logic                     clk = 0;
  logic                     ce, we;
  logic [$clog2(DEPTH)-1:0] addr;
  logic [WIDTH-1:0]         din, dout, doutGeneric;
  logic [WIDTH/8-1:0]       bwe;
  int                       errors = 0, checks = 0;

  ram1p1rwbe         #(.DEPTH(DEPTH), .WIDTH(WIDTH)) dut(.clk, .ce, .addr, .din, .we, .bwe, .dout);
  ram1p1rwbe_generic #(.DEPTH(DEPTH), .WIDTH(WIDTH)) ref_(.clk, .ce, .addr, .din, .we, .bwe, .dout(doutGeneric));

  always #5 clk = ~clk;

  initial begin
    $display("dut uses the macro: %0d-bit bit mask", $bits(dut.ihp.BitWriteMask));  // fails to elaborate otherwise
    for (int i = 0; i < DEPTH; i++) begin
      ce = 1; we = 1; bwe = '1; addr = i; din = $urandom;
      @(posedge clk); #1;
    end
    for (int i = 0; i < CYCLES; i++) begin
      ce = ($urandom % 4) != 0; we = $urandom % 2; bwe = $urandom; addr = $urandom; din = $urandom;
      @(posedge clk); #1;
      checks++;
      if (dout !== doutGeneric) begin
        if (errors < 10) $display("cycle %0d: dout %h, generic %h", i, dout, doutGeneric);
        errors++;
      end
    end
    if (errors == 0) $display("PASS: %0d cycles, dout matches the generic RAM", checks);
    else             $display("FAIL: %0d of %0d cycles differ", errors, checks);
    $finish;
  end
endmodule
