// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Real busfsm/ahbinterface/EBU endpoints against one/two-home buffered adapters.
`include "config.vh"
module adapter_tb import cvw::*; #(
    parameter int NCORES = 2,
    parameter int BANKS = 1,
    parameter int LATENCY = 3
)();
    `include "parameter-defs.vh"
    localparam OFFSET = $clog2(P.XLEN/8);
    localparam logic [P.PA_BITS-1:0] BASE = P.PA_BITS'(P.UNCORE_RAM_BASE);
    localparam logic [P.PA_BITS-1:0] FAULT = P.PA_BITS'('h100003f0);
    logic HCLK = 0, HRESETn = 0;
    always #5 HCLK = ~HCLK;
    logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR, LAdr = '0, IAdr = '0;
    logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA, CoreHRDATA;
    logic [NCORES-1:0][P.XLEN-1:0] WData = '0, LBuffer, IBuffer;
    logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB, Mask = '1;
    logic [NCORES-1:0] CoreHWRITE, CoreHMASTLOCK, CoreHREADY, CoreHRESP, CoreSCFail;
    logic [NCORES-1:0][2:0] CoreHSIZE, CoreHBURST;
    logic [NCORES-1:0][3:0] CoreHPROT;
    logic [NCORES-1:0][1:0] CoreHTRANS, CoreHATOMIC, LRW = '0, IRW = '0, Atomic = '0;
    logic [NCORES-1:0] LAtomic = '0, LStall, IStall, LCommitted, ICommitted, PipelineStall = '0, LFlush = '0;
    logic [P.PA_BITS-1:0] HADDR, AddrQ;
    logic [P.AHBW-1:0] HWDATA, HRDATA;
    logic [P.XLEN/8-1:0] HWSTRB;
    logic HWRITE, HMASTLOCK, HREADY, HRESP;
    logic [2:0] HSIZE, HBURST;
    logic [3:0] HPROT;
    logic [1:0] HTRANS;
    logic Active = 0, WriteQ, ErrorQ, ErrorLast = 0;
    logic FaultRead = 0, FaultWrite = 0;
    logic [P.XLEN-1:0] Memory[1024];
    int Delay = 0, Transfers = 0, Writes = 0, ErrorWaits = 0, ErrorFinals = 0, LockContention = 0;
    int Accepted[NCORES] = '{default:0};

    for (genvar h = 0; h < NCORES; h++) begin : endpoints
        logic [1:0] lt, it;
        logic lw, lr, ir;
        logic [P.XLEN-1:0] wd;
        logic [P.XLEN/8-1:0] ws;
        ahbinterface #(.XLEN(P.XLEN), .LSU(1)) lsu(
            .HCLK, .HRESETn, .HREADY(lr), .HTRANS(lt), .HWRITE(lw), .HRDATA(CoreHRDATA[h]),
            .HWDATA(wd), .HWSTRB(ws), .Stall(PipelineStall[h]), .Flush(LFlush[h]),
            .BusRW(LRW[h]), .BusAtomic(LAtomic[h]), .ByteMask(Mask[h]), .WriteData(WData[h]),
            .BusStall(LStall[h]), .BusCommitted(LCommitted[h]), .FetchBuffer(LBuffer[h]));
        ahbinterface #(.XLEN(P.XLEN), .LSU(0)) ifu(
            .HCLK, .HRESETn, .HREADY(ir), .HTRANS(it), .HWRITE(), .HRDATA(CoreHRDATA[h]),
            .HWDATA(), .HWSTRB(), .Stall(1'b0), .Flush(1'b0), .BusRW(IRW[h]), .BusAtomic(1'b0),
            .ByteMask('0), .WriteData('0), .BusStall(IStall[h]), .BusCommitted(ICommitted[h]), .FetchBuffer(IBuffer[h]));
        ebu #(P) ebu(.clk(HCLK), .reset(~HRESETn),
            .IFUHTRANS(it), .IFUHSIZE(3'(OFFSET)), .IFUHBURST(3'b000), .IFUHADDR(IAdr[h]), .IFUHREADY(ir),
            .LSUHTRANS(lt), .LSUHWRITE(lw), .LSUHSIZE(3'(OFFSET)), .LSUHBURST(3'b000), .LSUHADDR(LAdr[h]),
            .LSUHWDATA(wd), .LSUHWSTRB(ws), .LSUHREADY(lr), .LSUAtomicOp(Atomic[h]), .HATOMIC(CoreHATOMIC[h]),
            .HCLK(), .HRESETn(), .HREADY(CoreHREADY[h]), .HRESP(CoreHRESP[h]),
            .HADDR(CoreHADDR[h]), .HWDATA(CoreHWDATA[h]), .HWSTRB(CoreHWSTRB[h]), .HWRITE(CoreHWRITE[h]),
            .HSIZE(CoreHSIZE[h]), .HBURST(CoreHBURST[h]), .HPROT(CoreHPROT[h]), .HTRANS(CoreHTRANS[h]), .HMASTLOCK(CoreHMASTLOCK[h]));
    end
    if (BANKS == 1) begin : serial
        ahbmulticore #(.P(P), .NCORES(NCORES)) dut(
            .ReservationClear('0), .HOWNER(), .CacheReadAddr(), .CacheReadHit('0), .CacheReadData('0),
            .CacheWriteHit('0), .CacheWriteCommit(), .CacheWriteData(), .CacheWriteStrb(), .*);
    end else begin : banked
        ahbmsifabric #(.P(P), .NCORES(NCORES), .BANKS(BANKS), .DCACHE_WORDS(16), .ICACHE_WORDS(16)) dut(.*);
    end
    assign HREADY = !Active || (Delay == 0 && (!ErrorQ || ErrorLast));
    assign HRESP = Active && Delay == 0 && ErrorQ;
    assign HRDATA = Memory[AddrQ[OFFSET +: 10]];
    initial foreach (Memory[w]) Memory[w] = 0;
    always @(posedge HCLK) begin
        if (!HRESETn) begin
            Active <= 0; ErrorLast <= 0; Delay <= 0;
        end else begin
            for (int h = 0; h < NCORES; h++) begin
                if (CoreHTRANS[h][1] && CoreHREADY[h]) Accepted[h] <= Accepted[h]+1;
                if (CoreHRESP[h] && !CoreHREADY[h]) ErrorWaits <= ErrorWaits+1;
                if (CoreHRESP[h] && CoreHREADY[h]) ErrorFinals <= ErrorFinals+1;
            end
            if (HMASTLOCK && !CoreHREADY[1]) LockContention <= LockContention+1;
            if (Active && Delay != 0) Delay <= Delay-1;
            if (Active && Delay == 0 && ErrorQ && !ErrorLast) ErrorLast <= 1;
            if (HREADY) begin
                if (Active && WriteQ && !ErrorQ) begin
                    Writes <= Writes+1;
                    for (int b = 0; b < P.XLEN/8; b++)
                        if (HWSTRB[b]) Memory[AddrQ[OFFSET +: 10]][8*b +: 8] <= HWDATA[8*b +: 8];
                end
                Active <= HTRANS[1];
                if (HTRANS[1]) begin
                    AddrQ <= HADDR; WriteQ <= HWRITE;
                    ErrorQ <= HADDR == FAULT && (HWRITE ? FaultWrite : FaultRead);
                    ErrorLast <= 0; Delay <= LATENCY; Transfers <= Transfers+1;
                end
            end
        end
    end
    task automatic fetch(input int h, input logic [P.PA_BITS-1:0] address);
        @(negedge HCLK); IAdr[h] = address; IRW[h] = 2'b10;
        do @(negedge HCLK); while (IStall[h]);
        IRW[h] = 0;
        @(negedge HCLK);
    endtask
    task automatic access(input int h, input logic [P.PA_BITS-1:0] address, input bit wr,
                          input logic [1:0] op, input logic [P.XLEN-1:0] value,
                          input logic [P.XLEN-1:0] expected = 0, input bit compare_read = 0,
                          input bit move_metadata = 0, input logic [P.XLEN/8-1:0] strobes = '1);
        @(negedge HCLK);
        LAdr[h] = address; WData[h] = value; Mask[h] = strobes;
        Atomic[h] = op; LAtomic[h] = op == 3;
        LRW[h] = op == 3 ? 2'b11 : wr ? 2'b01 : 2'b10;
        if (move_metadata) begin
            do @(posedge HCLK); while (!(CoreHREADY[h] && CoreHTRANS[h][1]));
            @(negedge HCLK); LAdr[h] = address + P.PA_BITS'(128); Atomic[h] = 0;
        end
        do @(negedge HCLK); while (LStall[h]);
        if (compare_read)
            assert (LBuffer[h] == expected) else $fatal(1, "Adapter read/AMO data mismatch %h != %h", LBuffer[h], expected);
        LRW[h] = 0; LAtomic[h] = 0; Atomic[h] = 0;
        @(negedge HCLK);
    endtask
    initial begin
        int count, errors, accepted;
        logic [P.XLEN-1:0] persisted;
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        // Data flops update one cycle after the address, never at address capture.
        access(0, BASE, 1, 0, 11, 0, 0, 1);
        access(1, BASE, 0, 0, 0, 11, 1);
        access(0, BASE, 1, 0, P.XLEN'('haa), 0, 0, 0, (P.XLEN/8)'(1));
        access(1, BASE, 0, 0, 0, P.XLEN'('haa), 1);
        // SC result remains visible across an IFU reply and a stalled MEM3 stage.
        PipelineStall[0] = 1;
        access(0, BASE, 1, 2, 99);
        assert (CoreSCFail[0]) else $fatal(1, "Missing failed SC result");
        assert (!LStall[0] && LCommitted[0]) else $fatal(1, "LSU did not retain completed SC in MEM3");
        fetch(0, BASE + P.PA_BITS'(64));
        assert (CoreSCFail[0]) else $fatal(1, "IFU reply overwrote failed SC");
        assert (!LStall[0] && LCommitted[0]) else $fatal(1, "LSU left MEM3 before pipeline release");
        @(negedge HCLK); PipelineStall[0] = 0;
        access(0, BASE, 0, 1, 0, P.XLEN'('haa), 1);
        access(0, BASE, 1, 2, 19, 0, 0, 1);
        assert (!CoreSCFail[0]) else $fatal(1, "Successful SC failed");
        access(1, BASE, 0, 0, 0, 19, 1);
        // The real EBU saves a simultaneous IFU request while LSU owns the bus.
        fork
            access(0, BASE, 0, 3, 27, 19, 1);
            fetch(0, BASE + P.PA_BITS'(64));
            begin
                wait (HMASTLOCK);
                access(1, BASE + P.PA_BITS'(128), 1, 0, 71);
            end
        join
        assert (LockContention > 0) else $fatal(1, "No peer contended with the AMO lock");
        access(1, BASE, 0, 0, 0, 27, 1);
        if (NCORES > 2) access(2, BASE, 0, 0, 0, 27, 1);
        // No acceptance means a pre-issue Flush can cancel the request.
        @(negedge HCLK); accepted = Accepted[0];
        LRW[0] = 2'b01; LFlush[0] = 1; LAdr[0] = BASE;
        repeat (3) @(negedge HCLK);
        assert (Accepted[0] == accepted) else $fatal(1, "Flush issued an address");
        LRW[0] = 0; LFlush[0] = 0;
        repeat (2) @(negedge HCLK);
        // HRESP is visible on the port but is presently ignored by EBU/busfsm.
        FaultRead = 1; errors = ErrorFinals;
        access(0, FAULT, 0, 0, 0);
        assert (ErrorFinals == errors+1 && ErrorWaits == ErrorFinals) else $fatal(1, "Read ERROR phases lost");
        count = Writes;
        access(0, FAULT, 0, 3, 123);
        assert (Writes == count && !HMASTLOCK && ErrorWaits == ErrorFinals)
            else $fatal(1, "Read-error AMO leaked its follow-on write/lock");
        FaultRead = 0; FaultWrite = 1;
        access(0, FAULT, 1, 0, 23);
        assert (Writes == count) else $fatal(1, "ERROR write committed");
        access(0, FAULT, 0, 1, 0);
        access(0, FAULT, 1, 2, 23);
        assert (CoreSCFail[0] && Writes == count) else $fatal(1, "SC ERROR lost failure result");
        fetch(0, BASE + P.PA_BITS'(64));
        assert (CoreSCFail[0]) else $fatal(1, "IFU reply overwrote SC ERROR result");
        access(0, FAULT, 0, 3, 23);
        assert (!HMASTLOCK && Writes == count) else $fatal(1, "AMO write ERROR retained lock/committed");
        FaultWrite = 0;
        // Reset cancels all accepted work, reservations and locks. The slave is
        // reset with the adapter: no promise of rollback after an earlier commit.
        access(0, BASE, 0, 1, 0, 27, 1); // Leave a live reservation across the abort.
        persisted = Memory[BASE[OFFSET +: 10]]; count = Writes;
        fork
            access(0, FAULT, 0, 3, 31);
            begin
                wait (Active && WriteQ && AddrQ == FAULT && HMASTLOCK);
                @(negedge HCLK); HRESETn = 0; LRW = '0; IRW = '0;
                repeat (3) @(negedge HCLK);
                HRESETn = 1;
            end
        join
        assert (Writes == count && !HMASTLOCK) else $fatal(1, "Reset-aborted AMO write committed/retained lock");
        access(0, BASE, 1, 2, 99);
        assert (CoreSCFail[0]) else $fatal(1, "Reset preserved a reservation");
        access(1, BASE, 0, 0, 0, persisted, 1);
        $display("PASS: RV%0d adapter, %0d harts/%0d homes, waits=%0d: real IFU/LSU/EBU, delayed data, metadata, AMO/SC, errors and reset", P.XLEN, NCORES, BANKS, LATENCY);
        $finish;
    end
    // Deliberately broken endpoint cases: the runner requires a named assertion
    // failure, not merely a nonzero simulator exit or this fixture's timeout.
    initial begin
        wait (HRESETn);
        if ($test$plusargs("BAD_SC")) begin
            @(negedge HCLK); force CoreSCFail[0] = 1'b1;
        end else if ($test$plusargs("BAD_OP")) begin
            wait (CoreHTRANS[0][1] && CoreHWRITE[0]);
            force CoreHATOMIC[0] = 2'b01;
        end else if ($test$plusargs("BAD_AMO_ADDR")) begin
            wait (HMASTLOCK && CoreHTRANS[0][1] && CoreHWRITE[0]);
            force CoreHADDR[0] = BASE + P.PA_BITS'(8);
        end else if ($test$plusargs("BAD_ERROR")) begin
            wait (CoreHRESP[0] && !CoreHREADY[0]);
            force CoreHREADY[0] = 1'b1;
        end else if ($test$plusargs("BAD_DATA") || $test$plusargs("BAD_STRB")) begin
            wait (CoreHTRANS[0][1] && CoreHREADY[0] && CoreHWRITE[0]);
            @(posedge HCLK);
            repeat (2) @(negedge HCLK);
            if ($test$plusargs("BAD_DATA")) force CoreHWDATA[0] = '1;
            else force CoreHWSTRB[0] = '0;
        end
    end
    initial begin
        #200000;
        $fatal(1, "Adapter test timed out");
    end
endmodule
