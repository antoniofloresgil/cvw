// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Current full-core execution is qualified only for fault-free bus operation.
// This guard is not an architectural trap implementation or transport VIP.
module bus_fault_guard #(parameter int NCORES = 1) (
  input logic clk, reset,
  input logic GlobalError,
  input logic [NCORES-1:0] HartError
);
  always_ff @(posedge clk) begin
    if (!reset)
      assert (!GlobalError && !(|HartError))
        else $fatal(1, "Full-core execution requires fault-free bus: HRESP recovery is transport-only");
  end
endmodule
