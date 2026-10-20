// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Full arbiter/MSI path, RV32/RV64, waits/errors and a software reference model.
`include "config.vh"
module msi_tb import cvw::*; #(
    parameter int NCORES = 2,
    parameter int LATENCY = 3,
    parameter int WORDS = 4,
    parameter int LINE_WORDS = 1,
    parameter int ICACHE_LINE_WORDS = 1,
    parameter bit PRIVATE_ICACHE = 0,
    parameter int ICACHE_WORDS = 4,
    parameter bit LOCAL_DCACHE_READS = 0,
    parameter bit LOCAL_DCACHE_WRITES = 0
);
    `include "parameter-defs.vh"
    localparam OFFSET = $clog2(P.XLEN/8);
    localparam INDEX = $clog2(WORDS/LINE_WORDS);
    localparam HART_BITS = $clog2(NCORES);
    localparam CONFLICT_OFFSET = OFFSET + $clog2(LINE_WORDS > ICACHE_LINE_WORDS ? LINE_WORDS : ICACHE_LINE_WORDS);
    localparam logic [P.PA_BITS-1:0] BASE = P.PA_BITS'(P.UNCORE_RAM_BASE);
    logic HCLK = 0, HRESETn = 0;
    always #5 HCLK = ~HCLK;
    logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR = '0;
    logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA = '0, CoreHRDATA;
    logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB = '0;
    logic [NCORES-1:0] CoreHWRITE = '0, CoreHMASTLOCK = '0, CoreHREADY, CoreHRESP, CoreSCFail;
    logic [NCORES-1:0][2:0] CoreHSIZE = '0, CoreHBURST = '0;
    logic [NCORES-1:0][3:0] CoreHPROT = '0;
    logic [NCORES-1:0][1:0] CoreHTRANS = '0, CoreHATOMIC = '0;
    logic [HART_BITS-1:0] HOWNER;
    logic [P.PA_BITS-1:0] HADDR, downaddr;
    logic [P.AHBW-1:0] HWDATA, HRDATA, downwdata, downrdata;
    logic [P.XLEN/8-1:0] HWSTRB, downstrb;
    logic HWRITE, HMASTLOCK, HREADY, HRESP, downwrite, downlock, downready, downresp;
    logic [2:0] HSIZE, HBURST, downsize, downburst;
    logic [3:0] HPROT, downprot;
    logic [1:0] HTRANS, downtrans;
    logic [NCORES-1:0][P.PA_BITS-1:0] CacheReadAddr;
    logic [NCORES-1:0][P.AHBW-1:0] CacheReadData;
    logic [NCORES-1:0] CacheReadHit, CacheWriteHit, CacheWriteCommit;
    logic [NCORES-1:0][P.AHBW-1:0] CacheWriteData;
    logic [NCORES-1:0][P.XLEN/8-1:0] CacheWriteStrb;
    ahbmulticore #(.P(P), .NCORES(NCORES), .PRIVATE_ICACHE(PRIVATE_ICACHE),
        .ICACHE_WORDS(ICACHE_WORDS), .ICACHE_LINE_WORDS(ICACHE_LINE_WORDS), .DCACHE_LINE_WORDS(LINE_WORDS), .LOCAL_DCACHE_READS(LOCAL_DCACHE_READS), .LOCAL_DCACHE_WRITES(LOCAL_DCACHE_WRITES)) bus(.*);
    ahbmsicache #(.P(P), .NCORES(NCORES), .WORDS(WORDS), .LINE_WORDS(LINE_WORDS), .LOCAL_READS(LOCAL_DCACHE_READS), .LOCAL_WRITES(LOCAL_DCACHE_WRITES)) cache(
        .CacheReadAddr, .CacheReadHit, .CacheReadData,
        .CacheWriteHit, .CacheWriteCommit, .CacheWriteData, .CacheWriteStrb,
        .HCLK, .HRESETn, .UpHOWNER(HOWNER), .UpHADDR(HADDR), .UpHWDATA(HWDATA), .UpHWSTRB(HWSTRB),
        .UpHWRITE(HWRITE), .UpHMASTLOCK(HMASTLOCK), .UpHSIZE(HSIZE), .UpHBURST(HBURST),
        .UpHPROT(HPROT), .UpHTRANS(HTRANS), .UpHRDATA(HRDATA), .UpHREADY(HREADY), .UpHRESP(HRESP),
        .HADDR(downaddr), .HWDATA(downwdata), .HWSTRB(downstrb), .HWRITE(downwrite), .HMASTLOCK(downlock),
        .HSIZE(downsize), .HBURST(downburst), .HPROT(downprot), .HTRANS(downtrans),
        .HRDATA(downrdata), .HREADY(downready), .HRESP(downresp));
    logic [P.XLEN-1:0] mem[4096], reference[4096];
    logic pending = 0, writeq, errorq, error_first = 0;
    logic fault_read = 0, fault_write = 0;
    logic [P.PA_BITS-1:0] fault_addr = '1, addrq;
    int delayq = 0, transfers = 0, writebacks = 0, snapshot, mmio = 0;
    int local_stores = 0, parallel_stores = 0, stores_during_bus = 0, parallel_stores_during_bus = 0;
    int stores_at_lr_reply = 0, stores_at_ifill_reply = 0, global_requests = 0;
    always @(posedge HCLK) if (HRESETn) begin
        local_stores <= local_stores + $countones(CacheWriteCommit);
        if ($countones(CacheWriteCommit) > 1) parallel_stores <= parallel_stores + 1;
        if (HTRANS[1] && HREADY) global_requests <= global_requests + 1;
        if (|CacheWriteCommit) begin
            assert (!bus.LockActive) else $fatal(1, "Local M store bypassed AMO lock");
            if (bus.DataPhase || bus.IFillActive) begin
                if ($countones(CacheWriteCommit) > 1) parallel_stores_during_bus <= parallel_stores_during_bus + 1;
                stores_during_bus <= stores_during_bus + 1;
                for (int h = 0; h < NCORES; h++) if (CacheWriteCommit[h])
                    assert (bus.Owner != HART_BITS'(h) &&
                        bus.Addr[h][P.PA_BITS-1:CONFLICT_OFFSET] != bus.Addr[bus.Owner][P.PA_BITS-1:CONFLICT_OFFSET])
                        else $fatal(1, "Local M store raced a global access to its coherence/refill region");
                if (HREADY && !HRESP && bus.Op[bus.Owner] == 1) stores_at_lr_reply <= stores_at_lr_reply + 1;
                if (HREADY && !HRESP && !bus.Prot[bus.Owner][0]) stores_at_ifill_reply <= stores_at_ifill_reply + 1;
            end
        end
    end
    int local_replies = 0, overlapping_replies = 0, simultaneous_replies = 0;
    always @(posedge HCLK) if (HRESETn) begin
        local_replies <= local_replies + $countones(bus.LocalReply);
        if (bus.DataPhase && !HREADY && |bus.LocalReply)
            overlapping_replies <= overlapping_replies + 1;
        if ($countones(bus.LocalReply) > 1) simultaneous_replies <= simultaneous_replies + 1;
    end
    int instruction_write_overlaps = 0, data_write_overlaps = 0, simultaneous_write_replies = 0;
    always @(posedge HCLK) if (HRESETn && bus.DataPhase && bus.Write[bus.Owner]) begin
        if ($countones(bus.LocalReply) > 1) simultaneous_write_replies <= simultaneous_write_replies + 1;
        for (int h = 0; h < NCORES; h++) if (bus.LocalReply[h]) begin
            assert (bus.Addr[h][P.PA_BITS-1:CONFLICT_OFFSET] != bus.Addr[bus.Owner][P.PA_BITS-1:CONFLICT_OFFSET])
                else $fatal(1, "Local read bypassed a write to the same physical word");
            if (bus.Prot[h][0]) data_write_overlaps <= data_write_overlaps + 1;
            else instruction_write_overlaps <= instruction_write_overlaps + 1;
        end
    end
    logic [31:0] rng = 32'h10c0ffee;
    assign downready = !pending || (delayq == 0 && (!errorq || error_first));
    assign downresp = pending && delayq == 0 && errorq;
    assign downrdata = mem[addrq[OFFSET +: 12]];
    always @(posedge HCLK) begin
        if (!HRESETn) begin
            pending <= 0;
            error_first <= 0;
            delayq <= 0;
        end else if (pending) begin
            if (delayq != 0) delayq <= delayq - 1;
            else if (errorq && !error_first) error_first <= 1;
            else begin
                if (writeq && !errorq)
                    for (int b = 0; b < P.XLEN/8; b++)
                        if (downstrb[b]) mem[addrq[OFFSET +: 12]][8*b +: 8] <= downwdata[8*b +: 8];
                pending <= 0;
            end
        end else if (downtrans[1]) begin
            pending <= 1;
            addrq <= downaddr;
            writeq <= downwrite;
            errorq <= downaddr == fault_addr && (downwrite ? fault_write : fault_read);
            error_first <= 0;
            delayq <= LATENCY;
            transfers <= transfers + 1;
            if (downwrite) writebacks <= writebacks + 1;
            if (downaddr == P.PA_BITS'('h10000001)) begin
                mmio <= mmio + 1;
                assert (downsize == 0) else $fatal(1, "MMIO access size changed");
            end else begin
                assert (downsize == 3'(OFFSET) && downaddr[OFFSET-1:0] == 0)
                    else $fatal(1, "MSI fill/writeback must use a whole aligned word");
                if (downwrite) assert (&downstrb) else $fatal(1, "Incomplete dirty writeback");
            end
            assert (downlock == HMASTLOCK) else $fatal(1, "Lost AMO exclusion");
        end
    end
    task automatic access(input int hart, input bit wr, input logic [P.PA_BITS-1:0] address,
        input logic [P.XLEN-1:0] value, input logic [P.XLEN/8-1:0] strobes,
        input logic [P.XLEN-1:0] expected, input logic [1:0] atomic_op = 0,
        input bit instruction = 0, input bit error_expected = 0, input bit sc_failed = 0,
        input logic [2:0] access_size = 3'(OFFSET));
        @(negedge HCLK);
        assert (CoreHREADY[hart]) else $fatal(1, "Hart %0d not ready", hart);
        CoreHADDR[hart] = address;
        CoreHWRITE[hart] = wr;
        CoreHSIZE[hart] = access_size;
        CoreHPROT[hart] = instruction ? 4'b0010 : 4'b0011;
        CoreHATOMIC[hart] = atomic_op;
        CoreHTRANS[hart] = 2;
        @(negedge HCLK);
        CoreHTRANS[hart] = 0;
        CoreHWDATA[hart] = value;
        CoreHWSTRB[hart] = strobes;
        while (!CoreHREADY[hart]) @(negedge HCLK);
        assert (CoreHRESP[hart] == error_expected) else $fatal(1, "Unexpected error response");
        if (!wr && !error_expected)
            assert (CoreHRDATA[hart] == expected)
                else $fatal(1, "Hart %0d read %h: got %h expected %h", hart, address, CoreHRDATA[hart], expected);
        if (atomic_op == 2)
            assert (CoreSCFail[hart] == sc_failed) else $fatal(1, "Unexpected SC verdict");
        @(negedge HCLK);
    endtask
    task automatic load(input int h, input int word_index, input logic [P.XLEN-1:0] expected,
        input logic [1:0] op = 0, input bit instruction = 0);
        access(h, 0, BASE + (P.PA_BITS'(word_index) << OFFSET), 0, '0, expected, op, instruction);
    endtask
    task automatic store(input int h, input int word_index, input logic [P.XLEN-1:0] value,
        input logic [1:0] op = 0, input bit sc_failed = 0);
        access(h, 1, BASE + (P.PA_BITS'(word_index) << OFFSET), value, '1, 0, op, 0, 0, sc_failed);
    endtask
    task automatic independent_write_read(input bit instruction);
        int before_count, before_parallel;
        localparam OTHER = 64 + (WORDS > ICACHE_WORDS ? WORDS : ICACHE_WORDS);
        // Same bank index, different physical tag. A store miss can evict a
        // dirty victim and snoop another bank without changing this hot word.
        if (LOCAL_DCACHE_WRITES) begin
            store(1, OTHER, 'h123456);
            load(0, OTHER, 'h123456); // Downgrade writer to S.
        end
        load(0, 64, reference[64], 0, instruction);
        if (NCORES > 2) load(2, 64, reference[64], 0, instruction);
        before_parallel = simultaneous_write_replies;
        before_count = instruction ? instruction_write_overlaps : data_write_overlaps;
        fork
            store(1, OTHER, 'h123456);
            begin
                @(negedge HCLK);
                while (!(bus.DataPhase && bus.Write[bus.Owner])) @(negedge HCLK);
                load(0, 64, reference[64], 0, instruction);
            end
            begin
                if (NCORES > 2) begin
                    @(negedge HCLK);
                    while (!(bus.DataPhase && bus.Write[bus.Owner])) @(negedge HCLK);
                    load(2, 64, reference[64], 0, instruction);
                end
            end
        join
        if (NCORES > 2) assert (simultaneous_write_replies > before_parallel)
            else $fatal(1, "Two independent hits did not overlap the same write");
        assert ((instruction ? instruction_write_overlaps : data_write_overlaps) > before_count)
            else $fatal(1, "Independent %s hit did not overlap a write", instruction ? "I" : "D");
        load(0, OTHER, 'h123456);
    endtask
    task automatic byte_write_read(input bit instruction);
        logic [P.XLEN-1:0] expected;
        expected = (reference[80] & ~P.XLEN'('hff00)) | P.XLEN'('haa00);
        load(0, 80, reference[80], 0, instruction);
        fork
            access(1, 1, BASE+(P.PA_BITS'(80) << OFFSET)+1,
                'haa00, (P.XLEN/8)'('h02), 0, 0, 0, 0, 0, 0);
            begin
                @(negedge HCLK);
                while (!(bus.DataPhase && bus.Write[bus.Owner])) @(negedge HCLK);
                load(0, 80, expected, 0, instruction);
            end
        join
        reference[80] = expected;
    endtask
    task automatic snoop_store_race(input bit instruction);
        int before_count;
        store(0, 176, 'h8100);
        before_count = local_stores;
        fork
            load(1, 176, 'h8100, 0, instruction);
            begin
                @(negedge HCLK);
                while (!(bus.DataPhase && !bus.Write[bus.Owner])) @(negedge HCLK);
                store(0, 176, 'h8101);
            end
        join
        // The snoop downgrades M to S. Recheck permission after it completes:
        // the queued store must fall back to a global upgrade, not lose data.
        assert (local_stores == before_count) else $fatal(1, "M store overtook a snoop");
        load(1, 176, 'h8101, 0, instruction);
    endtask
    task automatic local_m_checks();
        int saved, requests, parallel_before, coincidences;
        store(0, 128, 'h1111);
        store(1, 129, 'h2222);
        saved = local_stores;
        requests = global_requests;
        parallel_before = parallel_stores;
        snapshot = transfers;
        fork
            store(0, 128, 'h3333);
            store(1, 129, 'h4444);
        join
        assert (local_stores == saved+2 && parallel_stores > parallel_before &&
            transfers == snapshot && global_requests == requests)
            else $fatal(1, "Independent M stores did not commit locally in parallel");
        if (NCORES > 2) begin
            saved = parallel_stores_during_bus;
            fork
                load(2, 136, reference[136]);
                begin
                    @(negedge HCLK);
                    while (!bus.DataPhase) @(negedge HCLK);
                    fork
                        store(0, 128, 'h3333);
                        store(1, 129, 'h4444);
                    join
                end
            join
            assert (parallel_stores_during_bus > saved)
                else $fatal(1, "Parallel M stores did not overlap an independent miss");
        end
        load(0, 128, 'h3333, 1); // Own M hit: LR must still use the monitor.
        saved = local_stores;
        store(0, 128, 'h3333); // Same-value M store consumes its own reservation.
        assert (local_stores == saved+1) else $fatal(1, "M store unexpectedly used global bus");
        store(0, 128, 'hbad, 2, 1);
        access(0, 1, BASE+(P.PA_BITS'(128) << OFFSET)+1,
            'haa00, (P.XLEN/8)'('h02), 0, 0, 0, 0, 0, 0);
        load(0, 128, 'haa33);
        load(1, 128, 'haa33); // Peer intervention sees newest local bytes.
        // A stale reservation address must not clear a newly completed LR
        // to a DIFFERENT word when an M commit occurs on the same edge.
        load(1, 96, reference[96], 1);
        store(0, 96, 'h6100);
        coincidences = stores_at_lr_reply;
        fork
            load(1, 96+WORDS, reference[96+WORDS], 1);
            begin
                @(negedge HCLK);
                while (!(cache.State == 4 && cache.Transfer == 2 && downready)) @(negedge HCLK);
                store(0, 96, 'h6101);
            end
        join
        assert (stores_at_lr_reply > coincidences) else $fatal(1, "Missing LR/local-M commit coincidence");
        store(1, 96+WORDS, 'h6200, 2);
        load(0, 96+WORDS, 'h6200);
        if (PRIVATE_ICACHE) begin
            // Victim I tag aliases the local-store word, while the NEW fill
            // is a different word at the same index. Keep the new valid bit.
            load(1, 160, reference[160], 0, 1);
            store(0, 160, 'h7100);
            coincidences = stores_at_ifill_reply;
            fork
                load(1, 160+ICACHE_WORDS, reference[160+ICACHE_WORDS], 0, 1);
                begin
                    @(negedge HCLK);
                    while (!(cache.State == 4 && cache.Transfer == 2 && downready)) @(negedge HCLK);
                    store(0, 160, 'h7101);
                end
            join
            assert (stores_at_ifill_reply > coincidences) else $fatal(1, "Missing I-fill/local-M commit coincidence");
            snapshot = transfers;
            requests = global_requests;
            load(1, 160+ICACHE_WORDS, reference[160+ICACHE_WORDS], 0, 1);
            assert (transfers == snapshot && global_requests == requests)
                else $fatal(1, "Local M invalidation discarded an independent I fill");
            load(1, 160, 'h7101, 0, 1);
            snoop_store_race(1);
        end
        snoop_store_race(0);
        store(0, 192, 'h9100);
        load(1, 193, reference[193], 3);
        saved = local_stores;
        fork
            store(0, 192, 'h9101);
            begin
                repeat (4) @(negedge HCLK);
                assert (local_stores == saved && !CoreHREADY[0])
                    else $fatal(1, "Local M store bypassed AMO exclusion");
                load(1, 194, reference[194], 0, 1);
                store(1, 193, 'h9200, 3);
            end
        join
        assert (local_stores == saved+1) else $fatal(1, "Queued M store did not resume after AMO");
        load(0, 192, 'h9101);
    endtask
    task automatic multiline_checks();
        int before_count;
        logic [P.XLEN-1:0] value;
        // A complete line is installed atomically, with total capacity fixed.
        load(0, 0, reference[0]);
        snapshot = transfers;
        for (int w = 0; w < LINE_WORDS; w++) load(0, w, reference[w]);
        assert (transfers == snapshot) else $fatal(1, "Adjacent D word missed after line fill");
        for (int w = 0; w < LINE_WORDS; w++) begin
            reference[w] = P.XLEN'(int'('h1000+w));
            store(0, w, reference[w]);
        end
        before_count = writebacks;
        load(1, LINE_WORDS-1, reference[LINE_WORDS-1]);
        assert (writebacks-before_count == LINE_WORDS) else $fatal(1, "Dirty intervention was not a complete line");
        for (int w = 0; w < LINE_WORDS; w++) begin
            assert (mem[w] == reference[w]) else $fatal(1, "Dirty line lost another word");
            load(1, w, reference[w]);
        end
        // Ownership/invalidation covers other words of the line (false sharing).
        store(0, 0, 'h3000); reference[0] = 'h3000;
        assert (cache.States[1][0] == 0) else $fatal(1, "Peer retained a different word of an invalidated line");
        load(1, LINE_WORDS-1, reference[LINE_WORDS-1]);
        // Byte merge on an allocating miss preserves every other word and byte.
        value = (reference[WORDS+1] & ~P.XLEN'('hff00)) | P.XLEN'('hab00);
        access(0, 1, BASE+(P.PA_BITS'(int'(WORDS+1)) << OFFSET)+1, 'hab00,
            (P.XLEN/8)'(2), 0, 0, 0, 0, 0, 0);
        reference[WORDS+1] = value;
        load(1, WORDS+1, value);
        load(1, WORDS, reference[WORDS]);
        load(0, 0, reference[0], 1);
        store(1, 0, 'h3100); reference[0] = 'h3100;
        store(0, 0, 'hbad, 2, 1);
        load(0, 0, reference[0], 1);
        store(0, 0, 'h3200, 2); reference[0] = 'h3200;
        if (LINE_WORDS > 1) begin
            // Sharing a line is not itself a store to the LR reserved word.
            load(0, 0, reference[0], 1);
            store(1, 1, reference[1]);
            store(0, 0, 'h3250, 2); reference[0] = 'h3250;
            store(0, 0, reference[0]); // Establish M for the local-store case.
            load(0, 0, reference[0], 1);
            store(0, 1, reference[1]);
            store(0, 0, 'h3260, 2); reference[0] = 'h3260;
            load(1, 1, reference[1]);
        end
        // Locked AMO still excludes peer operations across whole-line transfers.
        load(0, 0, reference[0], 3);
        fork
            load(1, 0, P.XLEN'('h3300));
            begin
                load(0, 2*WORDS, reference[2*WORDS], 0, 1);
                store(0, 0, 'h3300, 3);
            end
        join
        reference[0] = 'h3300;
        if (PRIVATE_ICACHE) begin
            load(0, 64+ICACHE_LINE_WORDS-1, reference[64+ICACHE_LINE_WORDS-1], 0, 1);
            snapshot = transfers;
            for (int w = 0; w < ICACHE_LINE_WORDS; w++) load(0, 64+w, reference[64+w], 0, 1);
            assert (transfers == snapshot) else $fatal(1, "Adjacent I word missed after line fill");
            // A non-first store invalidates the entire instruction line remotely.
            store(1, 65, 'hcafe); reference[65] = 'hcafe;
            load(0, 65, reference[65], 0, 1);
            load(0, 64, reference[64], 0, 1);
            // Local M stores in another word must not race an in-flight I refill.
            store(0, 80, 'h8100); reference[80] = 'h8100;
            fork
                load(1, 80, P.XLEN'('h8100), 0, 1);
                begin
                    while (!bus.DataPhase) @(negedge HCLK);
                    store(0, 81, 'h8200);
                end
            join
            reference[81] = 'h8200;
            load(1, 81, reference[81], 0, 1);
        end
        if (LOCAL_DCACHE_WRITES) begin
            int previous;
            store(0, 0, 'h9010); reference[0] = 'h9010;
            store(1, 64, 'h9020); reference[64] = 'h9020;
            store(0, 1, reference[1]);
            store(1, 65, reference[65]);
            previous = parallel_stores;
            before_count = global_requests;
            fork
                store(0, 1, 'h9030);
                store(1, 65, 'h9040);
            join
            reference[1] = 'h9030; reference[65] = 'h9040;
            assert (parallel_stores > previous && global_requests == before_count)
                else $fatal(1, "Independent multiline M stores lost parallel local completion");
            if (NCORES > 2) begin
                previous = parallel_stores_during_bus;
                fork
                    load(2, 224, reference[224]);
                    begin
                        while (!bus.DataPhase) @(negedge HCLK);
                        fork
                            store(0, 1, 'h9050);
                            store(1, 65, 'h9060);
                        join
                    end
                join
                reference[1] = 'h9050; reference[65] = 'h9060;
                assert (parallel_stores_during_bus > previous)
                    else $fatal(1, "Parallel M stores failed to overlap an independent line miss");
            end
        end
        if (LOCAL_DCACHE_READS) begin
            int previous;
            load(0, 0, reference[0]);
            previous = overlapping_replies;
            fork
                load(1, 224, reference[224]);
                begin
                    repeat (4) @(negedge HCLK);
                    load(0, 0, reference[0]);
                end
            join
            assert (overlapping_replies > previous) else $fatal(1, "D hit failed to overlap line traffic");
        end
        if (PRIVATE_ICACHE) begin
            int previous;
            load(0, 192, reference[192], 0, 1);
            previous = overlapping_replies;
            fork
                load(1, 160, reference[160]);
                begin
                    repeat (4) @(negedge HCLK);
                    load(0, 192, reference[192], 0, 1);
                end
            join
            assert (overlapping_replies > previous) else $fatal(1, "I hit failed to overlap line traffic");
        end
        // Fail each writeback beat. Dirty ownership/data survive partial writes.
        for (int beat = 0; beat < LINE_WORDS; beat++) begin
            for (int w = 0; w < LINE_WORDS; w++) begin
                reference[w] = P.XLEN'(int'('h5000+beat*32+w));
                store(0, w, reference[w]);
            end
            fault_addr = BASE+(P.PA_BITS'(beat) << OFFSET); fault_write = 1;
            access(0, 0, BASE+(P.PA_BITS'(WORDS) << OFFSET), 0, '0, 0, 0, 0, 1);
            assert (cache.States[0][0] == 2) else $fatal(1, "Partial eviction lost M permission");
            for (int w = 0; w < LINE_WORDS; w++) load(0, w, reference[w]);
            access(1, 0, BASE, 0, '0, 0, 0, 0, 1);
            assert (cache.States[0][0] == 2) else $fatal(1, "Partial intervention lost M permission");
            fault_write = 0;
            load(1, 0, reference[0]);
            for (int w = 0; w < LINE_WORDS; w++) load(1, w, reference[w]);
        end
        // Fail every D-fill beat; no partial line becomes visible.
        for (int beat = 0; beat < LINE_WORDS; beat++) begin
            load(0, 3*WORDS, reference[3*WORDS]);
            fault_addr = BASE+(P.PA_BITS'(int'(2*WORDS+beat)) << OFFSET); fault_read = 1;
            access(0, 0, BASE+(P.PA_BITS'(2*WORDS) << OFFSET), 0, '0, 0, 0, 0, 1);
            fault_read = 0;
            snapshot = transfers;
            load(0, 2*WORDS, reference[2*WORDS]);
            assert (transfers-snapshot == LINE_WORDS) else $fatal(1, "Partial D fill installed a line");
        end
        if (PRIVATE_ICACHE)
            for (int beat = 0; beat < ICACHE_LINE_WORDS; beat++) begin
                load(0, 128+ICACHE_WORDS, reference[128+ICACHE_WORDS], 0, 1);
                fault_addr = BASE+(P.PA_BITS'(int'(128+beat)) << OFFSET); fault_read = 1;
                access(0, 0, BASE+(P.PA_BITS'(128) << OFFSET), 0, '0, 0, 0, 1, 1);
                fault_read = 0;
                snapshot = transfers;
                load(0, 128, reference[128], 0, 1);
                assert (transfers-snapshot == ICACHE_LINE_WORDS) else $fatal(1, "Partial I fill installed a line");
            end
        // MMIO remains a single transfer, without line allocation/prefetch.
        snapshot = transfers;
        repeat (2) access(0, 0, P.PA_BITS'('h10000001), 0, '0, mem[0], 0, 0, 0, 0, 0);
        assert (transfers-snapshot == 2) else $fatal(1, "MMIO was prefetched or cached");
        $display("PASS: multiword directed D=%0d I=%0d words/line", LINE_WORDS, ICACHE_LINE_WORDS);
    endtask
    initial begin
        for (int w = 0; w < 4096; w++) begin
            mem[w] = (P.XLEN'(64'h5678000012340000) + P.XLEN'(w));
            reference[w] = mem[w];
        end
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        if (LINE_WORDS > 1 || ICACHE_LINE_WORDS > 1) multiline_checks();
        else begin
        load(0, 0, reference[0]);
        snapshot = transfers;
        load(0, 0, reference[0]);
        assert (transfers == snapshot) else $fatal(1, "Private read hit reached RAM");
        load(1, 0, reference[0]);
        store(0, 0, 'h42);
        assert (cache.States[0][0] == 2 && cache.States[1][0] == 0) else $fatal(1, "S->M upgrade failed");
        snapshot = transfers;
        store(0, 0, 'h43);
        load(0, 0, 'h43);
        assert (transfers == snapshot && mem[0] == reference[0]) else $fatal(1, "M hit was not write-back");
        load(1, 0, 'h43);
        assert (mem[0] == 'h43 && cache.States[0][0] == 1 && cache.States[1][0] == 1)
            else $fatal(1, "Modified intervention/downgrade failed");
        for (int h = 2; h < NCORES; h++) load(h, 0, 'h43);
        store(NCORES-1, 0, 'h44);
        for (int h = 0; h < NCORES-1; h++)
            assert (cache.States[h][0] == 0) else $fatal(1, "BusUpgr missed a sharer");
        load(0, 0, 'h44);
        store(0, 0, 'h45);
        store(1, 0, 'h46); // BusRdX against M.
        load(0, 0, 'h46);
        store(0, 0, 'h47);
        load(0, WORDS, reference[WORDS]);
        assert (mem[0] == 'h47) else $fatal(1, "Dirty replacement lost data");
        load(1, 0, 'h47);
        // Byte store must preserve every unselected byte, including on a miss.
        access(0, 1, BASE+1, 'haa00, (P.XLEN/8)'('h02), 0, 0, 0, 0, 0, 0);
        load(1, 0, 'haa47);
        // IFU never allocates; own- and remote-hart M copies are flushed first.
        store(0, 0, 'h51);
        load(0, 0, 'h51, 0, 1);
        store(0, 0, 'h52);
        load(1, 0, 'h52, 0, 1);
        assert (cache.States[1][0] == 0) else $fatal(1, "Instruction fetch allocated in private D-cache");
        for (int repeat_read = 0; repeat_read < 2; repeat_read++)
            access(0, 0, P.PA_BITS'('h10000001), 0, '0, mem[0], 0, 0, 0, 0, 0);
        assert (mmio == 2) else $fatal(1, "MMIO was cached");
        // Reservation invalidation must include stores that hit a private M line.
        store(1, 1, 'h61);
        load(0, 1, 'h61, 1);
        store(1, 1, 'h62);
        store(0, 1, 'hbad, 2, 1);
        load(0, 1, 'h62);
        load(0, 1, 'h62, 1);
        store(0, 1, 'h63, 2);
        load(1, 1, 'h63);
        store(0, 1, 'h63);
        load(0, 1, 'h63, 1);
        store(0, 1, 'h63); // M-hit ordinary store consumes its own LR reservation.
        store(0, 1, 'hbad, 2, 1);
        // Locked AMO permits its owner's instruction fetch while excluding peers.
        load(0, 1, 'h63, 3);
        fork
            begin
                load(1, 1, 'h64);
            end
            begin
                load(0, 2, reference[2], 0, 1);
                store(0, 1, 'h64, 3);
            end
        join
        if (PRIVATE_ICACHE) begin
            repeat (2) access(0, 0, P.PA_BITS'('h10000001), 0, '0, mem[0], 0, 1, 0, 0, 0);
            assert (mmio == 4) else $fatal(1, "Instruction MMIO access was cached");
            // Distinct I banks: simultaneous hits require no global transfer.
            for (int h = 0; h < NCORES; h++) load(h, 32, reference[32], 0, 1);
            snapshot = transfers;
            fork
                load(0, 32, reference[32], 0, 1);
                load(1, 32, reference[32], 0, 1);
            join
            assert (transfers == snapshot && simultaneous_replies > 0)
                else $fatal(1, "Private I hits were serialized on the bus");
            // Fill conflict replaces an I line; both are read from coherent RAM.
            load(0, 32+ICACHE_WORDS, reference[32+ICACHE_WORDS], 0, 1);
            snapshot = transfers;
            load(0, 32, reference[32], 0, 1);
            assert (transfers > snapshot) else $fatal(1, "I-cache conflict did not replace its victim");
            // Own and remote modifications invalidate I copies, including a byte.
            store(0, 32, 'h1234);
            load(0, 32, 'h1234, 0, 1);
            load(1, 32, 'h1234, 0, 1);
            access(1, 1, BASE+(P.PA_BITS'(32) << OFFSET)+1, 'hab00,
                (P.XLEN/8)'('h02), 0, 0, 0, 0, 0, 0);
            load(0, 32, 'hab34, 0, 1);
            load(1, 32, 'hab34, 0, 1);
            // A fetch issued after a write starts must wait for invalidation.
            fork
                store(1, 32, 'hcafe);
                begin
                    @(negedge HCLK);
                    while (!(bus.DataPhase && bus.Write[bus.Owner])) @(negedge HCLK);
                    load(0, 32, 'hcafe, 0, 1);
                end
            join
            fault_addr = BASE+(P.PA_BITS'(60) << OFFSET);
            fault_read = 1;
            repeat (2) access(0, 0, fault_addr, 0, '0, 0, 0, 1, 1);
            fault_read = 0;
            load(0, 60, reference[60], 0, 1);
            load(0, 32, 'hcafe, 0, 1);
            // A fast hit must retire while another hart is waiting for a miss.
            fork
                load(1, 48, reference[48]);
                begin
                    repeat (4) @(negedge HCLK);
                    load(0, 32, 'hcafe, 0, 1);
                end
            join
            assert (overlapping_replies > 0) else $fatal(1, "I hit did not overlap an outstanding miss");
        end
        if (LOCAL_DCACHE_READS) begin
            int saved;
            load(0, 40, reference[40]);
            load(1, 41, reference[41]);
            saved = simultaneous_replies;
            snapshot = transfers;
            fork
                load(0, 40, reference[40]);
                load(1, 41, reference[41]);
            join
            assert (simultaneous_replies > saved && transfers == snapshot)
                else $fatal(1, "Private D read hits were serialized on the bus");
            saved = local_replies;
            fork
                load(1, 49, reference[49]);
                begin
                    repeat (4) @(negedge HCLK);
                    load(0, 40, reference[40]);
                end
            join
            assert (local_replies > saved && overlapping_replies > 0)
                else $fatal(1, "Ordinary D read hit did not complete locally");
            load(0, 44, reference[44]);
            fork
                store(1, 44, 'hbeef);
                begin
                    @(negedge HCLK);
                    while (!(bus.DataPhase && bus.Write[bus.Owner])) @(negedge HCLK);
                    load(0, 44, 'hbeef);
                end
            join
            load(0, 40, reference[40]);
            // LR and AMO must retain global reservation/lock handling even on hits.
            saved = local_replies;
            load(0, 40, reference[40], 1);
            assert (local_replies == saved) else $fatal(1, "LR bypassed reservations");
            store(1, 40, 'h77);
            store(0, 40, 'hbad, 2, 1);
            load(0, 40, 'h77);
            load(1, 55, reference[55]);
            load(0, 40, 'h77, 3);
            fork
                load(1, 55, reference[55]);
                begin
                    repeat (4) @(negedge HCLK);
                    assert (!CoreHREADY[1]) else $fatal(1, "D hit bypassed AMO exclusion");
                    load(0, 2, reference[2], 0, 1);
                    store(0, 40, 'h78, 3);
                end
            join
        end
        if (PRIVATE_ICACHE) begin
            independent_write_read(1);
            byte_write_read(1);
        end
        if (LOCAL_DCACHE_READS) begin
            independent_write_read(0);
            byte_write_read(0);
        end
        if (LOCAL_DCACHE_WRITES) local_m_checks();
        // Failed victim writeback must retain the modified line for retry.
        store(0, 0, 'h71);
        fault_addr = BASE;
        fault_write = 1;
        access(0, 0, BASE+(P.PA_BITS'(WORDS) << OFFSET), 0, '0, 0, 0, 0, 1);
        assert (cache.States[0][0] == 2) else $fatal(1, "Failed eviction discarded M");
        load(0, 0, 'h71);
        // Failed snoop writeback must not expose stale memory or grant ownership.
        access(1, 0, BASE, 0, '0, 0, 0, 0, 1);
        assert (cache.States[0][0] == 2 &&
            !(cache.States[1][0] != 0 && cache.Tags[1][0] == BASE[P.PA_BITS-1:OFFSET+$clog2(LINE_WORDS)+INDEX]))
            else $fatal(1, "Failed intervention changed ownership");
        fault_write = 0;
        load(1, 0, 'h71);
        fault_addr = BASE + ((P.PA_BITS'(WORDS)+3) << OFFSET);
        fault_read = 1;
        access(1, 0, fault_addr, 0, '0, 0, 0, 0, 1);
        fault_read = 0;
        load(1, WORDS+3, reference[WORDS+3]);
        // Concurrent readers and simultaneous ownership requests exercise arbitration.
        store(0, 2, 'h80);
        fork
            load(0, 2, 'h80);
            load(1, 2, 'h80);
        join
        fork
            store(0, 2, 'h81);
            store(1, 2, 'h82);
        join
        assert (cache.States[0][(2/LINE_WORDS) % (WORDS/LINE_WORDS)] == 2 || cache.States[1][(2/LINE_WORDS) % (WORDS/LINE_WORDS)] == 2)
            else $fatal(1, "Concurrent stores left no owner");
        end
        // Establish a known reference, then randomize hits, misses, subword stores,
        // sharing, dirty conflicts and uncached instruction reads across all harts.
        for (int w = 0; w < 16; w++) begin
            reference[w] = (P.XLEN'('h98760000) + P.XLEN'(w));
            store(0, w, reference[w]);
        end
        for (int iteration = 0; iteration < 2000; iteration++) begin
            int h, w, byte_index;
            logic [P.XLEN/8-1:0] mask;
            logic [P.XLEN-1:0] random_data;
            rng = (rng << 13) ^ rng;
            rng = (rng >> 17) ^ rng;
            rng = (rng << 5) ^ rng;
            random_data = P.XLEN'({~rng, rng});
            h = int'(rng % NCORES);
            w = int'((rng >> 8) % 16);
            byte_index = int'((rng >> 16) % (P.XLEN/8));
            if (rng[4]) begin
                mask = rng[5] ? '1 : (P.XLEN/8)'(1 << byte_index);
                access(h, 1, BASE+(P.PA_BITS'(w) << OFFSET), random_data, mask, 0);
                for (int b = 0; b < P.XLEN/8; b++)
                    if (mask[b]) reference[w][8*b +: 8] = 8'(random_data >> (8*b));
            end else load(h, w, reference[w], 0, rng[5]);
        end
        for (int w = 0; w < 16; w++)
            for (int h = 0; h < NCORES; h++) load(h, w, reference[w]);
        if (PRIVATE_ICACHE) load(0, 32, mem[32], 0, 1);
        // Reset aborts an outstanding bus operation and invalidates every bank.
        @(negedge HCLK);
        CoreHADDR[0] = BASE;
        CoreHWRITE[0] = 0;
        CoreHATOMIC[0] = 0;
        CoreHTRANS[0] = 2;
        @(negedge HCLK);
        CoreHTRANS[0] = 0;
        repeat (2) @(negedge HCLK);
        HRESETn = 0;
        repeat (2) @(negedge HCLK);
        HRESETn = 1;
        for (int h = 0; h < NCORES; h++)
            for (int w = 0; w < WORDS/LINE_WORDS; w++)
                assert (cache.States[h][w] == 0) else $fatal(1, "Reset left a valid line");
        load(0, 0, mem[0]);
        if (PRIVATE_ICACHE) begin
            snapshot = transfers;
            load(0, 32, mem[32], 0, 1);
            assert (transfers > snapshot) else $fatal(1, "Reset left a valid I-cache line");
        end
        $display("LOCAL M: stores=%0d parallel=%0d during-bus=%0d parallel-during-bus=%0d LR-coincidence=%0d I-fill-coincidence=%0d",
            local_stores, parallel_stores, stores_during_bus, parallel_stores_during_bus, stores_at_lr_reply, stores_at_ifill_reply);
        $display("WRITE OVERLAP: I=%0d D=%0d parallel=%0d", instruction_write_overlaps, data_write_overlaps, simultaneous_write_replies);
        $display("LOCAL: I=%0d D=%0d replies=%0d overlapped=%0d simultaneous=%0d",
            PRIVATE_ICACHE, LOCAL_DCACHE_READS, local_replies, overlapping_replies, simultaneous_replies);
        $display("PASS: MSI RV%0d, %0d harts, %0d words, latency %0d: directed + 2000 randomized operations", P.XLEN, NCORES, WORDS, LATENCY);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "MSI test timeout");
    end
endmodule
