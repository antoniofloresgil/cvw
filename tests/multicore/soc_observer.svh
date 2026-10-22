// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// SoC-specific passive observation boundary, including generated topology paths.
    localparam bit OBS_PRIVATE = PRIVATE_DCACHE && NCORES > 1;
    localparam OBS_BANKS = OBS_PRIVATE ? COHERENCE_BANKS : 1;
    // Inactive private options must not impose geometry on native/shared tests.
    localparam OBS_DC_WORDS = OBS_PRIVATE ? PRIVATE_DCACHE_WORDS : 2;
    localparam OBS_IC_WORDS = OBS_PRIVATE ? PRIVATE_ICACHE_WORDS : 2;
    localparam OBS_LINE_WORDS = OBS_PRIVATE ? PRIVATE_DCACHE_LINE_WORDS : 1;
    localparam OBS_DW = OBS_DC_WORDS/OBS_BANKS;
    localparam OBS_OFFSET = $clog2(P.AHBW/8);
    localparam OBS_LINE_OFFSET = OBS_OFFSET+$clog2(OBS_LINE_WORDS);
    localparam OBS_CI = $clog2(OBS_DW/OBS_LINE_WORDS);
    localparam OBS_TAG_BITS = P.PA_BITS-OBS_LINE_OFFSET-OBS_CI;
    logic [OBS_BANKS-1:0][NCORES-1:0][OBS_DW/OBS_LINE_WORDS-1:0][1:0] ObservedPermissions;
    logic [OBS_TAG_BITS-1:0] ObservedTags[OBS_BANKS][NCORES][OBS_DW/OBS_LINE_WORDS];
    logic [P.AHBW-1:0] ObservedLines[OBS_BANKS][NCORES][OBS_DW];
    if (OBS_PRIVATE) begin : private_view
        if (OBS_BANKS > 1) begin : banked
            for (genvar b = 0; b < OBS_BANKS; b++) begin : homes
                assign ObservedPermissions[b] = dut.memory_system.banked.fabric.banks[b].cache.observation.Permissions;
                assign ObservedTags[b] = dut.memory_system.banked.fabric.banks[b].cache.observation.Tags;
                assign ObservedLines[b] = dut.memory_system.banked.fabric.banks[b].cache.observation.Lines;
            end
        end else begin : single
            assign ObservedPermissions[0] = dut.memory_system.msicache.cache.observation.Permissions;
            assign ObservedTags[0] = dut.memory_system.msicache.cache.observation.Tags;
            assign ObservedLines[0] = dut.memory_system.msicache.cache.observation.Lines;
        end
    end else begin : memory_view
        assign ObservedPermissions = '0;
        always_comb begin
            foreach (ObservedTags[b,h,l]) ObservedTags[b][h][l] = '0;
            foreach (ObservedLines[b,h,w]) ObservedLines[b][h][w] = '0;
        end
    end
    multicore_word_observer #(.P(P), .PRIVATE(OBS_PRIVATE), .NCORES(NCORES), .BANKS(OBS_BANKS),
        .DCACHE_WORDS(OBS_DC_WORDS), .ICACHE_WORDS(OBS_IC_WORDS),
        .LINE_WORDS(OBS_LINE_WORDS)) observer(
        .Permissions(ObservedPermissions), .Tags(ObservedTags), .Lines(ObservedLines));
    function automatic logic [63:0] architectural_word(input int unsigned index);
        return 64'(observer.word(index, dut.uncoregen.uncore.ram.ram.memory.ram.RAM[index]));
    endfunction
    task automatic load_image(input string filename);
        $readmemh(filename, dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
    endtask
    integer UARTWrites = 0;
    int unsigned MemoryTransfers = 0, LocalCompletions = 0;
    always @(posedge clk) if (!reset && dut.HTRANS[1] && dut.HREADY)
        MemoryTransfers <= MemoryTransfers + 1;
    if (NCORES > 1 && PRIVATE_DCACHE && COHERENCE_BANKS > 1) begin : counters
        logic [COHERENCE_BANKS-1:0][31:0] Counts;
        for (genvar b = 0; b < COHERENCE_BANKS; b++) begin : banks
            assign Counts[b] = 32'($countones(dut.memory_system.banked.fabric.banks[b].bus.observation.LocalReply |
                dut.memory_system.banked.fabric.banks[b].bus.observation.LocalStoreCommitted));
        end
        always @(posedge clk) if (!reset)
            for (int b = 0; b < COHERENCE_BANKS; b++)
                LocalCompletions = LocalCompletions + Counts[b];
    end else if (NCORES > 1) begin : counters
        always @(posedge clk) if (!reset)
            LocalCompletions <= LocalCompletions + $countones(dut.memory_system.multicore.bus.observation.LocalReply | dut.memory_system.multicore.bus.observation.LocalStoreCommitted);
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
