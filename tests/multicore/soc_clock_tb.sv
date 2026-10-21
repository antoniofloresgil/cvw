// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module soc_clock_tb import cvw::*;();
    `include "parameter-defs.vh"
    logic clk = 0, reset_ext = 1;
    always #5 clk = ~clk;
    function automatic cvw_t busconfig(input bit enabled);
        cvw_t c = P;
        c.BUS_SUPPORTED = enabled;
        return c;
    endfunction
    for (genvar b = 0; b < 2; b++) begin : cases
        localparam cvw_t BP = busconfig(b != 0);
        logic reset, hclk, hresetn;
        wallypipelinedsoc #(.P(BP)) dut(
            .clk, .reset_ext, .reset, .ExternalStall(1'b0),
            .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(),
            .HCLK(hclk), .HRESETn(hresetn), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(),
            .HBURST(), .HPROT(), .HTRANS(), .HMASTLOCK(), .HREADY(),
            .TIMECLK(1'b0), .GPIOIN('0), .GPIOOUT(), .GPIOEN(), .UARTSin(1'b1), .UARTSout(),
            .SPIIn(1'b0), .SPIOut(), .SPICS(), .SPICLK(), .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO());
        // Sample both clock edges, while reset is asserted and after release.
        always @(clk) begin
            #1;
            assert (hclk == (b != 0 ? clk : 1'b0) && hresetn == (b != 0 ? ~reset : 1'b0))
                else $fatal(1, "Clock/reset compatibility failed for BUS_SUPPORTED=%0d", b);
        end
    end
    initial begin
        repeat (4) @(negedge clk);
        reset_ext = 0;
        repeat (12) @(negedge clk);
        $display("PASS: RV%0d SoC clocks/reset with bus enabled and disabled", P.XLEN);
        $finish;
    end
endmodule
