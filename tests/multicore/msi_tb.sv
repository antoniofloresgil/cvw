// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Full arbiter/MSI path, RV32/RV64, waits/errors and a software reference model.
`include "config.vh"
module msi_tb import cvw::*; #(
    parameter int NCORES = 2,
    parameter int LATENCY = 3,
    parameter int WORDS = 4
);
    `include "parameter-defs.vh"
    localparam OFFSET = $clog2(P.XLEN/8);
    localparam INDEX = $clog2(WORDS);
    localparam HART_BITS = $clog2(NCORES);
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
    ahbmulticore #(.P(P), .NCORES(NCORES)) bus(.*);
    ahbmsicache #(.P(P), .NCORES(NCORES), .WORDS(WORDS)) cache(
        .HCLK, .HRESETn, .UpHOWNER(HOWNER), .UpHADDR(HADDR), .UpHWDATA(HWDATA), .UpHWSTRB(HWSTRB),
        .UpHWRITE(HWRITE), .UpHMASTLOCK(HMASTLOCK), .UpHSIZE(HSIZE), .UpHBURST(HBURST),
        .UpHPROT(HPROT), .UpHTRANS(HTRANS), .UpHRDATA(HRDATA), .UpHREADY(HREADY), .UpHRESP(HRESP),
        .HADDR(downaddr), .HWDATA(downwdata), .HWSTRB(downstrb), .HWRITE(downwrite), .HMASTLOCK(downlock),
        .HSIZE(downsize), .HBURST(downburst), .HPROT(downprot), .HTRANS(downtrans),
        .HRDATA(downrdata), .HREADY(downready), .HRESP(downresp));
    logic [P.XLEN-1:0] mem[256], reference[256];
    logic pending = 0, writeq, errorq, error_first = 0;
    logic fault_read = 0, fault_write = 0;
    logic [P.PA_BITS-1:0] fault_addr = '1, addrq;
    int delayq = 0, transfers = 0, writebacks = 0, snapshot, mmio = 0;
    logic [31:0] rng = 32'h10c0ffee;
    assign downready = !pending || (delayq == 0 && (!errorq || error_first));
    assign downresp = pending && delayq == 0 && errorq;
    assign downrdata = mem[addrq[OFFSET +: 8]];
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
                        if (downstrb[b]) mem[addrq[OFFSET +: 8]][8*b +: 8] <= downwdata[8*b +: 8];
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
    initial begin
        for (int w = 0; w < 256; w++) begin
            mem[w] = (P.XLEN'(64'h5678000012340000) + P.XLEN'(w));
            reference[w] = mem[w];
        end
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
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
        // Failed victim writeback must retain the modified line for retry.
        store(0, 0, 'h71);
        fault_addr = BASE;
        fault_write = 1;
        access(0, 0, BASE+(P.PA_BITS'(WORDS) << OFFSET), 0, '0, 0, 0, 0, 1);
        assert (cache.States[0][0] == 2) else $fatal(1, "Failed eviction discarded M");
        load(0, 0, 'h71);
        // Failed snoop writeback must not expose stale memory or grant ownership.
        access(1, 0, BASE, 0, '0, 0, 0, 0, 1);
        assert (cache.States[0][0] == 2 && cache.States[1][0] == 0)
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
        assert (cache.States[0][2 % WORDS] == 2 || cache.States[1][2 % WORDS] == 2)
            else $fatal(1, "Concurrent stores left no owner");
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
            for (int w = 0; w < WORDS; w++)
                assert (cache.States[h][w] == 0) else $fatal(1, "Reset left a valid line");
        load(0, 0, mem[0]);
        $display("PASS: MSI RV%0d, %0d harts, %0d words, latency %0d: directed + 2000 randomized operations", P.XLEN, NCORES, WORDS, LATENCY);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "MSI test timeout");
    end
endmodule
