// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module soc_tb import cvw::*; #(
    parameter int NCORES = 2,
    parameter int LATENCY = 0,
    parameter bit SHARED_CACHE = 0
);
    `include "parameter-defs.vh"
    function automatic cvw_t testconfig();
        cvw_t c = P;
        c.RAM_LATENCY = LATENCY;
        return c;
    endfunction
    localparam cvw_t TEST_P = testconfig();
    logic clk = 0;
    logic reset_ext = 1;
    logic reset;
    string image, suite;
    always #5 clk = ~clk;
    wallypipelinedsoc #(.P(TEST_P), .NCORES(NCORES), .SHARED_CACHE(SHARED_CACHE)) dut(
        .clk, .reset_ext, .reset, .ExternalStall(1'b0),
        .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(),
        .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(),
        .HBURST(), .HPROT(), .HTRANS(), .HMASTLOCK(), .HREADY(),
        .TIMECLK(1'b0), .GPIOIN('0), .GPIOOUT(), .GPIOEN(), .UARTSin(1'b1), .UARTSout(),
        .SPIIn(1'b0), .SPIOut(), .SPICS(), .SPICLK(), .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO());
    integer UARTWrites = 0;
    always @(posedge clk) begin
        if (!reset && dut.uncoregen.uncore.PSEL[3] && dut.uncoregen.uncore.PWRITE &&
            dut.uncoregen.uncore.PENABLE && dut.uncoregen.uncore.PREADY[3] &&
            dut.uncoregen.uncore.PADDR[2:0] == 0 && !dut.uncoregen.uncore.uartgen.uart.uartPC.DLAB) begin
            UARTWrites = UARTWrites + 1;
            if (suite == "uart") $display("UART write %0d: %h", UARTWrites, dut.uncoregen.uncore.PWDATA[7:0]);
        end
    end
    initial begin
        if (!$value$plusargs("image=%s", image)) $fatal(1, "Missing +image=...");
        if (!$value$plusargs("suite=%s", suite)) suite = "smoke";
        $readmemh(image, dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
        repeat (5) @(negedge clk);
        reset_ext = 0;
        for (int cycle = 0; cycle < 100000; cycle++) begin
            bit complete;
            @(negedge clk);
            complete = 1;
            for (int h = 0; h < NCORES; h++) begin
                if (dut.uncoregen.uncore.ram.ram.memory.ram.RAM['h1003+8*h] == 'hdead)
                    $fatal(1, "Hart %0d failed: phase=%0d mcause=%h", h,
                        dut.uncoregen.uncore.ram.ram.memory.ram.RAM['h1001+8*h],
                        dut.uncoregen.uncore.ram.ram.memory.ram.RAM['h1005+8*h]);
                if (dut.uncoregen.uncore.ram.ram.memory.ram.RAM['h1003+8*h] != 1) complete = 0;
            end
            if (complete) begin
                if (suite == "uart") assert (UARTWrites == 4) else $fatal(1, "Expected four UART writes, got %0d", UARTWrites);
                $display("PASS: %s, %0d harts, RAM latency %0d (%0d cycles)", suite, NCORES, LATENCY, cycle);
                $finish;
            end
        end
        $fatal(1, "Multicore smoke test timed out");
    end
endmodule
