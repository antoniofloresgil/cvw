// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module soc_tb import cvw::*; #(parameter int LATENCY = 0, `CVW_MULTICORE_PARAMS(AHBW)
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
    wallypipelinedsoc #(.P(TEST_P), `CVW_MULTICORE_CONNECT) dut(
        .clk, .reset_ext, .reset, .ExternalStall(1'b0),
        .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT(),
        .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(), .HWRITE(), .HSIZE(),
        .HBURST(), .HPROT(), .HTRANS(), .HMASTLOCK(), .HREADY(),
        .TIMECLK(1'b0), .GPIOIN('0), .GPIOOUT(), .GPIOEN(), .UARTSin(1'b1), .UARTSout(),
        .SPIIn(1'b0), .SPIOut(), .SPICS(), .SPICLK(), .SDCIn(1'b0), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO());
    bus_fault_guard #(.NCORES(NCORES)) fault_guard(
        .clk, .reset, .GlobalError(dut.HRESP), .HartError(dut.CoreHRESP));
    // White-box architectural observer: write-back data may be newer than RAM.
    // This does not flush caches or participate in the coherence protocol.
    if (PRIVATE_DCACHE && NCORES > 1 && COHERENCE_BANKS > 1) begin : observer
        localparam DW = PRIVATE_DCACHE_WORDS/COHERENCE_BANKS;
        localparam IW = PRIVATE_ICACHE_WORDS/COHERENCE_BANKS;
        localparam OFFSET = $clog2(P.XLEN/8);
        localparam LINE_OFFSET = OFFSET + $clog2(PRIVATE_DCACHE_LINE_WORDS);
        localparam CI = $clog2(DW/PRIVATE_DCACHE_LINE_WORDS);
        localparam DI = $clog2(DW);
        localparam HO = OFFSET + $clog2(DW > IW ? DW : IW);
        logic [NCORES-1:0][DW/PRIVATE_DCACHE_LINE_WORDS-1:0][1:0] States[COHERENCE_BANKS];
        logic [P.PA_BITS-LINE_OFFSET-CI-1:0] Tags[COHERENCE_BANKS][NCORES][DW/PRIVATE_DCACHE_LINE_WORDS];
        logic [P.AHBW-1:0] Lines[COHERENCE_BANKS][NCORES][DW];
        for (genvar b = 0; b < COHERENCE_BANKS; b++) begin : shadows
            assign States[b] = dut.memory_system.banked.fabric.banks[b].cache.States;
            assign Tags[b] = dut.memory_system.banked.fabric.banks[b].cache.Tags;
            assign Lines[b] = dut.memory_system.banked.fabric.banks[b].cache.Lines;
        end
        function automatic logic [63:0] word(input int unsigned index);
            logic [P.PA_BITS-1:0] address;
            int b;
            address = P.PA_BITS'(P.UNCORE_RAM_BASE) + (P.PA_BITS'(index) << OFFSET);
            b = int'((address >> HO) & P.PA_BITS'(int'(COHERENCE_BANKS-1)));
            word = dut.uncoregen.uncore.ram.ram.memory.ram.RAM[index];
            for (int h = 0; h < NCORES; h++)
                if (States[b][h][address[LINE_OFFSET +: CI]] == 2 &&
                    Tags[b][h][address[LINE_OFFSET +: CI]] == address[P.PA_BITS-1:LINE_OFFSET+CI])
                    word = Lines[b][h][address[OFFSET +: DI]];
        endfunction
    end else if (PRIVATE_DCACHE && NCORES > 1) begin : observer
        function automatic logic [63:0] word(input int unsigned index);
            localparam OFFSET = $clog2(P.XLEN/8);
            localparam LINE_OFFSET = OFFSET + $clog2(PRIVATE_DCACHE_LINE_WORDS);
            localparam CACHE_INDEX = $clog2(PRIVATE_DCACHE_WORDS/PRIVATE_DCACHE_LINE_WORDS);
            localparam DATA_INDEX = $clog2(PRIVATE_DCACHE_WORDS);
            logic [P.PA_BITS-1:0] address;
            logic [CACHE_INDEX-1:0] cache_index;
            address = P.PA_BITS'(P.UNCORE_RAM_BASE) + (P.PA_BITS'(index) << OFFSET);
            cache_index = address[LINE_OFFSET +: CACHE_INDEX];
            word = dut.uncoregen.uncore.ram.ram.memory.ram.RAM[index];
            for (int h = 0; h < NCORES; h++)
                if (dut.memory_system.msicache.cache.States[h][cache_index] == 2 &&
                    dut.memory_system.msicache.cache.Tags[h][cache_index] == address[P.PA_BITS-1:LINE_OFFSET+CACHE_INDEX])
                    word = dut.memory_system.msicache.cache.Lines[h][address[OFFSET +: DATA_INDEX]];
        endfunction
    end else begin : observer
        function automatic logic [63:0] word(input int unsigned index);
            word = dut.uncoregen.uncore.ram.ram.memory.ram.RAM[index];
        endfunction
    end
    integer UARTWrites = 0;
    int unsigned MemoryTransfers = 0, LocalCompletions = 0;
    always @(posedge clk) if (!reset && dut.HTRANS[1] && dut.HREADY)
        MemoryTransfers <= MemoryTransfers + 1;
    if (NCORES > 1 && PRIVATE_DCACHE && COHERENCE_BANKS > 1) begin : counters
        logic [COHERENCE_BANKS-1:0][31:0] Counts;
        for (genvar b = 0; b < COHERENCE_BANKS; b++) begin : banks
            assign Counts[b] = 32'($countones(dut.memory_system.banked.fabric.banks[b].bus.LocalReply |
                dut.memory_system.banked.fabric.banks[b].bus.CacheWriteCommit));
        end
        always @(posedge clk) if (!reset)
            for (int b = 0; b < COHERENCE_BANKS; b++)
                LocalCompletions = LocalCompletions + Counts[b];
    end else if (NCORES > 1) begin : counters
        always @(posedge clk) if (!reset)
            LocalCompletions <= LocalCompletions + $countones(dut.memory_system.multicore.bus.LocalReply | dut.memory_system.multicore.bus.CacheWriteCommit);
    end else begin : counters
        assign LocalCompletions = 0;
    end
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
                if (observer.word('h1003+8*h) == 'hdead)
                    $fatal(1, "Hart %0d failed: phase=%0d mcause=%h", h,
                        observer.word('h1001+8*h),
                        observer.word('h1005+8*h));
                if (observer.word('h1003+8*h) != 1) complete = 0;
            end
            if (complete) begin
                if (suite == "uart") assert (UARTWrites == 4) else $fatal(1, "Expected four UART writes, got %0d", UARTWrites);
                $display("TRAFFIC: memory=%0d local=%0d", MemoryTransfers, LocalCompletions);
                $display("PASS: %s, %0d harts, RAM latency %0d (%0d cycles)", suite, NCORES, LATENCY, cycle);
                $finish;
            end
        end
        $fatal(1, "Multicore smoke test timed out");
    end
endmodule
