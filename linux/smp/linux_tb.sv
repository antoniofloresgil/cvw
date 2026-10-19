// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module linux_tb import cvw::*; #(
    parameter int NCORES = 2,
    parameter int CACHE_WORDS = 256,
    parameter bit PRIVATE_DCACHE = 0,
    parameter bit PRIVATE_ICACHE = 0,
    parameter int ICACHE_WORDS = 256,
    parameter bit LOCAL_DCACHE_READS = 0,
    parameter bit LOCAL_DCACHE_WRITES = 0
)(
    input logic clk, reset_ext,
    output logic ConsoleValid,
    output logic [7:0] ConsoleData,
    output logic [NCORES-1:0][63:0] PCs,
    output logic [NCORES-1:0][63:0] Causes
);
    `include "parameter-defs.vh"
    string ram_image, rom_image;
    wallypipelinedsoc #(.P(P), .NCORES(NCORES), .SHARED_CACHE(!PRIVATE_DCACHE), .SHARED_CACHE_WORDS(CACHE_WORDS),
        .PRIVATE_DCACHE(PRIVATE_DCACHE), .PRIVATE_DCACHE_WORDS(CACHE_WORDS),
        .PRIVATE_ICACHE(PRIVATE_ICACHE), .PRIVATE_ICACHE_WORDS(ICACHE_WORDS),
        .LOCAL_DCACHE_READS(LOCAL_DCACHE_READS), .LOCAL_DCACHE_WRITES(LOCAL_DCACHE_WRITES)) dut(
        .clk, .reset_ext, .reset(), .ExternalStall(1'b0),
        .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(),
        .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(),
        .HBURST(), .HPROT(), .HTRANS(), .HMASTLOCK(), .HREADY(),
        .TIMECLK(1'b0), .GPIOIN('0), .GPIOOUT(), .GPIOEN(), .UARTSin(1'b1), .UARTSout(),
        .SPIIn(1'b0), .SPIOut(), .SPICS(), .SPICLK(), .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO());
    // Observe actual UART transmit-register writes. The real UART remains in
    // circuit, including its busy/ready timing and interrupt generation.
    assign ConsoleValid = dut.uncoregen.uncore.PSEL[3] && dut.uncoregen.uncore.PWRITE &&
        dut.uncoregen.uncore.PENABLE && dut.uncoregen.uncore.PREADY[3] &&
        dut.uncoregen.uncore.PADDR[2:0] == 0 && !dut.uncoregen.uncore.uartgen.uart.uartPC.DLAB;
    assign ConsoleData = dut.uncoregen.uncore.PWDATA[7:0];
    assign PCs[0] = dut.core.ifu.PCF;
    assign Causes[0] = dut.core.priv.priv.csr.csrm.MCAUSE_REGW;
    for (genvar h = 1; h < NCORES; h++) begin : probes
        assign PCs[h] = dut.harts[h].core.ifu.PCF;
        assign Causes[h] = dut.harts[h].core.priv.priv.csr.csrm.MCAUSE_REGW;
    end
    initial begin
        if (!$value$plusargs("ram=%s", ram_image) || !$value$plusargs("rom=%s", rom_image))
            $fatal(1, "Specify +ram=... +rom=...");
        $readmemh(ram_image, dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
        $readmemh(rom_image, dut.uncoregen.uncore.bootrom.bootrom.memory.ROM);
    end
endmodule
