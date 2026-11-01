// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Full arbiter/MSI path, RV32/RV64, waits/errors and a software reference model.
`include "config.vh"
module msifabric_tb import cvw::*; import multicore_observation::*; #(
    parameter int NCORES = 2,
    parameter int BANKS = 2,
    parameter int LATENCY = 3,
    parameter int WORDS = 32,
    parameter int LINE_WORDS = 4,
    parameter int ICACHE_LINE_WORDS = 4,
    parameter bit PRIVATE_ICACHE = 1,
    parameter int ICACHE_WORDS = 32,
    parameter bit CACHE_BURSTS = 0,
    parameter bit MESI = 0,
    parameter bit CACHE_TO_CACHE = 1,
    parameter bit LOCAL_DCACHE_READS = 0,
    parameter bit LOCAL_DCACHE_WRITES = 0
);
    `include "parameter-defs.vh"
    localparam OFFSET = $clog2(P.XLEN/8);
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
    localparam STRIDE = (WORDS > ICACHE_WORDS ? WORDS : ICACHE_WORDS)/BANKS;
    logic [P.PA_BITS-1:0] downaddr;
    logic [P.AHBW-1:0] downwdata, downrdata;
    logic [P.XLEN/8-1:0] downstrb;
    logic downwrite, downready, downresp;
    logic [2:0] downsize, downburst;
    logic [1:0] downtrans;
    ahbmsifabric #(.P(P), .NCORES(NCORES), .BANKS(BANKS),
        .DCACHE_WORDS(WORDS), .DCACHE_LINE_WORDS(LINE_WORDS),
        .PRIVATE_ICACHE(PRIVATE_ICACHE), .ICACHE_WORDS(ICACHE_WORDS), .ICACHE_LINE_WORDS(ICACHE_LINE_WORDS),
        .CACHE_TO_CACHE(CACHE_TO_CACHE), .CACHE_BURSTS(CACHE_BURSTS), .MESI(MESI), .LOCAL_DCACHE_READS(LOCAL_DCACHE_READS),
        .LOCAL_DCACHE_WRITES(LOCAL_DCACHE_WRITES)) dut(
        .HCLK, .HRESETn, .CoreHADDR, .CoreHWDATA, .CoreHWSTRB, .CoreHWRITE, .CoreHMASTLOCK,
        .CoreHSIZE, .CoreHBURST, .CoreHPROT, .CoreHTRANS, .CoreHATOMIC,
        .CoreHRDATA, .CoreHREADY, .CoreHRESP, .CoreSCFail, .DataMiss(), .InstrMiss(),
        .HADDR(downaddr), .HWDATA(downwdata), .HWSTRB(downstrb), .HWRITE(downwrite), .HMASTLOCK(),
        .HSIZE(downsize), .HBURST(downburst), .HPROT(), .HTRANS(downtrans),
        .HRDATA(downrdata), .HREADY(downready), .HRESP(downresp));
    logic [P.XLEN-1:0] mem[4096], reference[4096];
    logic pending = 0, writeq, errorq, error_first = 0;
    logic fault_read = 0, fault_write = 0;
    logic [P.PA_BITS-1:0] fault_addr = '1, addrq;
    int delayq = 0, transfers = 0, writebacks = 0, mmio = 0;
    `include "fabric_observer.svh"
    int overlap = 0, peak_active = 0;
    always @(posedge HCLK) if (HRESETn) begin
        if ($countones(Active) > 1) overlap <= overlap+1;
        if ($countones(Active) > peak_active) peak_active <= $countones(Active);
    end
    logic [31:0] rng = 32'h10c0ffee;
    `include "ahb_downstream_memory.svh"
    int unsigned sequential;
    ahb_downstream_checker #(.ADDR_WIDTH(P.PA_BITS), .DATA_WIDTH(P.AHBW),
        .STRB_WIDTH(P.XLEN/8), .BYTE_OFFSET(OFFSET)) downstream_checker(
        .HCLK, .HRESETn, .HADDR(downaddr), .HWDATA(downwdata), .HWSTRB(downstrb),
        .HSIZE(downsize), .HBURST(downburst), .HTRANS(downtrans), .HREADY(downready),
        .HRESP(downresp), .WriteDataWait(pending && writeq && !downready),
        .SequentialBeats(sequential));
    `include "ahb_master_tasks.svh"
    int coherence_requests = 0;
    always @(posedge HCLK) if (HRESETn)
        coherence_requests <= coherence_requests+$countones(TestLookup);
    `include "mesi_checks.vh"
    initial begin
        bit slow_done, fast_first;
        for (int w = 0; w < 4096; w++) begin
            mem[w] = P.XLEN'(64'h5678000012340000) + P.XLEN'(w);
            reference[w] = mem[w];
        end
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        mesi_checks();
        $display("BANKED: parallel ownership and RAM miss"); $fflush();
        store(0, STRIDE, 'h1234); reference[STRIDE] = 'h1234;
        slow_done = 0; fast_first = 0;
        fork
            begin load(0, 4*WORDS, reference[4*WORDS]); slow_done = 1; end
            begin store(1, STRIDE, 'h5678); fast_first = !slow_done; end
        join
        reference[STRIDE] = 'h5678;
        assert (overlap > 0) else $fatal(1, "Independent coherence misses never overlapped");
        if (CACHE_TO_CACHE && LATENCY >= 3)
            assert (fast_first) else $fatal(1, "Independent ownership transfer waited for RAM miss");
        load(0, STRIDE, reference[STRIDE]);
        $display("BANKED: cross-home reservations"); $fflush();
        // Every bank uses one per-hart reservation; an LR elsewhere replaces it.
        load(0, 0, reference[0], 1);
        load(0, STRIDE, reference[STRIDE], 1);
        store(0, 0, 'hbad, 2, 1);
        store(0, STRIDE, 'hbad, 2, 1);
        load(0, STRIDE, reference[STRIDE], 1);
        store(0, STRIDE, 'habcd, 2); reference[STRIDE] = 'habcd;
        load(0, STRIDE, reference[STRIDE], 1);
        store(1, STRIDE, 'hdead); reference[STRIDE] = 'hdead;
        store(0, STRIDE, 'hbad, 2, 1);
        $display("BANKED: AMO and remote IFU"); $fflush();
        // An AMO owner can fetch instructions from a different bank while a
        // peer is waiting there. No peer escapes exclusion or blocks its IFU.
        load(0, 0, reference[0], 3);
        fork
            store(1, STRIDE, 'h9000);
            begin
                load(0, STRIDE, reference[STRIDE], 0, 1);
                store(0, 0, 'h8000, 3);
            end
        join
        reference[0] = 'h8000; reference[STRIDE] = 'h9000;
        fork
            begin load(0, 0, reference[0], 3); store(0, 0, 'h8001, 3); end
            begin load(1, STRIDE, reference[STRIDE], 3); store(1, STRIDE, 'h9001, 3); end
        join
        reference[0] = 'h8001; reference[STRIDE] = 'h9001;
        $display("BANKED: same-home conflict"); $fflush();
        // Conflicting requests to the same home remain ordered.
        fork
            load(0, 0, reference[0]);
            load(1, 0, reference[0]);
        join
        if (NCORES >= 4 && BANKS >= 4) begin
            fork
                load(0, 12*WORDS, reference[12*WORDS]);
                load(1, 12*WORDS+STRIDE, reference[12*WORDS+STRIDE]);
                load(2, 12*WORDS+2*STRIDE, reference[12*WORDS+2*STRIDE]);
                load(3, 12*WORDS+3*STRIDE, reference[12*WORDS+3*STRIDE]);
            join
            assert (peak_active >= 4) else $fatal(1, "Four homes did not become active together");
        end
        if (CACHE_BURSTS && PRIVATE_ICACHE && ICACHE_LINE_WORDS > LINE_WORDS) begin
            // The first D line is absent/clean while a later D line in the
            // same I refill has a modified owner. Whole-region snooping must
            // prevent a RAM burst from exposing stale instruction words.
            store(1, 8*WORDS+LINE_WORDS, 'hc0de);
            reference[8*WORDS+LINE_WORDS] = 'hc0de;
            load(0, 8*WORDS, reference[8*WORDS], 0, 1);
            load(0, 8*WORDS+LINE_WORDS, 'hc0de, 0, 1);
        end
        $display("BANKED: writeback errors"); $fflush();
        // A partial intervention keeps the dirty owner and never installs a
        // partial requester, regardless of which bank returns the error.
        for (int b = 0; b < BANKS; b++) begin
            for (int beat = 0; beat < LINE_WORDS; beat++) begin
                for (int w = 0; w < LINE_WORDS; w++) begin
                    reference[b*STRIDE+w] = P.XLEN'(int'('h5000+b*256+beat*32+w));
                    store(0, b*STRIDE+w, reference[b*STRIDE+w]);
                end
                fault_addr = BASE+(P.PA_BITS'(int'(b*STRIDE+beat)) << OFFSET); fault_write = 1;
                access(1, 0, BASE+(P.PA_BITS'(b*STRIDE) << OFFSET), 0, '0, 0, 0, 0, 1);
                fault_write = 0;
                for (int w = 0; w < LINE_WORDS; w++) load(0, b*STRIDE+w, reference[b*STRIDE+w]);
                for (int w = 0; w < LINE_WORDS; w++) load(1, b*STRIDE+w, reference[b*STRIDE+w]);
            end
        end
        for (int b = 0; b < BANKS; b++) begin
            fault_addr = BASE+(P.PA_BITS'(8*WORDS+b*STRIDE) << OFFSET); fault_read = 1;
            access(0, 0, fault_addr, 0, '0, 0, 0, 0, 1);
            fault_read = 0;
            load(0, 8*WORDS+b*STRIDE, reference[8*WORDS+b*STRIDE]);
        end
        $display("BANKED: random reference comparison"); $fflush();
        for (int iteration = 0; iteration < 2000; iteration++) begin
            int h, w, byte_index;
            logic [P.XLEN/8-1:0] mask;
            logic [P.XLEN-1:0] value;
            rng = (rng << 13) ^ rng; rng = (rng >> 17) ^ rng; rng = (rng << 5) ^ rng;
            value = P.XLEN'({~rng, rng});
            h = int'(rng % NCORES); w = int'((rng >> 8) % (BANKS*STRIDE*2));
            byte_index = int'((rng >> 16) % (P.XLEN/8));
            if (rng[4]) begin
                mask = rng[5] ? '1 : (P.XLEN/8)'(1 << byte_index);
                access(h, 1, BASE+(P.PA_BITS'(w) << OFFSET), value, mask, 0);
                for (int b = 0; b < P.XLEN/8; b++)
                    if (mask[b]) reference[w][8*b +: 8] = 8'(value >> (8*b));
            end else load(h, w, reference[w], 0, rng[5]);
        end
        $display("BANKED: parallel RAM and sharing"); $fflush();
        // Simultaneous read/write streams, including two homes using RAM.
        fork
            begin store(0, 16*WORDS, 'h7000); load(0, 16*WORDS, 'h7000); end
            begin store(1, 16*WORDS+STRIDE, 'h7100); load(1, 16*WORDS+STRIDE, 'h7100); end
        join
        fork
            begin load(0, 16*WORDS+STRIDE, 'h7100); store(0, 16*WORDS+STRIDE, 'h7101); end
            begin load(1, 16*WORDS, 'h7000); store(1, 16*WORDS, 'h7001); end
        join
        load(0, 16*WORDS, 'h7001);
        load(1, 16*WORDS+STRIDE, 'h7101);
        $display("BANKED: uncached MMIO"); $fflush();
        // MMIO is unallocated and remains strongly ordered per hart.
        repeat (2) access(0, 0, P.PA_BITS'('h10000001), 0, '0, mem[0], 0, 0, 0, 0, 0);
        assert (mmio == 2) else $fatal(1, "MMIO incorrectly allocated");
        $display("BANKED: reset with pending requests"); $fflush();
        // Reset with two independent transactions queued/in flight.
        @(negedge HCLK);
        for (int h = 0; h < 2; h++) begin
            CoreHADDR[h] = BASE+(P.PA_BITS'(32*WORDS+h*STRIDE) << OFFSET);
            CoreHWRITE[h] = 0; CoreHATOMIC[h] = 0; CoreHTRANS[h] = 2;
        end
        @(negedge HCLK); CoreHTRANS = '0;
        repeat (8) @(negedge HCLK);
        HRESETn = 0; repeat (3) @(negedge HCLK); HRESETn = 1;
        load(0, 0, mem[0]);
        load(1, STRIDE, mem[STRIDE]);
        if (CACHE_BURSTS && (LINE_WORDS > 1 || (PRIVATE_ICACHE && ICACHE_LINE_WORDS > 1)))
            assert (sequential > 0) else $fatal(1, "Burst option emitted no sequential transfers");
        if (!CACHE_BURSTS) assert (sequential == 0) else $fatal(1, "Disabled burst path emitted SEQ");
        $display("AHB SEQ beats: %0d", sequential);
        $display("PASS: banked MSI RV%0d harts=%0d banks=%0d overlap=%0d peak=%0d: directed + 2000 random operations", P.XLEN, NCORES, BANKS, overlap, peak_active);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "Banked MSI test timeout");
    end
endmodule
