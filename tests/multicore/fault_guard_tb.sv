// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module fault_guard_tb;
    logic clk = 0, reset = 1, GlobalError = 1;
    logic [2:0] HartError = '1;
    always #5 clk = ~clk;
    bus_fault_guard #(.NCORES(3)) guard(.*);
    initial begin
        // Errors during reset are ignored; execution errors must stop the run.
        repeat (2) @(negedge clk);
        GlobalError = 0; HartError = '0; reset = 0;
        @(negedge clk);
        if ($test$plusargs("BAD_GLOBAL")) GlobalError = 1;
        if ($test$plusargs("BAD_HART")) HartError = 3'b100;
        repeat (2) @(negedge clk);
        $display("PASS: full-core fault guard, reset and fault-free execution");
        $finish;
    end
endmodule
