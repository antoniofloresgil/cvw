// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module pmu_tb import cvw::*; (
    input logic clk, reset_ext,
    output logic ConsoleValid,
    output logic [7:0] ConsoleData,
    output logic [63:0] PCs, Causes
);
    `include "parameter-defs.vh"
    string ram_image, rom_image;
    wallypipelinedsoc #(.P(P)) dut(
        .clk, .reset_ext, .reset(), .ExternalStall(1'b0),
        .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(),
        .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(),
        .HBURST(), .HPROT(), .HTRANS(), .HMASTLOCK(), .HREADY(),
        .TIMECLK(1'b0), .GPIOIN('0), .GPIOOUT(), .GPIOEN(), .UARTSin(1'b1), .UARTSout(),
        .SPIIn(1'b0), .SPIOut(), .SPICS(), .SPICLK(), .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO());
    assign ConsoleValid = dut.uncoregen.uncore.PSEL[3] && dut.uncoregen.uncore.PWRITE &&
        dut.uncoregen.uncore.PENABLE && dut.uncoregen.uncore.PREADY[3] &&
        dut.uncoregen.uncore.PADDR[2:0] == 0 && !dut.uncoregen.uncore.uartgen.uart.uartPC.DLAB;
    assign ConsoleData = dut.uncoregen.uncore.PWDATA[7:0];
    assign PCs = dut.core.ifu.PCF;
    assign Causes = dut.core.priv.priv.csr.csrm.MCAUSE_REGW;
    initial begin
        if (!$value$plusargs("ram=%s", ram_image) || !$value$plusargs("rom=%s", rom_image))
            $fatal(1, "Specify +ram=... +rom=...");
        $readmemh(ram_image, dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
        $readmemh(rom_image, dut.uncoregen.uncore.bootrom.bootrom.memory.ROM);
    end
endmodule
